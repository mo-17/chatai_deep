#!/usr/bin/env python3
"""仅回环、确定性的 OCR HTTP 合同测试；不识别文件、不转发请求。"""
import hashlib
import argparse
import base64
import json
from pathlib import Path
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

jobs = {}
events = []
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def headers_for_cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Authorization, Content-Type')

    def reply(self, data, status=200):
        raw = json.dumps({'code': 0, 'data': data}, ensure_ascii=False).encode()
        self.send_response(status)
        self.headers_for_cors()
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self.send_response(204)
        self.headers_for_cors()
        self.end_headers()

    def do_GET(self):
        self.handle_request('GET')

    def do_POST(self):
        self.handle_request('POST')

    def do_DELETE(self):
        self.handle_request('DELETE')

    def handle_request(self, method):
        path = urlsplit(self.path).path
        if method == 'GET' and path == '/sqlite3.wasm':
            raw = (Path(__file__).resolve().parents[2] / 'web/sqlite3.wasm').read_bytes()
            self.send_response(200)
            self.headers_for_cors()
            self.send_header('Content-Type', 'application/wasm')
            self.send_header('Content-Length', str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        body = b''
        if method == 'POST':
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 8 * 1024 * 1024:
                return self.reply({}, 413)
            body = self.rfile.read(size)
            if body == b'delayed':
                time.sleep(1)
        with lock:
            if path == '/events':
                if method == 'DELETE':
                    events.clear()
                    jobs.clear()
                return self.reply({'events': events.copy()})
            if path == '/uapi/ocr/capabilities':
                return self.reply({'available': True})
            match = re.fullmatch('/uapi/ocr/jobs/([a-f0-9]{32})', path)
            if not match:
                return self.reply({}, 404)
            job_id = match[1]
            event = {'method': method, 'id': job_id}
            if method == 'POST':
                preview = parse_qs(urlsplit(self.path).query).get('preview') == ['true']
                event.update(size=len(body), sha256=hashlib.sha256(body).hexdigest(), preview=preview)
                if jobs.get(job_id, {}).get('state') == 'cancelled':
                    events.append({**event, 'rejected': True})
                    return self.reply(jobs[job_id], 409)
                jobs[job_id] = {'id': job_id, 'state': 'queued', 'hold': body == b'hold', 'preview': preview}
            elif method == 'DELETE':
                jobs[job_id] = {'id': job_id, 'state': 'cancelled'}
            elif job_id not in jobs:
                return self.reply({}, 404)
            elif jobs[job_id]['state'] == 'queued' and not jobs[job_id]['hold']:
                detail = {'width': 100, 'height': 200, 'lines': [{'text': '浏览器 OCR 合同验证', 'confidence': .7, 'box': [[1, 2], [90, 2], [90, 20], [1, 20]]}]}
                if jobs[job_id]['preview']:
                    # 仅验证二进制协议；真实 JPEG 解码/模型质量由 engine 测试覆盖。
                    detail['preview'] = base64.b64encode(b'\xff\xd8\xff\x00').decode()
                jobs[job_id] = {'id': job_id, 'state': 'completed', 'result': {
                    'totalPages': 1, 'pages': [{'page': 1, 'text': '浏览器 OCR 合同验证', **detail}]}}
            events.append(event)
            self.reply({k: v for k, v in jobs[job_id].items() if k != 'hold'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=48353)
    ThreadingHTTPServer(('127.0.0.1', parser.parse_args().port), Handler).serve_forever()
