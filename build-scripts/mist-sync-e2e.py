#!/usr/bin/env python3
"""Own the local relay process group so every exit cleans up Wrangler and workerd."""
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request


def main():
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="mist-sync-relay-") as scratch:
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        url = f"http://127.0.0.1:{port}"
        log_path = Path(scratch) / "wrangler.log"
        with log_path.open("w") as log:
            relay = subprocess.Popen(
                ["npx", "--no-install", "wrangler", "dev", "--local", "--ip", "127.0.0.1",
                 "--port", str(port), "--inspector-port", "0", "--persist-to", str(Path(scratch) / "state"),
                 "--show-interactive-dev-session=false", "--log-level", "error"],
                cwd=root / "mist/sync-server", stdout=log, stderr=subprocess.STDOUT,
                env={**os.environ, "WRANGLER_SEND_METRICS": "false", "CI": "true"}, start_new_session=True,
            )
            try:
                deadline = time.monotonic() + 45
                while True:
                    if relay.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Local Wrangler did not start")
                    try:
                        urllib.request.urlopen(url, timeout=0.5).close()
                        break
                    except urllib.error.HTTPError:
                        break  # A 404 proves that the relay is listening.
                    except urllib.error.URLError:
                        time.sleep(0.1)
                subprocess.run([sys.argv[1], url], check=True, timeout=90)
            except BaseException:
                print(log_path.read_text()[-8000:], file=sys.stderr)
                raise
            finally:
                try:
                    os.killpg(relay.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    relay.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(relay.pid, signal.SIGKILL)
                    relay.wait()


if __name__ == "__main__":
    main()
