"""仅回环监听的 OCR worker。任务有界、单并发、取消杀进程、终态删除原件。"""
import hashlib
import hmac
import json
import multiprocessing
import os
import re
import shutil
import tempfile
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from engine import run

MAX_BYTES = 8 * 1024 * 1024
TERMINAL = {"completed", "failed", "cancelled"}
TTL = 300
TIMEOUT = 180


def validate_settings(value):
    if not isinstance(value, dict) or set(value) != {"ownerHourly", "globalHourly", "ownerOverrides"}:
        raise Failure(400, "invalid_request")
    if (type(value["ownerHourly"]) is not int or not 0 <= value["ownerHourly"] <= 200 or
            type(value["globalHourly"]) is not int or not 1 <= value["globalHourly"] <= 1000):
        raise Failure(400, "invalid_request")
    overrides = value["ownerOverrides"]
    if not isinstance(overrides, dict) or len(overrides) > 100:
        raise Failure(400, "invalid_request")
    for owner, limit in overrides.items():
        if not re.fullmatch(r"(?:user|admin):[1-9][0-9]{0,15}", owner) or type(limit) is not int or not 0 <= limit <= 200:
            raise Failure(400, "invalid_request")
    return {"ownerHourly": value["ownerHourly"], "globalHourly": value["globalHourly"], "ownerOverrides": dict(overrides)}


