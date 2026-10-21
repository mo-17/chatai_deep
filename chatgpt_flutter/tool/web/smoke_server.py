#!/usr/bin/env python3
"""Loopback-only deterministic CORS/SSE fixture. Never forwards requests."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass  # Do not log headers, bodies or credentials.

    def cors(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers',
                         'Authorization, Content-Type, OpenAI-Organization')

    def do_OPTIONS(self):
        self.send_response(204)
        self.cors()
        self.end_headers()

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if size > 1024 * 1024 or self.path != '/v1/chat/completions':
            self.send_error(400)
            return
        body = json.loads(self.rfile.read(size))
        model = body.get('model')
        if model == 'web-delay':
            time.sleep(1)
        status = 429 if model == 'web-error' else 200
        self.send_response(status)
        self.cors()
        streaming = bool(body.get('stream'))
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8' if streaming
                         else 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-cache')
        self.end_headers()
        try:
            if status != 200:
                self.wfile.write(b'{"error":{"code":"rate_limit_exceeded"}}')
                return
            if not streaming:
                self.wfile.write(json.dumps({
                    'id': 'local-web-smoke', 'object': 'chat.completion',
                    'model': model,
                    'choices': [{'index': 0, 'message': {'role': 'assistant',
                        'content': '浏览器连接成功'}, 'finish_reason': 'stop'}],
                    'usage': {'prompt_tokens': 9, 'completion_tokens': 5},
                }, ensure_ascii=False).encode())
                return
            self.event({'choices': [{'delta': {'reasoning_content': '测试推理'}}]})
            if model == 'web-hold':
                time.sleep(8)
            for part in ['浏览器', '流式', '成功']:
                self.event({'choices': [{'delta': {'content': part}}]})
                time.sleep(0.05)
            if model == 'web-stream':
                self.event({'choices': [{'delta': {'tool_calls': [{
                    'index': 0, 'id': 'call_test', 'type': 'function',
                    'function': {'name': 'calculator', 'arguments': '{"expression":"1+1"}'}}]}}]})
            self.event({'choices': [], 'usage': {'prompt_tokens': 9, 'completion_tokens': 5}})
            self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def event(self, value):
        data = ('data: ' + json.dumps(value, ensure_ascii=False) + '\n\n').encode()
        # Deliberately split a multibyte UTF-8 character across network chunks.
        start = data.find('浏'.encode())
        split = start + 1 if start >= 0 else len(data) // 2
        self.wfile.write(data[:split])
        self.wfile.flush()
        time.sleep(0.01)
        self.wfile.write(data[split:])
        self.wfile.flush()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=48352)
    args = parser.parse_args()
    print(f'Local Web smoke fixture: http://127.0.0.1:{args.port}', flush=True)
    ThreadingHTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
