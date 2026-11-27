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

def get_script_failures_dir(script_id):
    fdir = os.path.join(DIR, "failures", str(script_id))
    if os.path.isdir(fdir):
        return fdir
    if str(script_id) == "9976":
        return FAILURES_DIR
    return fdir

def get_script_snapshots_dir(script_id):
    sdir = os.path.join(DIR, "snapshots", str(script_id))
    if os.path.isdir(sdir):
        return sdir
    if str(script_id) == "9976":
        return SNAPSHOTS_DIR
    return sdir

_diff_cache = {}

class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64

class SnapshotViewerHandler(http.server.SimpleHTTPRequestHandler):
    timeout = 15

    def log_message(self, format, *args):
        # Keep console output clean, only log errors or important events if desired
        pass

    def send_json_response(self, obj, status=200):
        try:
            payload = json.dumps(obj).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        try:
            self._handle_GET()
        except (BrokenPipeError, ConnectionResetError):
            # Client closed the connection early (e.g. user refreshed or selected another tag)
            pass

    def _handle_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query_params = urllib.parse.parse_qs(parsed.query)
        script_id = query_params.get("script", ["9976"])[0]

        # 1. API: List all failed tags from latest regression run
        if path == "/api/failures":
            failed_tags = []
            failures_summary = {}
            target_failures_dir = get_script_failures_dir(script_id)
            if os.path.isdir(target_failures_dir):
                json_files = [f for f in os.listdir(target_failures_dir) if f.endswith(".json")]
                def _sort_tag_file(f):
                    try:
                        return int(f.replace(".json", ""))
                    except ValueError:
                        return 0
                for fname in sorted(json_files, key=_sort_tag_file):
                    if fname.endswith(".json"):
                        try:
                            tid = int(fname.replace(".json", ""))
                            fpath = os.path.join(target_failures_dir, fname)
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

            self.send_json_response({
                "script_id": script_id,
                "failed_tags": failed_tags,
                "failures": failures_summary
            })
            return

        # 2. API: Get detailed regression diff for a given tag & user
        m_diff = re.match(r"^/api/diff(?:/(\d+))?$", path)
        if m_diff:
            tag_id_str = m_diff.group(1) or query_params.get("tag", [None])[0]
            user = query_params.get("user", [None])[0]
            if tag_id_str:
                tag_id = int(tag_id_str)
                target_failures_dir = get_script_failures_dir(script_id)
                fpath = os.path.join(target_failures_dir, f"{tag_id}.json")
                if os.path.exists(fpath):
                    mtime = os.path.getmtime(fpath)
                    cache_key = (tag_id, user, mtime)
                    if cache_key in _diff_cache:
                        self.send_json_response(_diff_cache[cache_key])
                        return

                    with open(fpath, "r", encoding="utf-8") as f:
                        fdata = json.load(f)
                    profiles = fdata.get("profiles", {})
                    target_user = user if (user and user in profiles) else (list(profiles.keys())[0] if profiles else None)
                    prof_data = profiles.get(target_user, {}) if target_user else {}

                    exp = prof_data.get("expected") or {}
                    act = prof_data.get("actual") or {}
                    exp_html = exp.get("html", "") or ""
                    act_html = act.get("html", "") or ""
                    exp_log = exp.get("log", "") or ""
                    act_log = act.get("log", "") or ""

                    # Avoid expensive difflib computation when strings are identical
                    hd = difflib.HtmlDiff(tabsize=2)
                    if exp_html == act_html:
                        table_html = ""
                        unified_html = ""
                    else:
                        exp_h_lines = exp_html.splitlines()
                        act_h_lines = act_html.splitlines()
                        # Cap at 5000 lines for diff calculation to prevent freezing
                        if len(exp_h_lines) > 5000 or len(act_h_lines) > 5000:
                            exp_h_lines = exp_h_lines[:5000]
                            act_h_lines = act_h_lines[:5000]
                        table_html = hd.make_table(
                            exp_h_lines,
                            act_h_lines,
                            fromdesc=f"Expected / Snapshot ({target_user})",
                            todesc=f"Actual / Failed Run ({target_user})",
                            context=True,
                            numlines=3
                        )
                        unified_html = "\n".join(difflib.unified_diff(
                            exp_h_lines, act_h_lines,
                            fromfile=f"Expected ({target_user})", tofile=f"Actual ({target_user})",
                            lineterm=""
                        ))

                    if exp_log == act_log:
                        table_log = ""
                        unified_log = ""
                    else:
                        exp_l_lines = exp_log.splitlines()
                        act_l_lines = act_log.splitlines()
                        if len(exp_l_lines) > 5000 or len(act_l_lines) > 5000:
                            exp_l_lines = exp_l_lines[:5000]
                            act_l_lines = act_l_lines[:5000]
                        table_log = hd.make_table(
                            exp_l_lines,
                            act_l_lines,
                            fromdesc=f"Expected / Snapshot ({target_user})",
                            todesc=f"Actual / Failed Run ({target_user})",
                            context=True,
                            numlines=3
                        )
                        unified_log = "\n".join(difflib.unified_diff(
                            exp_l_lines, act_l_lines,
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
                    _diff_cache[cache_key] = diff_res
                    self.send_json_response(diff_res)
                    return
                else:
                    self.send_json_response({
                        "tag_id": tag_id,
                        "has_failure": False,
                        "message": f"No failure recorded for tag {tag_id}."
                    })
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
                try:
                    with open(tag_path, "rb") as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return

        # 4. Allow fetching snapshot json by tag ID, e.g. /snapshots/81236.json
        m_snap = re.match(r"^/snapshots/(?:(\w+)/)?(\d+)\.json$", path)
        if m_snap:
            sid_in_path = m_snap.group(1) or script_id
            tag_id = int(m_snap.group(2))
            target_snapshots_dir = get_script_snapshots_dir(sid_in_path)
            snap_path = os.path.join(target_snapshots_dir, f"{tag_id}.json")
            if not os.path.exists(snap_path) and (sid_in_path == "9976" or sid_in_path == 9976):
                snap_path = os.path.join(SNAPSHOTS_DIR, f"{tag_id}.json")
            if os.path.exists(snap_path):
                try:
                    with open(snap_path, "rb") as f:
                        data = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Access-Control-Allow-Origin", "*")
                    self.send_header("Content-Length", str(len(data)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass
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
    with ThreadedHTTPServer(("", PORT), Handler) as httpd:
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