class Failure(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


class Jobs:
    def __init__(self, root, target=run, timeout=TIMEOUT, settings_path=None):
        self.root, self.target, self.timeout = Path(root), target, timeout
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.items = {}
        self.rates = deque()
        self.closed = False
        self.started = time.monotonic()
        self.counts = {"completed": 0, "failed": 0, "cancelled": 0}
        self.total_seconds = 0
        self.completed_pages = 0
        self.settings_path = Path(settings_path) if settings_path else None
        self.settings = {"ownerHourly": 20, "globalHourly": 120, "ownerOverrides": {}}
        if self.settings_path and self.settings_path.exists():
            self.settings = validate_settings(json.loads(self.settings_path.read_text()))
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def prune(self):
        now = time.monotonic()
        self.items = {k: v for k, v in self.items.items()
                      if v["state"] not in TERMINAL or now - v["updated"] < TTL}
        while self.rates and now - self.rates[0][0] > 3600:
            self.rates.popleft()

    def put(self, owner, job_id, kind, pages, body, preview=False):
        if kind not in {"pdf", "image"} or not 0 < len(body) <= MAX_BYTES:
            raise Failure(400, "invalid_file")
        if kind == "pdf" and not body.startswith(b"%PDF-"):
            raise Failure(400, "invalid_file")
        if any(type(p) is not int or not 1 <= p <= 20 for p in pages) or len(pages) > 20:
            raise Failure(400, "invalid_pages")
        if type(preview) is not bool:
            raise Failure(400, "invalid_request")
        digest = hashlib.sha256(body + json.dumps([kind, pages, preview]).encode()).hexdigest()
        with self.lock:
            self.prune()
            old = self.items.get(job_id)
            if old:
                if old["owner"] != owner:
                    raise Failure(404, "not_found")
                if old.get("digest") == digest and old["state"] != "cancelled":
                    return self.view(old)
                raise Failure(409, "job_closed")
            if len(self.items) >= 64 or sum(j["state"] not in TERMINAL for j in self.items.values()) >= 4:
                raise Failure(429, "queue_full")
            if any(j["owner"] == owner and j["state"] not in TERMINAL for j in self.items.values()):
                raise Failure(429, "owner_busy")
            owner_limit = self.settings["ownerOverrides"].get(owner, self.settings["ownerHourly"])
            if len(self.rates) >= self.settings["globalHourly"] or sum(o == owner for _, o in self.rates) >= owner_limit:
                raise Failure(429, "rate_limit")
            path = self.root / job_id
            with path.open("xb") as file:
                file.write(body)
            os.chmod(path, 0o600)
            item = dict(id=job_id, owner=owner, kind=kind, selected=pages, path=path, preview=preview,
                        digest=digest, state="queued", completedPages=0, totalPages=0,
                        updated=time.monotonic())
            self.items[job_id] = item
            self.rates.append((time.monotonic(), owner))
            return self.view(item)

    @staticmethod
    def view(item):
        return {k: item[k] for k in ("id", "state", "completedPages", "totalPages", "result", "error") if k in item}

    def get(self, owner, job_id):
        with self.lock:
            self.prune()
            item = self.items.get(job_id)
            if not item or item["owner"] != owner:
                raise Failure(404, "not_found")
            return self.view(item)

    def cancel(self, owner, job_id):
        with self.lock:
            self.prune()
            item = self.items.get(job_id)
            if item and item["owner"] != owner:
                raise Failure(404, "not_found")
            if not item:
                if len(self.items) >= 64:
                    raise Failure(429, "queue_full")
                # 上传响应丢失/取消早于上传到达，也不能稍后开始一个孤儿任务。
                item = dict(id=job_id, owner=owner, completedPages=0, totalPages=0)
                self.items[job_id] = item
            if item.get("state") in TERMINAL:
                self.record(item)
            item.update(state="cancelled", updated=time.monotonic())
            item.pop("result", None)
            self.record(item)
            process = item.get("process")
            if process and process.is_alive():
                process.kill()
            if item.get("path"):
                item["path"].unlink(missing_ok=True)
            return self.view(item)

    def loop(self):
        while not self.closed:
            with self.lock:
                self.prune()
                item = next((j for j in self.items.values() if j["state"] == "queued"), None)
                if item:
                    item["state"] = "running"
            if item:
                self.execute(item)
            else:
                time.sleep(0.05)

    def execute(self, item):
        ctx = multiprocessing.get_context("spawn")
        receive, send = ctx.Pipe(duplex=False)
        arguments = (str(item["path"]), item["kind"], item["selected"], send)
        if item["preview"]:
            arguments += (True,)
        process = ctx.Process(target=self.target, args=arguments)
        start = time.monotonic()
        item["started"] = start
        try:
            with self.lock:
                if item["state"] == "cancelled":
                    return
                process.start()
                item["process"] = process
            send.close()
            while True:
                with self.lock:
                    if item["state"] == "cancelled":
                        break
                    if time.monotonic() - start > self.timeout:
                        item.update(state="failed", error="timeout")
                        break
                if receive.poll(0.1):
                    try:
                        message = receive.recv()
                    except EOFError:
                        break
                    with self.lock:
                        if item["state"] == "cancelled":
                            break
                        if "result" in message:
                            # 有界结果；禁止巨型坐标/文本拖垮网关。
                            if len(json.dumps(message).encode()) > 2 * 1024 * 1024:
                                item.update(state="failed", error="result_limit")
                            else:
                                item.update(state="completed", result=message["result"],
                                            totalPages=message["result"]["totalPages"],
                                            completedPages=len(message["result"]["pages"]))
                            break
                        if "error" in message:
                            item.update(state="failed", error=message["error"])
                            break
                        item.update(message)
                elif not process.is_alive():
                    break
        except Exception:
            pass
        finally:
            if process.pid:
                if process.is_alive():
                    process.kill()
                process.join(timeout=3)
            receive.close()
            send.close()
            with self.lock:
                item.pop("process", None)
                if process.pid:
                    process.close()
                if item["state"] not in TERMINAL:
                    item.update(state="failed", error="recognition_failed")
                item["updated"] = time.monotonic()
                item["path"].unlink(missing_ok=True)
                self.record(item)

    def record(self, item):
        # 只记录聚合数量和耗时，不存原文、文件名、令牌或任务标识。
        if item.get("recorded") or "digest" not in item:
            return
        state = item["state"]
        if state not in TERMINAL:
            return
        item["recorded"] = True
        self.counts[state] += 1
        self.total_seconds += max(0, time.monotonic() - item.get("started", time.monotonic()))
        if state == "completed":
            self.completed_pages += item.get("completedPages", 0)

    def overview(self):
        def rss(pid):
            try:
                for line in Path(f"/proc/{pid}/status").read_text().splitlines():
                    if line.startswith("VmRSS:"):
                        return int(line.split()[1]) * 1024
            except (OSError, ValueError):
                pass
            return None
        with self.lock:
            self.prune()
            active = [item for item in self.items.values() if item["state"] not in TERMINAL]
            pids = [item["process"].pid for item in active if "process" in item]
            count = sum(self.counts.values())
            return {"uptimeSeconds": round(time.monotonic() - self.started),
                    "counts": dict(self.counts), "completedPages": self.completed_pages,
                    "averageSeconds": round(self.total_seconds / count, 2) if count else 0,
                    "queueDepth": sum(item["state"] == "queued" for item in active),
                    "running": sum(item["state"] == "running" for item in active),
                    "workerRssBytes": rss(os.getpid()),
                    "childRssBytes": sum(rss(pid) or 0 for pid in pids),
                    "settings": {**self.settings, "ownerOverrides": dict(self.settings["ownerOverrides"])}}

    def configure(self, value):
        settings = validate_settings(value)
        with self.lock:
            if self.settings_path is None:
                raise Failure(503, "settings_unavailable")
            temporary = self.settings_path.with_suffix(".next")
            with temporary.open("w") as file:
                os.chmod(temporary, 0o600)
                json.dump(settings, file)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary, self.settings_path)
            self.settings = settings
            return settings

    def close(self):
        self.closed = True
        for item in list(self.items.values()):
            self.cancel(item["owner"], item["id"])
        self.thread.join(timeout=5)


