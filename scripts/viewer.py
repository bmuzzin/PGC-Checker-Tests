#!/usr/bin/env python3
"""
Simple HTTP server to browse snapshots and view regression test diffs.
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
import json
import difflib

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(DIR)

TAGS_BASE_DIR = os.path.abspath(os.path.join(DIR, "..", "PGC-ChallengeCheckers", "tags"))
FAILURES_DIR = os.path.abspath(os.path.join(DIR, "failures"))
SNAPSHOTS_DIR = os.path.abspath(os.path.join(DIR, "snapshots"))

class SnapshotViewerHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        # 1. API: List all failed tags from latest regression run
        if path == "/api/failures":
            failed_tags = []
            failures_summary = {}
            if os.path.isdir(FAILURES_DIR):
                json_files = [f for f in os.listdir(FAILURES_DIR) if f.endswith(".json")]
                def _sort_tag_file(f):
                    try:
                        return int(f.replace(".json", ""))
                    except ValueError:
                        return 0
                for fname in sorted(json_files, key=_sort_tag_file):
                    if fname.endswith(".json"):
                        try:
                            tid = int(fname.replace(".json", ""))
                            fpath = os.path.join(FAILURES_DIR, fname)
                            with open(fpath, "r", encoding="utf-8") as f:
                                fdata = json.load(f)
                            failed_tags.append(tid)
                            profiles = list(fdata.get("profiles", {}).keys())
                            failures_summary[str(tid)] = {
                                "tag_id": tid,
                                "timestamp": fdata.get("timestamp"),
                                "profiles": profiles
                            }
                        except Exception:
                            pass

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            payload = json.dumps({
                "failed_tags": failed_tags,
                "failures": failures_summary
            }).encode("utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        # 2. API: Get detailed regression diff for a given tag & user
        m_diff = re.match(r"^/api/diff(?:/(\d+))?$", path)
        if m_diff:
            query_params = urllib.parse.parse_qs(parsed.query)
            tag_id_str = m_diff.group(1) or query_params.get("tag", [None])[0]
            user = query_params.get("user", [None])[0]
            if tag_id_str:
                tag_id = int(tag_id_str)
                fpath = os.path.join(FAILURES_DIR, f"{tag_id}.json")
                if os.path.exists(fpath):
                    with open(fpath, "r", encoding="utf-8") as f:
                        fdata = json.load(f)
                    profiles = fdata.get("profiles", {})
                    target_user = user if (user and user in profiles) else (list(profiles.keys())[0] if profiles else None)
                    prof_data = profiles.get(target_user, {}) if target_user else {}

                    exp = prof_data.get("expected") or {}
                    act = prof_data.get("actual") or {}
                    exp_html = exp.get("html", "")
                    act_html = act.get("html", "")
                    exp_log = exp.get("log", "")
                    act_log = act.get("log", "")

                    hd = difflib.HtmlDiff(tabsize=2)
                    table_html = hd.make_table(
                        exp_html.splitlines(),
                        act_html.splitlines(),
                        fromdesc=f"Expected / Snapshot ({target_user})",
                        todesc=f"Actual / Failed Run ({target_user})",
                        context=True,
                        numlines=3
                    )
                    table_log = hd.make_table(
                        exp_log.splitlines(),
                        act_log.splitlines(),
                        fromdesc=f"Expected / Snapshot ({target_user})",
                        todesc=f"Actual / Failed Run ({target_user})",
                        context=True,
                        numlines=3
                    )
                    unified_html = "\n".join(difflib.unified_diff(
                        exp_html.splitlines(), act_html.splitlines(),
                        fromfile=f"Expected ({target_user})", tofile=f"Actual ({target_user})",
                        lineterm=""
                    ))
                    unified_log = "\n".join(difflib.unified_diff(
                        exp_log.splitlines(), act_log.splitlines(),
                        fromfile=f"Expected ({target_user})", tofile=f"Actual ({target_user})",
                        lineterm=""
                    ))

                    diff_res = {
                        "tag_id": tag_id,
                        "user": target_user,
                        "available_users": list(profiles.keys()),
                        "has_failure": True,
                        "error": prof_data.get("error"),
                        "ok": {
                            "expected": exp.get("ok"),
                            "actual": act.get("ok"),
                            "match": prof_data.get("ok_match", exp.get("ok") == act.get("ok"))
                        },
                        "log_match": prof_data.get("log_match", exp_log == act_log),
                        "html_match": prof_data.get("html_match", exp_html == act_html),
                        "expected": exp,
                        "actual": act,
                        "unified_html": unified_html,
                        "unified_log": unified_log,
                        "table_html": table_html,
                        "table_log": table_log
                    }
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    payload = json.dumps(diff_res).encode("utf-8")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    payload = json.dumps({
                        "tag_id": tag_id,
                        "has_failure": False,
                        "message": f"No failure recorded for tag {tag_id}."
                    }).encode("utf-8")
                    self.send_header("Content-Length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return

        # 3. Allow fetching tag json by flat ID, e.g. /tags/81236.json
        m = re.match(r"^/tags/(\d+)\.json$", path)
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
print(f" PGC Snapshot & Diff Viewer running at:")
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
