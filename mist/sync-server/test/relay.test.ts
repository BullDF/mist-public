import { env } from "cloudflare:workers";
import { runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, expect, it } from "vitest";
import { roomName, type Env as SyncEnv, type Item } from "../src/index";

declare global { namespace Cloudflare { interface Env extends SyncEnv {} } }
const sockets: WebSocket[] = [];
afterEach(() => { for (const socket of sockets.splice(0)) socket.close(); });
const token = () => crypto.randomUUID().replaceAll("-", "").padEnd(43, "a");
const item = (i: number, clock = 1): Item => ({
  id: String(i).padStart(43, "a"), hlc: `${String(clock).padStart(15, "0")}-000000-test`, blob: "ciphertext"
});
function inbox(socket: WebSocket) {
  const queued: any[] = [];
  const waiting: ((frame: any) => void)[] = [];
  socket.addEventListener("message", e => {
    const frame = e.data === "pong" ? "pong" : JSON.parse(e.data as string);
    if (waiting.length) waiting.shift()!(frame); else queued.push(frame);
  });
  return () => queued.length ? Promise.resolve(queued.shift()) : new Promise<any>(resolve => waiting.push(resolve));
}
async function connect(auth = token()) {
  const response = await SELF.fetch("https://relay/v1/connect", {
    headers: { Upgrade: "websocket", Authorization: `Bearer ${auth}` }
  });
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  sockets.push(socket);
  socket.accept();
  return { socket, next: inbox(socket), auth };
}
async function push(c: Awaited<ReturnType<typeof connect>>, items: Item[], ref = 1) {
  c.socket.send(JSON.stringify({ t: "push", ref, items }));
  expect(await c.next()).toEqual({ t: "ack", ref });
}

it("rejects invalid auth, methods and missing upgrades", async () => {
  for (const auth of ["", "Bearer short", `Bearer ${"!".repeat(43)}`, `Bearer ${"a".repeat(44)}`]) {
    expect((await SELF.fetch("https://relay/v1/connect", { headers: { Upgrade: "websocket", Authorization: auth } })).status).toBe(401);
  }
  expect((await SELF.fetch("https://relay/v1/connect")).status).toBe(400);
  expect((await SELF.fetch("https://relay/v1/connect", { method: "POST" })).status).toBe(400);
});

it("isolates rooms by token", async () => {
  const a = await connect(), b = await connect();
  await push(a, [item(1)]); await a.next();
  b.socket.send(JSON.stringify({ t: "hello", after: 0 }));
  expect(await b.next()).toEqual({ t: "synced", seq: 0 });
});

it("pages hello in ascending sequence order and resumes after a cursor", async () => {
  const a = await connect();
  await push(a, Array.from({ length: 500 }, (_, i) => item(i))); await a.next();
  await push(a, [item(500)]); await a.next();
  a.socket.send(JSON.stringify({ t: "hello", after: 0 }));
  const page = await a.next();
  expect(page.items).toHaveLength(500);
  expect(page.items.map((x: any) => x.seq)).toEqual(Array.from({ length: 500 }, (_, i) => i + 1));
  expect((await a.next()).items[0].seq).toBe(501);
  expect(await a.next()).toEqual({ t: "synced", seq: 501 });
  a.socket.send(JSON.stringify({ t: "hello", after: 500 }));
  expect((await a.next()).items).toHaveLength(1);
  expect(await a.next()).toEqual({ t: "synced", seq: 501 });
});

it("broadcasts LWW updates to sender and peer; drops stale and equal records", async () => {
  const a = await connect(), b = await connect(a.auth);
  await push(a, [item(1, 2)]);
  expect(await a.next()).toEqual(await b.next());
  await push(b, [item(1, 1), item(1, 2)], 2);
  b.socket.send(JSON.stringify({ t: "hello", after: 1 }));
  expect(await b.next()).toEqual({ t: "synced", seq: 1 });
  await push(b, [item(1, 3)], 3);
  expect((await b.next()).items[0].seq).toBe(2);
  expect((await a.next()).items[0].hlc).toBe(item(1, 3).hlc);
});

it("keeps malformed connections usable and auto-responds to ping", async () => {
  const a = await connect();
  for (const message of ["{", "null", '{"t":"hello","after":-1}', '{"t":"other"}']) {
    a.socket.send(message); expect((await a.next()).t).toBe("error");
  }
  a.socket.send("ping"); expect(await a.next()).toBe("pong");
  await push(a, [item(1)]); expect((await a.next()).items).toHaveLength(1);
});

it("rejects entire pushes over the item and blob limits", async () => {
  const a = await connect();
  for (const items of [Array.from({ length: 501 }, (_, i) => item(i)),
    [item(1), { ...item(2), blob: "x".repeat(65_537) }],
    [{ ...item(3), blob: "é".repeat(32_769) }]]) {
    a.socket.send(JSON.stringify({ t: "push", ref: 1, items }));
    expect((await a.next()).t).toBe("error");
  }
  a.socket.send(JSON.stringify({ t: "hello", after: 0 }));
  expect(await a.next()).toEqual({ t: "synced", seq: 0 });
  await push(a, [{ ...item(1), blob: "x".repeat(65_536) }]);
  expect((await a.next()).items[0].seq).toBe(1);
});

it("rolls back the whole push at the row cap, but allows updates", async () => {
  const a = await connect();
  const stub = env.SYNC_ROOMS.get(env.SYNC_ROOMS.idFromName(await roomName(a.auth)));
  await runInDurableObject(stub, (_instance, state) => {
    state.storage.sql.exec(`WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<200000)
      INSERT INTO records SELECT printf('%043d',x), x, '000000000000001-000000-test', 'ciphertext' FROM n`);
    state.storage.sql.exec("UPDATE counter SET seq=200000");
  });
  a.socket.send(JSON.stringify({ t: "push", ref: 1, items: [
    { ...item(1, 4), id: "1".padStart(43, "0") }, item(2, 4)
  ] }));
  expect((await a.next()).t).toBe("error");
  await runInDurableObject(stub, (_instance, state) => {
    expect(state.storage.sql.exec<{ n: number }>("SELECT count(*) AS n FROM records").one().n).toBe(200_000);
    expect(state.storage.sql.exec<{ seq: number }>("SELECT seq FROM counter").one().seq).toBe(200_000);
  });
  await push(a, [{ ...item(1, 4), id: "1".padStart(43, "0") }]);
  expect((await a.next()).items[0].seq).toBe(200_001);
});
