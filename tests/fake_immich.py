#!/usr/bin/env python3
"""A stand-in for Immich: one library per API key, in memory, no dependencies.

The plugin authenticates with an ``x-api-key`` header, so a different key is a
different account here exactly as it is on a real server. That is what makes an
account switch testable without two Immich instances: swap the key file, and the
next list request answers with the other library.

Libraries are keyed by key string; the assets are ``(id, fileCreatedAt)`` pairs.
An unknown key gets an empty library, which is the interesting case for the
privacy tests: a valid answer, no photos.

Only the endpoints ``scripts/immich.sh`` actually calls are implemented:
``POST /api/search/metadata`` (list) and ``GET /api/assets/<id>/thumbnail``
(fetch), plus ``/api/server/version`` and ``/api/albums`` so ``check`` works.

``slow`` delays every list response, which is how the "refresh is already in
flight when the key changes" race is reproduced.
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import pathlib
import threading
import time

ASSET_DIR = pathlib.Path(__file__).resolve().parent / "assets"
THUMBNAIL = (ASSET_DIR / "thumb.jpg").read_bytes()

# Two photos for the "signed in" account, none for the empty one, one for the
# third. Ids keep a per-library prefix so a failed assertion says which library
# a path came from.
LIBS = {
    "KEY-A": [
        ("aaaaaaaa-0000-4000-8000-000000000001", "2024-01-01T10:00:00.000Z"),
        ("aaaaaaaa-0000-4000-8000-000000000002", "2024-01-02T10:00:00.000Z"),
    ],
    "KEY-B": [],
    "KEY-C": [
        ("cccccccc-0000-4000-8000-000000000001", "2024-02-01T10:00:00.000Z"),
    ],
}


def asset_payload(assets, count=None):
    items = [{
        "id": asset_id,
        "width": 1600,
        "height": 900,
        "originalMimeType": "image/jpeg",
        "type": "IMAGE",
        "fileCreatedAt": created,
        "originalFileName": "test-%s.jpg" % asset_id[:4],
    } for asset_id, created in assets]
    return {"assets": {"count": len(items) if count is None else count, "items": items}}


class FakeImmich(ThreadingHTTPServer):
    """Threaded, with the per-run list delay kept on the server object."""

    daemon_threads = True
    slow = 0.0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # the harness prints its own assertions; access logs are noise
    def log_message(self, format, *args):  # noqa: A002 - signature is Qt's
        pass

    def _json(self, payload, code=200):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        try:
            request = json.loads(body or b"{}")
        except ValueError:
            request = {}

        if not self.path.startswith("/api/search/metadata"):
            self._json({}, 404)
            return

        # Page 1 is the whole library. Later pages, and any cursor walk, are
        # empty -- which is how immich.sh knows the walk is complete.
        finished = int(request.get("page") or 1) > 1 or bool(request.get("cursor"))
        # Only the first page is slow: the point is a list that is still running
        # when the key file changes, not a slow walk.
        if self.server.slow and not finished:
            time.sleep(self.server.slow)
        assets = [] if finished else LIBS.get(self.headers.get("x-api-key", ""), [])
        self._json(asset_payload(assets))

    def do_GET(self):
        if self.path.startswith("/api/server/version"):
            self._json({"major": 3, "minor": 4, "patch": 0})
            return
        if self.path.startswith("/api/albums"):
            self._json([])
            return
        if self.path.startswith("/api/assets/") and "/thumbnail" in self.path:
            self.send_response(200)
            self.send_header("content-type", "image/jpeg")
            self.send_header("content-length", str(len(THUMBNAIL)))
            self.end_headers()
            self.wfile.write(THUMBNAIL)
            return
        self._json({}, 404)


def start(slow=0.0):
    """Start the server on an ephemeral port. Returns (server, port)."""
    server = FakeImmich(("127.0.0.1", 0), Handler)
    server.slow = slow
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, server.server_address[1]


if __name__ == "__main__":
    import sys
    srv, port = start(slow=float(sys.argv[1]) if len(sys.argv) > 1 else 0.0)
    print("fake immich on 127.0.0.1:%d (keys: %s)" % (port, ", ".join(LIBS)))
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        srv.shutdown()
