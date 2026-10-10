#!/usr/bin/env python3
"""A stand-in for the sports hosts' header-only HLS rows, for the smoke on a build machine.

Serves the first pieces of a public test stream the way those hosts do (measured 2026-10-11):
each piece is a small PNG with the transport stream glued on behind it, named like a picture
(`…~tplv-origin.image?sig=…`), and nothing is served without the Referer the row names (403).
The engine alone refuses such a stream; the app's loopback playlist path must play it.

    python3 scripts/wrapped-hls.py 8899 &
    Nebula --smoke http://127.0.0.1:8899/t/abc/index.m3u8 --header 'Referer: https://iplayer.is/'
"""
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SOURCE = "https://test-streams.mux.dev/x36xhzz/url_2/193039199_mp4_h264_aac_ld_7.m3u8"
REFERER = "https://iplayer.is/"
PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452") + bytes(54)   # 70 bytes, like the real ones

text = urllib.request.urlopen(SOURCE, timeout=30).read().decode()
base = SOURCE.rsplit("/", 1)[0] + "/"
lines, pieces = [], []
for l in text.splitlines():
    if l and not l.startswith("#"):
        if len(pieces) >= 4:
            break
        pieces.append(PNG + urllib.request.urlopen(base + l, timeout=60).read())
        lines.append("https://127.0.0.1:%s/x/%d~tplv-tiktokx-origin.image?x-signature=a%%2Fb&t=1" % ("PORT", len(pieces) - 1))
    elif not l.startswith("#EXT-X-ENDLIST"):
        lines.append(l)
lines.append("#EXT-X-ENDLIST")
port = int(sys.argv[1]) if len(sys.argv) > 1 else 8899
playlist = "\n".join(lines).replace("https://127.0.0.1:PORT", "http://127.0.0.1:%d" % port).encode()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Referer") != REFERER:
            self.send_error(403)
            return
        if self.path.endswith("index.m3u8"):
            body, kind = playlist, "application/vnd.apple.mpegurl"
        elif self.path.startswith("/x/"):
            body, kind = pieces[int(self.path[3:].split("~")[0])], "image/png"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        sys.stderr.write("wrapped-hls: %s %s\n" % (self.path[:40], self.headers.get("Referer")))


server = ThreadingHTTPServer(("127.0.0.1", port), H)   # bound before it says so
print("serving %d wrapped pieces on %d" % (len(pieces), port), flush=True)
server.serve_forever()
