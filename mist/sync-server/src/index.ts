import { DurableObject } from "cloudflare:workers";

export interface Env { SYNC_ROOMS: DurableObjectNamespace<SyncRoom> }
export type Item = { id: string; hlc: string; blob: string };
type Row = Item & { seq: number };
const maxItems = 500;
const maxBlob = 64 * 1024;
const maxRows = 200_000;
const encoder = new TextEncoder();

export async function roomName(token: string): Promise<string> {
  const hash = await crypto.subtle.digest("SHA-256", encoder.encode(token));
  return Array.from(new Uint8Array(hash), b => b.toString(16).padStart(2, "0")).join("");
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (new URL(request.url).pathname !== "/v1/connect") return new Response("Not found", { status: 404 });
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("WebSocket upgrade required", { status: 400 });
    }
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(request.headers.get("Authorization") ?? "");
    if (!match) return new Response("Invalid bearer token", { status: 401 });
    return env.SYNC_ROOMS.get(env.SYNC_ROOMS.idFromName(await roomName(match[1]))).fetch(request);
  }
} satisfies ExportedHandler<Env>;

export class SyncRoom extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.storage.sql.exec(`
      CREATE TABLE IF NOT EXISTS records(id TEXT PRIMARY KEY, seq INTEGER NOT NULL UNIQUE,
                                        hlc TEXT NOT NULL, blob TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS counter(singleton INTEGER PRIMARY KEY CHECK(singleton=1), seq INTEGER NOT NULL);
      INSERT OR IGNORE INTO counter VALUES(1, 0);
    `);
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  fetch(): Response {
    const pair = new WebSocketPair();
    this.ctx.acceptWebSocket(pair[1]);
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): void {
    try {
      if (typeof message !== "string") throw new Error("Expected a JSON text frame");
      const frame = JSON.parse(message);
      if (frame?.t === "hello") {
        if (!Number.isSafeInteger(frame.after) || frame.after < 0) throw new Error("Invalid cursor");
        let after = frame.after;
        for (;;) {
          const items = this.ctx.storage.sql.exec<Row>(
            "SELECT seq,id,hlc,blob FROM records WHERE seq > ? ORDER BY seq LIMIT ?", after, maxItems
          ).toArray();
          if (!items.length) break;
          socket.send(JSON.stringify({ t: "records", items }));
          after = items[items.length - 1].seq;
        }
        socket.send(JSON.stringify({ t: "synced", seq: this.currentSeq() }));
      } else if (frame?.t === "push") {
        if (!Number.isSafeInteger(frame.ref) || !Array.isArray(frame.items) || frame.items.length > maxItems) {
          throw new Error("Invalid push (maximum 500 items)");
        }
        for (const item of frame.items) {
          if (typeof item?.id !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(item.id) ||
              typeof item.hlc !== "string" || !/^\d{15}-\d{6}-[A-Za-z0-9-]{1,64}$/.test(item.hlc) ||
              typeof item.blob !== "string" || !item.blob.length || encoder.encode(item.blob).length > maxBlob) {
            throw new Error("Invalid record (maximum blob size 64 KiB)");
          }
        }
        const accepted = this.ctx.storage.transactionSync(() => {
          const rows: Row[] = [];
          let seq = this.currentSeq();
          let count = this.ctx.storage.sql.exec<{ n: number }>("SELECT count(*) AS n FROM records").one().n;
          for (const item of frame.items as Item[]) {
            const old = this.ctx.storage.sql.exec<Row>("SELECT hlc FROM records WHERE id = ?", item.id).toArray()[0];
            if (old && item.hlc <= old.hlc) continue;
            if (!old && ++count > maxRows) throw new Error("Room limit of 200,000 records reached");
            const row = { id: item.id, hlc: item.hlc, blob: item.blob, seq: ++seq };
            this.ctx.storage.sql.exec(`INSERT INTO records(id,seq,hlc,blob) VALUES(?,?,?,?)
              ON CONFLICT(id) DO UPDATE SET seq=excluded.seq,hlc=excluded.hlc,blob=excluded.blob`,
              row.id, row.seq, row.hlc, row.blob);
            rows.push(row);
          }
          this.ctx.storage.sql.exec("UPDATE counter SET seq=? WHERE singleton=1", seq);
          return rows;
        });
        socket.send(JSON.stringify({ t: "ack", ref: frame.ref }));
        if (accepted.length) {
          const broadcast = JSON.stringify({ t: "records", items: accepted });
          for (const peer of this.ctx.getWebSockets()) {
            try { peer.send(broadcast); } catch { peer.close(1011, "Reconnect to catch up"); }
          }
        }
      } else throw new Error("Unknown frame type");
    } catch (error) {
      socket.send(JSON.stringify({ t: "error", message: error instanceof Error ? error.message : "Invalid frame" }));
    }
  }

  webSocketClose(socket: WebSocket, code: number): void {
    socket.close(code === 1005 || code === 1006 || code === 1015 ? 1000 : code);
  }
  webSocketError(socket: WebSocket): void { socket.close(1011, "Reconnect to catch up"); }
  private currentSeq(): number {
    return this.ctx.storage.sql.exec<{ seq: number }>("SELECT seq FROM counter WHERE singleton=1").one().seq;
  }
}
