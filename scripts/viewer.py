#!/usr/bin/env python3
"""
Simple HTTP server to browse snapshots.
Usage:
    python3 scripts/viewer.py [port]
"""
import http.server
import socketserver
import os
import webbrowser
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(DIR)

Handler = http.server.SimpleHTTPRequestHandler
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
