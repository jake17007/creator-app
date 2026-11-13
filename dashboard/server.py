#!/usr/bin/env python3
"""Live session recordings for the app.

A small local page that shows the app's screen recordings as they come in,
with a player and a list of what each person did. Only useful when analytics
is on (creator/app.json has analytics.posthogToken).

Run:   POSTHOG_PERSONAL_API_KEY=phx_... python3 dashboard/server.py
Open:  http://localhost:8792

It reads from the PostHog project the app reports to (analytics.posthogProjectId
in creator/app.json, or POSTHOG_PROJECT_ID) using a personal API key from
POSTHOG_PERSONAL_API_KEY (or POSTHOG_PERSONAL_AGENT_API_KEY). The key needs to
read session recordings and run queries. It never leaves this process: the
browser only talks to this server, which listens on localhost.

PostHog allows roughly 600 recording-data requests an hour per key, so this
server caches everything it has already downloaded and only asks for what is
new. If the limit is hit, the page keeps showing what it has.
"""

import base64
import html
import json
import os
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import OrderedDict, deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

# Who this copy of the app belongs to: written by ./configure.
try:
    with open(os.path.join(HERE, "..", "Generated", "creator.json"), encoding="utf-8") as _settings:
        CREATOR = json.load(_settings)
except FileNotFoundError:
    raise SystemExit("Generated/creator.json is missing. Run ./configure first.")

APP_NAME = CREATOR["app"]["name"]
NAME = CREATOR["creator"]["name"]
AGENT = CREATOR["agent"]["name"]

HOST = os.environ.get("POSTHOG_APP_HOST", "https://us.posthog.com").rstrip("/")
PROJECT = os.environ.get("POSTHOG_PROJECT_ID") or CREATOR["analytics"]["posthogProjectId"]
KEY = os.environ.get("POSTHOG_PERSONAL_API_KEY") or os.environ.get("POSTHOG_PERSONAL_AGENT_API_KEY") or ""
PORT = int(os.environ.get("DASH_PORT", "8792"))

APP = CREATOR["analytics"]["appTag"]   # the `app` property the iPhone app registers on every event
LIST_TTL = 8                # seconds one session list is reused
LIVE_WINDOW = 180           # seconds of silence before a session stops counting as live
MAX_FRAME_BYTES = 350e6     # recordings kept in memory before the oldest are dropped
SNAPSHOT_BUDGET = 560       # recording-data requests allowed per hour (PostHog's limit is ~600)
THUMB_RESERVE = 140         # of those, kept back for the session being watched

ID_RE = re.compile(r"[0-9a-fA-F-]{36}")


class PostHogError(Exception):
    def __init__(self, status, detail):
        super().__init__(f"{status}: {detail}")
        self.status = status
        self.detail = detail


def describe(error):
    if error.status == 429:
        return "PostHog is limiting requests for a moment. Showing what's already loaded."
    if error.status in (401, 403):
        return "PostHog rejected the API key (it needs to read session recordings and run queries)."
    if error.status == 0:
        return "Couldn't reach PostHog. Check the internet connection."
    return f"PostHog returned an error ({error.status})."


# ---------------------------------------------------------------- PostHog API

_spacing = threading.Lock()
_last_call = 0.0
_snapshot_calls = deque()