def handler(jobs, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.handle_request()

        def do_PUT(self):
            self.handle_request()

        def do_DELETE(self):
            self.handle_request()

        def handle_request(self):
            self.connection.settimeout(15)
            try:
                if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + token):
                    raise Failure(401, "unauthorized")
                parts = urlsplit(self.path)
                if parts.path in {"/admin/overview", "/admin/settings"}:
                    if not re.fullmatch(r"admin:[1-9][0-9]{0,15}", self.headers.get("X-Ocr-Owner", "")):
                        raise Failure(403, "unauthorized")
                    if self.command == "GET" and parts.path == "/admin/overview":
                        return self.reply(200, jobs.overview())
                    if self.command == "PUT" and parts.path == "/admin/settings":
                        size = int(self.headers.get("Content-Length", "0"))
                        if not 0 < size <= 16 * 1024 or self.headers.get("Transfer-Encoding"):
                            raise Failure(400, "invalid_request")
                        return self.reply(200, jobs.configure(json.loads(self.rfile.read(size))))
                    raise Failure(400, "invalid_request")
                if self.command == "GET" and parts.path == "/health":
                    return self.reply(200, {"available": True, "maxBytes": MAX_BYTES, "maxPages": 20,
                                            "imageFormats": ["png", "jpg", "jpeg", "webp", "bmp"], "pagePreviews": True})
                match = re.fullmatch(r"/jobs/([a-f0-9]{32})", parts.path)
                owner = self.headers.get("X-Ocr-Owner", "")
                if not match or not re.fullmatch(r"(?:user|admin):[1-9][0-9]{0,15}", owner):
                    raise Failure(400, "invalid_request")
                job_id = match[1]
                if self.command == "PUT":
                    size = int(self.headers.get("Content-Length", "0"))
                    if not 0 < size <= MAX_BYTES or self.headers.get("Transfer-Encoding"):
                        raise Failure(413, "file_limit")
                    query = parse_qs(parts.query, keep_blank_values=True)
                    if "preview" in query and query["preview"] != ["true"]:
                        raise Failure(400, "invalid_request")
                    pages = [int(p) for p in query.get("pages", [""])[0].split(",") if p]
                    body = self.rfile.read(size)
                    if len(body) != size:
                        raise Failure(400, "invalid_file")
                    result = jobs.put(owner, job_id, query.get("kind", [""])[0], pages, body, "preview" in query)
                elif self.command == "DELETE":
                    result = jobs.cancel(owner, job_id)
                else:
                    result = jobs.get(owner, job_id)
                self.reply(200, result)
            except Failure as error:
                self.reply(error.status, {"error": error.code})
            except (ValueError, OSError):
                self.reply(400, {"error": "invalid_request"})

        def reply(self, status, data):
            raw = json.dumps(data, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(raw)
    return Handler


class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(6)
        super().__init__(*args, **kwargs)

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


if __name__ == "__main__":
    token = os.environ.get("OCR_WORKER_TOKEN", "")
    if len(token) < 32:
        raise SystemExit("OCR_WORKER_TOKEN must contain at least 32 characters")
    # 每次启动使用全新临时目录，退出清除；systemd RuntimeDirectory 也会清理崩溃残留。
    root = tempfile.mkdtemp(prefix="jobs-", dir=os.environ.get("OCR_SPOOL_ROOT"))
    state_root = Path(os.environ.get("OCR_STATE_ROOT", root))
    jobs = Jobs(root, settings_path=state_root / "settings.json")
    server = BoundedServer(("127.0.0.1", int(os.environ.get("OCR_WORKER_PORT", "3002"))), handler(jobs, token))
    try:
        server.serve_forever()
    finally:
        server.server_close()
        jobs.close()
        shutil.rmtree(root, ignore_errors=True)
