import tempfile
import time
import unittest
from pathlib import Path
from server import Jobs, Failure, MAX_BYTES


def fake_engine(path, kind, pages, send):
    send.send({"totalPages": 3, "completedPages": 0})
    time.sleep(0.15)
    send.send({"result": {"totalPages": 3, "pages": [{"page": 2, "text": "scan"}]}})
    send.close()


def stalled_engine(path, kind, pages, send):
    time.sleep(30)


def preview_engine(path, kind, pages, send, include_preview=False):
    send.send({"result": {"totalPages": 1, "pages": [{"page": 1, "text": "preview",
        "previewRequested": include_preview}]}})
    send.close()


class WorkerTest(unittest.TestCase):
    def create(self, target=fake_engine, timeout=5):
        root = tempfile.TemporaryDirectory()
        jobs = Jobs(root.name, target, timeout)
        self.addCleanup(root.cleanup)
        self.addCleanup(jobs.close)
        return jobs

    def wait_terminal(self, jobs, job_id):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            job = jobs.get("user:1", job_id)
            if job["state"] in {"completed", "cancelled", "failed"}:
                return job
            time.sleep(0.03)
        self.fail("job did not settle")

    def test_result_page_positions_and_original_deleted(self):
        jobs = self.create()
        job_id = "a" * 32
        jobs.put("user:1", job_id, "pdf", [2], b"%PDF-fixture")
        result = self.wait_terminal(jobs, job_id)
        self.assertEqual(result["result"]["pages"][0]["page"], 2)
        # 等待 finally 完成原件清理。
        end = time.monotonic() + 2
        while (jobs.root / job_id).exists() and time.monotonic() < end:
            time.sleep(0.03)
        self.assertFalse((jobs.root / job_id).exists())
        jobs.cancel("user:1", job_id)
        self.assertNotIn("result", jobs.get("user:1", job_id))

    def test_idempotency_and_owner_isolation(self):
        jobs = self.create()
        job_id = "b" * 32
        jobs.put("user:1", job_id, "pdf", [], b"%PDF-fixture")
        jobs.put("user:1", job_id, "pdf", [], b"%PDF-fixture")
        for operation in (lambda: jobs.get("user:2", job_id),
                          lambda: jobs.cancel("user:2", job_id),
                          lambda: jobs.put("user:2", job_id, "pdf", [], b"%PDF-fixture")):
            with self.assertRaises(Failure) as caught:
                operation()
            self.assertEqual(caught.exception.status, 404)

    def test_preview_is_opt_in_and_part_of_idempotency(self):
        jobs = self.create(preview_engine)
        job_id = "9" * 32
        jobs.put("user:1", job_id, "pdf", [], b"%PDF-fixture", preview=True)
        result = self.wait_terminal(jobs, job_id)
        self.assertTrue(result["result"]["pages"][0]["previewRequested"])
        with self.assertRaises(Failure) as caught:
            jobs.put("user:1", job_id, "pdf", [], b"%PDF-fixture", preview=False)
        self.assertEqual(caught.exception.code, "job_closed")
        with self.assertRaises(Failure):
            jobs.put("user:1", "8" * 32, "pdf", [], b"%PDF-fixture", preview="true")

    def test_admin_settings_persist_and_limit_owners(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "settings.json"
            jobs = Jobs(Path(root) / "spool", fake_engine, 5, settings_path=path)
            try:
                settings = {"ownerHourly": 20, "globalHourly": 120, "ownerOverrides": {"user:1": 0}}
                jobs.configure(settings)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                with self.assertRaises(Failure) as caught:
                    jobs.put("user:1", "7" * 32, "pdf", [], b"%PDF-fixture")
                self.assertEqual(caught.exception.code, "rate_limit")
                with self.assertRaises(Failure):
                    jobs.configure({**settings, "ownerHourly": 201})
                with self.assertRaises(Failure):
                    jobs.configure({**settings, "ownerOverrides": {"../secret": 10}})
                self.assertEqual(jobs.settings, settings)
            finally:
                jobs.close()
            reopened = Jobs(Path(root) / "spool", fake_engine, 5, settings_path=path)
            try:
                self.assertEqual(reopened.settings, settings)
            finally:
                reopened.close()

    def test_admin_metrics_do_not_count_cleanup_as_cancel_or_expose_content(self):
        jobs = self.create()
        job_id = "6" * 32
        jobs.put("user:1", job_id, "pdf", [2], b"%PDF-secret-material")
        self.wait_terminal(jobs, job_id)
        jobs.cancel("user:1", job_id)
        snapshot = jobs.overview()
        self.assertEqual(snapshot["counts"], {"completed": 1, "failed": 0, "cancelled": 0})
        self.assertEqual(snapshot["completedPages"], 1)
        self.assertNotIn(job_id, str(snapshot))
        self.assertNotIn("secret-material", str(snapshot))

    def test_cancel_before_upload_prevents_late_job(self):
        jobs = self.create()
        jobs.cancel("user:1", "c" * 32)
        with self.assertRaises(Failure) as caught:
            jobs.put("user:1", "c" * 32, "pdf", [], b"%PDF-fixture")
        self.assertEqual(caught.exception.code, "job_closed")

    def test_cancel_kills_running_process_and_next_job_can_run(self):
        jobs = self.create(stalled_engine)
        job_id = "d" * 32
        jobs.put("user:1", job_id, "pdf", [], b"%PDF-fixture")
        end = time.monotonic() + 3
        while "process" not in jobs.items[job_id] and time.monotonic() < end:
            time.sleep(0.03)
        process = jobs.items[job_id]["process"]
        jobs.cancel("user:1", job_id)
        end = time.monotonic() + 3
        while "process" in jobs.items[job_id] and time.monotonic() < end:
            time.sleep(0.03)
        self.assertNotIn("process", jobs.items[job_id])
        self.assertFalse((jobs.root / job_id).exists())
        jobs.target = fake_engine
        jobs.put("user:1", "e" * 32, "pdf", [], b"%PDF-fixture")
        self.assertEqual(self.wait_terminal(jobs, "e" * 32)["state"], "completed")

    def test_timeout_and_limits(self):
        jobs = self.create(stalled_engine, timeout=0.2)
        jobs.put("user:1", "f" * 32, "pdf", [], b"%PDF-fixture")
        self.assertEqual(self.wait_terminal(jobs, "f" * 32)["error"], "timeout")
        for kind, pages, body in [("pdf", [], b"bad"), ("pdf", [21], b"%PDF-ok"),
                                  ("image", [], b"x" * (MAX_BYTES + 1))]:
            with self.assertRaises(Failure):
                jobs.put("user:1", "1" * 32, kind, pages, body)

    def test_per_owner_and_global_queue_limits(self):
        jobs = self.create(stalled_engine)
        jobs.put("user:1", "1" * 32, "pdf", [], b"%PDF-fixture")
        with self.assertRaises(Failure) as caught:
            jobs.put("user:1", "2" * 32, "pdf", [], b"%PDF-fixture")
        self.assertEqual(caught.exception.code, "owner_busy")
        for n in range(2, 5):
            jobs.put(f"user:{n}", str(n) * 32, "pdf", [], b"%PDF-fixture")
        with self.assertRaises(Failure) as caught:
            jobs.put("user:5", "5" * 32, "pdf", [], b"%PDF-fixture")
        self.assertEqual(caught.exception.code, "queue_full")


if __name__ == "__main__":
    unittest.main()