def ph(path, params=None, body=None, raw=False, timeout=45, snapshot=False):
    """One request to PostHog, spaced out so polling never arrives in a burst."""
    global _last_call
    url = HOST + path + ("?" + urllib.parse.urlencode(params) if params else "")
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(
        url, data=data,
        headers={"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
    with _spacing:
        wait = 0.25 - (time.time() - _last_call)
        if wait > 0:
            time.sleep(wait)
        _last_call = time.time()
        if snapshot:
            _snapshot_calls.append(_last_call)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise PostHogError(error.code, error.read()[:300].decode("utf-8", "replace"))
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise PostHogError(0, str(error))
    return payload if raw else json.loads(payload)


def snapshot_budget_left():
    cutoff = time.time() - 3600
    with _spacing:
        while _snapshot_calls and _snapshot_calls[0] < cutoff:
            _snapshot_calls.popleft()
        return SNAPSHOT_BUDGET - len(_snapshot_calls)


def hogql(query):
    # force_blocking: PostHog otherwise answers a repeated query from its cache,
    # which makes a live session look frozen.
    return ph(f"/api/projects/{PROJECT}/query/",
              body={"query": {"kind": "HogQLQuery", "query": query},
                    "refresh": "force_blocking"}).get("results", [])


def since_clause(start_seconds, margin=86400):
    """Limits a query to events from around a session, so it stays quick."""
    if not start_seconds:
        return "timestamp > now() - interval 35 day"
    return f"timestamp > toDateTime({int(start_seconds - margin)})"


def parse_ts(value):
    """ISO time from PostHog -> seconds since 1970 (None if unreadable)."""
    if not value or not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


# ---------------------------------------------------------------- session list

_list_lock = threading.Lock()
_list = {"at": 0.0, "data": None}
_activity = {}   # session id -> {"end", "last_ts", "last_event", "build"}


def refresh_activity(recordings):
    """What each session did last, so "live" means the app is really still open."""
    need = [
        r["id"] for r in recordings
        if ID_RE.fullmatch(r["id"]) and (
            r.get("ongoing") or (_activity.get(r["id"]) or {}).get("end") != r.get("end_time"))
    ]
    if not need:
        return
    need = need[:80]
    ids = ", ".join(f"'{i}'" for i in need)
    starts = [parse_ts(r.get("start_time")) for r in recordings if r["id"] in need]
    earliest = min([s for s in starts if s] or [0])
    try:
        rows = hogql(
            "select $session_id, max(timestamp), argMax(event, timestamp), max(properties.build_type) "
            f"from events where $session_id in ({ids}) and {since_clause(earliest)} "
            "group by $session_id")
    except PostHogError:
        return
    found = {row[0]: row for row in rows}
    ends = {r["id"]: r.get("end_time") for r in recordings}
    for session_id in need:
        row = found.get(session_id)
        _activity[session_id] = {
            "end": ends.get(session_id),
            "last_ts": parse_ts(row[1]) if row else None,
            "last_event": row[2] if row else None,
            "build": (row[3] if row else None) or "",
        }


def shape(recording, now):
    person = recording.get("person") or {}
    props = person.get("properties") or {}
    start = parse_ts(recording.get("start_time"))
    end = parse_ts(recording.get("end_time"))
    activity = _activity.get(recording["id"]) or {}
    last = max([t for t in (end, activity.get("last_ts")) if t] or [0])
    left_app = activity.get("last_event") == "Application Backgrounded"
    live = not left_app and now - last < LIVE_WINDOW
    return {
        "id": recording["id"],
        "name": (props.get("name") or "").strip() or "Not signed in",
        "creator": bool(props.get("is_creator")),
        "start": start * 1000 if start else None,
        "end": end * 1000 if end else None,
        "duration": recording.get("recording_duration") or 0,
        "active": recording.get("active_seconds") or 0,
        "taps": recording.get("click_count") or 0,
        "live": live,
        "build": activity.get("build") or "",
        "version": props.get("$app_version") or "",
        "os": " ".join(str(x) for x in (props.get("$os"), props.get("$os_version")) if x),
        "url": f"{HOST}/project/{PROJECT}/replay/{recording['id']}",
    }


def list_sessions():
    with _list_lock:
        if _list["data"] is not None and time.time() - _list["at"] < LIST_TTL:
            return _list["data"]
        # Matched on the events, not the person, so sessions from someone who
        # never got as far as signing in are listed too.
        only_this_app = json.dumps(
            [{"key": "app", "value": [APP], "operator": "exact", "type": "event"}])
        try:
            page = ph(f"/api/projects/{PROJECT}/session_recordings/",
                      {"limit": 60, "properties": only_this_app})
        except PostHogError as error:
            if _list["data"] is not None:
                return {**_list["data"], "warning": describe(error)}
            raise
        recordings = page.get("results", [])
        refresh_activity(recordings)
        now = time.time()
        sessions = [shape(r, now) for r in recordings if ID_RE.fullmatch(r.get("id", ""))]
        sessions.sort(key=lambda s: s["start"] or 0, reverse=True)
        data = {"now": now * 1000, "sessions": sessions}
        _list.update(at=now, data=data)
        return data


# ---------------------------------------------------------------- one recording

class Recording:
    def __init__(self, recording_id):
        self.id = recording_id
        self.lock = threading.Lock()
        self.blobs = set()        # chunks already downloaded
        self.known = []           # every chunk key PostHog has, in order
        self.frames = {}          # timestamp (ms) -> (image bytes, mime type)
        self.touches = []         # {"t", "x", "y", "ex", "ey"}
        self._open_touch = {}     # finger id -> touch still down
        self.width, self.height = 402, 874
        self.bytes = 0
        self.checked_at = 0.0
        self.events = []
        self.events_at = 0.0


_recordings = OrderedDict()
_recordings_lock = threading.Lock()


def recording(recording_id):
    with _recordings_lock:
        rec = _recordings.get(recording_id)
        if rec is None:
            rec = _recordings[recording_id] = Recording(recording_id)
        else:
            _recordings.move_to_end(recording_id)
        # Drop the recordings that were opened longest ago once memory fills up.
        while len(_recordings) > 1 and sum(r.bytes for r in _recordings.values()) > MAX_FRAME_BYTES:
            _recordings.popitem(last=False)
        return rec


def decode_image(value):
    if not isinstance(value, str) or len(value) < 100:
        return None
    mime = None
    if value.startswith("data:"):
        head, _, value = value.partition(",")
        match = re.match(r"data:(image/[\w+.-]+)", head)
        mime = match.group(1) if match else None
    try:
        data = base64.b64decode(value)
    except ValueError:
        return None
    if mime is None:
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            mime = "image/webp"
        elif data[:3] == b"\xff\xd8\xff":
            mime = "image/jpeg"
        elif data[:8] == b"\x89PNG\r\n\x1a\n":
            mime = "image/png"
        else:
            return None
    return data, mime


def parse_chunk(rec, raw):
    """Adds one downloaded chunk's screenshots and touches to the recording."""
    for line in raw.decode("utf-8", "replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            item = json.loads(line)
        except ValueError:
            continue
        event = item[1] if isinstance(item, list) and len(item) == 2 else item
        if not isinstance(event, dict):
            continue
        ts, kind, data = event.get("timestamp"), event.get("type"), event.get("data")
        if not isinstance(ts, (int, float)) or not isinstance(data, dict):
            continue
        ts = int(ts)

        if kind == 4:                                   # screen size
            rec.width = data.get("width") or rec.width
            rec.height = data.get("height") or rec.height
            continue

        wireframes = []
        if kind == 2:                                   # full screenshot
            wireframes = data.get("wireframes") or []
        elif kind == 3:
            if data.get("source") == 2:                 # finger down / up
                finger = data.get("id", 0)
                x, y = data.get("x"), data.get("y")
                if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
                    continue
                if data.get("type") == 7:
                    touch = {"t": ts, "x": x, "y": y, "ex": x, "ey": y}
                    rec._open_touch[finger] = touch
                    rec.touches.append(touch)
                elif data.get("type") == 9 and finger in rec._open_touch:
                    touch = rec._open_touch.pop(finger)
                    touch["ex"], touch["ey"] = x, y
                continue
            for update in (data.get("updates") or []) + (data.get("adds") or []):
                if isinstance(update, dict) and isinstance(update.get("wireframe"), dict):
                    wireframes.append(update["wireframe"])

        for wireframe in wireframes:
            image = decode_image(wireframe.get("base64")) if isinstance(wireframe, dict) else None
            if image and ts not in rec.frames:
                rec.frames[ts] = image
                rec.bytes += len(image[0])
                break


def chunk_runs(keys, size=8):
    """Groups chunk keys into consecutive runs, so several download in one request."""
    numeric = sorted(int(k) for k in keys if str(k).isdigit())
    runs, run = [], []
    for key in numeric:
        if run and (key != run[-1] + 1 or len(run) >= size):
            runs.append(run)
            run = []
        run.append(key)
    if run:
        runs.append(run)
    return runs


def fetch_chunks(rec, keys):
    base = f"/api/projects/{PROJECT}/session_recordings/{rec.id}/snapshots"
    for run in chunk_runs(keys):
        raw = ph(base, {"source": "blob_v2", "start_blob_key": run[0], "end_blob_key": run[-1]},
                 raw=True, timeout=120, snapshot=True)
        parse_chunk(rec, raw)
        rec.blobs.update(str(k) for k in run)
    rec.touches.sort(key=lambda t: t["t"])


def refresh_known(rec):
    base = f"/api/projects/{PROJECT}/session_recordings/{rec.id}/snapshots"
    sources = ph(base, snapshot=True).get("sources", [])
    rec.known = [str(s.get("blob_key")) for s in sources if s.get("source") == "blob_v2"]
    rec.checked_at = time.time()


def load_all(rec, max_age=4):
    """Downloads whatever part of the recording isn't in memory yet."""
    with rec.lock:
        if time.time() - rec.checked_at >= max_age:
            refresh_known(rec)
        missing = [k for k in rec.known if k not in rec.blobs]
        if missing:
            fetch_chunks(rec, missing)


def load_latest(rec, max_age=45):
    """Just enough for a thumbnail: the newest chunks that contain a screenshot."""
    with rec.lock:
        if time.time() - rec.checked_at >= max_age:
            refresh_known(rec)
        newest = max(rec.frames) if rec.frames else None
        for key in reversed(rec.known[-3:]):
            if key not in rec.blobs:
                fetch_chunks(rec, [key])
            if rec.frames and (newest is None or max(rec.frames) > newest):
                break


EVENT_LABELS = {
    "Application Installed": "Opened the app for the first time",
    "Application Updated": "Opened the app after an update",
    "Application Opened": "Opened the app",
    "Application Backgrounded": "Left the app",
    "$identify": "Signed in",
    "$rageclick": "Tapped the same spot over and over",
    "goal_added": "Added a goal",
    "video_played": "Played a video",
    "ask_about_post": f"Tapped Ask {AGENT} on a post",
    "post_created": "Posted to the feed",
}


def label(name, screen, about_post, answer, as_creator):
    if name == "$screen":
        return f"Opened {screen}" if screen else None
    if name == "agent_message_sent":
        return f"Messaged {AGENT} about a post" if about_post else f"Messaged {AGENT}"
    if name == "dm_sent":
        return "Replied to a member" if as_creator else f"Messaged {NAME}"
    if name == "replay_consent":
        return {"allowed": "Allowed screen recordings",
                "declined": "Turned screen recordings off"}.get(answer, "Answered the recording question")
    if name in EVENT_LABELS:
        return EVENT_LABELS[name]
    if name.startswith("$"):
        return None
    return name.replace("_", " ").capitalize()


def session_start(recording_id):
    for session in (_list["data"] or {}).get("sessions", []):
        if session["id"] == recording_id and session["start"]:
            return session["start"] / 1000
    return None


def load_events(rec, max_age=8):
    if time.time() - rec.events_at < max_age:
        return
    rows = hogql(
        "select timestamp, event, properties.$screen_name, properties.about_post, "
        "properties.answer, properties.as_creator from events "
        f"where $session_id = '{rec.id}' and {since_clause(session_start(rec.id))} "
        "order by timestamp limit 800")
    events = []
    for timestamp, name, screen, about_post, answer, as_creator in rows:
        ts, text = parse_ts(timestamp), label(name or "", screen, about_post, answer, as_creator)
        if ts and text:
            events.append({"t": int(ts * 1000), "label": text})
    rec.events = events
    rec.events_at = time.time()


def detail(recording_id):
    rec = recording(recording_id)
    warning = None
    try:
        load_all(rec)
    except PostHogError as error:
        warning = describe(error)
    try:
        load_events(rec)
    except PostHogError as error:
        warning = warning or describe(error)
    with rec.lock:
        frames, touches = sorted(rec.frames), list(rec.touches)
    return {
        "id": recording_id,
        "width": rec.width,
        "height": rec.height,
        "frames": frames,
        "touches": touches,
        "events": rec.events,
        "warning": warning,
    }


def is_live(recording_id):
    sessions = (_list["data"] or {}).get("sessions", [])
    return any(s["id"] == recording_id and s["live"] for s in sessions)


def thumbnail(recording_id):
    """The newest screenshot. A finished session's is downloaded once and kept;
    a live one is refreshed while there is request budget to spare."""
    rec = recording(recording_id)
    budget = snapshot_budget_left()
    wanted = (not rec.frames and budget > 40) or (is_live(recording_id) and budget > THUMB_RESERVE)
    if wanted:
        try:
            load_latest(rec)
        except PostHogError:
            pass
    with rec.lock:
        return rec.frames[max(rec.frames)] if rec.frames else None


# ---------------------------------------------------------------- web server

class Handler(BaseHTTPRequestHandler):
    server_version = "CreatorAppSessions/1.0"

    def log_message(self, *args):
        pass

    def send(self, status, body, content_type, cache="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, payload, status=200):
        self.send(status, json.dumps(payload).encode(), "application/json")

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            if path in ("/", "/index.html"):
                with open(os.path.join(HERE, "index.html"), encoding="utf-8") as page:
                    html_page = page.read().replace("__APP_NAME__", html.escape(APP_NAME))
                return self.send(200, html_page.encode("utf-8"), "text/html; charset=utf-8")
            if path == "/api/sessions":
                if not KEY:
                    return self.send_json({"error": "No PostHog API key. Start this server with "
                                           "POSTHOG_PERSONAL_API_KEY set."}, 503)
                if not PROJECT:
                    return self.send_json({"error": "No PostHog project id. Add analytics.posthogProjectId to "
                                           "creator/app.json and run ./configure."}, 503)
                return self.send_json(list_sessions())

            parts = path.strip("/").split("/")
            if len(parts) >= 3 and parts[:2] == ["api", "sessions"] and ID_RE.fullmatch(parts[2]):
                recording_id = parts[2]
                if len(parts) == 3:
                    return self.send_json(detail(recording_id))
                if len(parts) == 4 and parts[3] == "thumb":
                    image = thumbnail(recording_id)
                    if image is None:
                        return self.send(404, b"", "text/plain")
                    return self.send(200, image[0], image[1], "private, max-age=300")
                if len(parts) == 5 and parts[3] == "frame" and parts[4].isdigit():
                    image = recording(recording_id).frames.get(int(parts[4]))
                    if image is None:
                        return self.send(404, b"", "text/plain")
                    return self.send(200, image[0], image[1], "private, max-age=86400")
            self.send(404, b"Not found", "text/plain")
        except PostHogError as error:
            self.send_json({"error": describe(error)}, 502)
        except Exception as error:   # keep the server up; show the problem on the page
            self.send_json({"error": f"Something went wrong here: {error}"}, 500)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"{APP_NAME} sessions: http://localhost:{PORT}" + ("" if KEY else "  (no PostHog key set)"), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
