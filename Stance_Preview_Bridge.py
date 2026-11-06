import argparse
import math
import secrets
import json
import re
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

MAX_BYTES = 1800000
JOBS = {}
QUEUE = deque()
LOCK = threading.RLock()
TOKEN = secrets.token_hex(16)
VALID_ID = re.compile(r'^[0-9]{1,20}$')


def validate_clip(value, animation_id):
    if not isinstance(value, dict) or value.get('version') != 1 or str(value.get('animationId')) != animation_id:
        return False
    duration = value.get('duration')
    if not isinstance(duration, (float, int)) or not math.isfinite(duration) or not 0 < duration <= 240:
        return False
    tracks = value.get('tracks')
    if not isinstance(tracks, dict) or not tracks:
        return False
    for name, keys in tracks.items():
        if not isinstance(name, str) or len(name) > 64 or not isinstance(keys, list) or len(keys) > 1000:
            return False
        for key in keys:
            if not isinstance(key, list) or len(key) != 2 or not isinstance(key[0], (int, float)) or not math.isfinite(key[0]) or not 0 <= key[0] <= duration + .01:
                return False
            if not isinstance(key[1], list) or len(key[1]) != 12 or any(not isinstance(v, (int, float)) or not math.isfinite(v) or abs(v) > 10000 for v in key[1]):
                return False
    return True


class Bridge(BaseHTTPRequestHandler):
    server_version = 'StanceLocalPreview/1'

    def log_message(self, *_args):
        pass

    def send(self, status, value, raw=False):
        payload = value if raw else json.dumps(value, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        route = urlsplit(self.path)
        if route.path == '/v1/health':
            self.send(200, {'status': 'ready', 'service': 'stance-preview-bridge', 'version': 1, 'workerToken': TOKEN})
            return
        if route.path == '/v1/next':
            job = None
            with LOCK:
                while QUEUE:
                    animation_id = QUEUE.popleft()
                    state = JOBS.get(animation_id)
                    if state and state['status'] == 'queued':
                        state.update(status='processing', started=time.monotonic())
                        job = {'animationId': animation_id}
                        break
            self.send(200, job or {'status': 'idle'})
            return
        if route.path != '/v1/preview':
            self.send(404, {'status': 'error', 'message': 'Unknown route'})
            return
        animation_id = parse_qs(route.query).get('id', [''])[0]
        if not VALID_ID.fullmatch(animation_id):
            self.send(400, {'status': 'error', 'message': 'Invalid animation ID'})
            return
        filename = self.server.cache / (animation_id + '.json')
        if filename.is_file():
            try:
                payload = filename.read_bytes()
                if len(payload) <= MAX_BYTES and validate_clip(json.loads(payload), animation_id):
                    self.send(200, payload, raw=True)
                    return
            except (ValueError, OSError, UnicodeError):
                pass
        with LOCK:
            state = JOBS.get(animation_id)
            if state and state['status'] == 'processing' and time.monotonic() - state['started'] > 65:
                JOBS.pop(animation_id, None)
                state = None
            if state is None and len(JOBS) >= 64:
                self.send(429, {'status': 'error', 'message': 'Preview queue is full'})
                return
            if state is None:
                state = {'status': 'queued', 'started': time.monotonic(), 'message': 'Waiting for Studio'}
                JOBS[animation_id] = state
                QUEUE.append(animation_id)
            if state['status'] == 'error' and time.monotonic() - state['started'] > 10:
                JOBS.pop(animation_id, None)
                QUEUE.append(animation_id)
                state = {'status': 'queued', 'started': time.monotonic(), 'message': 'Retrying in Studio'}
                JOBS[animation_id] = state
            info = {'status': state['status'], 'animationId': animation_id}
            if state.get('message'):
                info['message'] = state['message'][:160]
        self.send(200, info)

    def do_POST(self):
        if urlsplit(self.path).path != '/v1/result':
            self.send(404, {'status': 'error', 'message': 'Unknown route'})
            return
        try:
            n = int(self.headers.get('Content-Length', '-1'))
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BYTES:
            self.send(413, {'status': 'error', 'message': 'Invalid payload size'})
            return
        try:
            result = json.loads(self.rfile.read(n))
            animation_id = str(result.get('animationId', ''))
            if not VALID_ID.fullmatch(animation_id):
                raise ValueError('Invalid animation ID')
            if result.get('workerToken') != TOKEN:
                self.send(403, {'status': 'error', 'message': 'Studio worker token is missing'})
                return
            with LOCK:
                state = JOBS.get(animation_id)
                if not state or state['status'] != 'processing':
                    self.send(409, {'status': 'error', 'message': 'No corresponding active request'})
                    return
            if result.get('status') == 'ok' and validate_clip(result.get('payload'), animation_id):
                out = self.server.cache / (animation_id + '.json')
                raw = json.dumps(result['payload'], separators=(',', ':')).encode()
                if len(raw) > MAX_BYTES:
                    raise ValueError('Clip too large')
                out.write_bytes(raw)
                with LOCK:
                    JOBS.pop(animation_id, None)
                self.send(200, {'status': 'saved', 'animationId': animation_id})
            else:
                msg = str(result.get('message') or 'Clip not accessible or not a KeyframeSequence')[:160]
                with LOCK:
                    state.update(status='error', message=msg, started=time.monotonic())
                self.send(200, {'status': 'error', 'animationId': animation_id, 'message': msg})
        except (ValueError, TypeError, OSError, UnicodeError) as exc:
            self.send(400, {'status': 'error', 'message': str(exc)[:160]})


def main():
    parser = argparse.ArgumentParser(description='Stance independent animation preview bridge (local-only)')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--cache', type=Path, default=Path(__file__).with_name('StancePreviewCache'))
    options = parser.parse_args()
    options.cache.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('127.0.0.1', options.port), Bridge)
    server.cache = options.cache
    print('Stance Preview Bridge: http://127.0.0.1:%s' % options.port)
    print('Cached animation keyframes: ' + str(options.cache.resolve()))
    print('Keep this open, then start the Studio companion script.')
    try:
        server.serve_forever(poll_interval=.25)
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == '__main__':
    main()
