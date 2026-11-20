#!/usr/bin/env python3
"""
Simple HTTP server to browse snapshots.
Usage:
    python3 scripts/viewer.py [port]
"""
import http.server
import socketserver
import os
import re
import urllib.parse
import webbrowser
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(DIR)

TAGS_BASE_DIR = os.path.abspath(os.path.join(DIR, "..", "PGC-ChallengeCheckers", "tags"))

class SnapshotViewerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        # Allow fetching tag json by flat ID, e.g. /tags/81236.json
        parsed = urllib.parse.urlparse(self.path)
        m = re.match(r"^/tags/(\d+)\.json$", parsed.path)
        if m:
            tag_id = int(m.group(1))
            start = (tag_id // 1000) * 1000
            end = start + 999
            subdir = f"{start:08d}-{end:08d}"
            tag_path = os.path.join(TAGS_BASE_DIR, subdir, f"{tag_id}.json")
            if os.path.exists(tag_path):
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Access-Control-Allow-Origin", "*")
                with open(tag_path, "rb") as f:
                    data = f.read()
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
                return

        return super().do_GET()

Handler = SnapshotViewerHandler
Handler.extensions_map.update({
    ".json": "application/json",
})

url = f"http://localhost:{PORT}/viewer.html"
print("==================================================")
print(f" PGC Snapshot Viewer running at:")
print(f"   {url}")
print(" Press Ctrl+C to stop.")
print("==================================================")

try:
    with socketserver.TCPServer(("", PORT), Handler) as httpd:
        try:
            webbrowser.open(url)
        except Exception:
            pass
        httpd.serve_forever()
except KeyboardInterrupt:
    print("\nServer stopped.")
except OSError as e:
    if "Address already in use" in str(e):
        print(f"Port {PORT} is already in use. Try: python3 scripts/viewer.py {PORT + 1}")
    else:
        raise
