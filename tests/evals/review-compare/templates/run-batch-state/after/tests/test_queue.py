import unittest

from jobs.queue import Queue, RetryableError
from jobs.registry import Registry, UnknownJob


def flaky(times):
    calls = {"n": 0}

    def handler(options):
        calls["n"] += 1
        if calls["n"] <= times:
            raise RetryableError("busy")
        return "ok"

    return handler


class QueueTest(unittest.TestCase):
    def setUp(self):
        self.registry = Registry()
        self.registry.register("ok", lambda options: "ok")
        self.registry.register("resize", lambda options: options["limits"]["timeout"],
                               {"retries": 1, "limits": {"timeout": 30, "memory": 256}})
        self.queue = Queue(self.registry)

    def test_nested_override_merges(self):
        job = self.queue.add("a", "resize", limits={"timeout": 5})
        self.assertEqual(job["options"], {"retries": 1, "limits": {"timeout": 5, "memory": 256}})
        self.assertEqual(self.queue.run("a")["result"], 5)

    def test_unknown_and_duplicate(self):
        with self.assertRaises(UnknownJob):
            self.queue.add("a", "missing")
        self.queue.add("a", "ok")
        with self.assertRaises(ValueError):
            self.queue.add("a", "ok")

    def test_retry_then_done(self):
        self.registry.register("flaky", flaky(1), {"retries": 2})
        self.queue.add("a", "flaky")
        job = self.queue.run("a")
        self.assertEqual((job["state"], job["attempts"], job["errors"]), ("done", 2, ["busy"]))
        self.assertEqual(job["result"], "ok")

    def test_retries_run_out(self):
        self.registry.register("flaky", flaky(5), {"retries": 1})
        self.queue.add("a", "flaky")
        job = self.queue.run("a")
        self.assertEqual((job["state"], job["attempts"]), ("failed", 2))

    def test_batch_layout(self):
        for job_id in "abc":
            self.queue.add(job_id, "ok")
        jobs = lambda grid: [[slot and slot["job"] for slot in row] for row in grid]
        self.assertEqual(jobs(self.queue.batch(["a", "b", "c"], 3)), [["a", "b", "c"]])
        self.assertEqual(jobs(self.queue.batch(["a", "b", "c"], 4)), [["a", "b", "c", None]])
        with self.assertRaises(ValueError):
            self.queue.batch(["a"], 0)

    def test_slot_start_runs_job(self):
        self.queue.add("a", "ok")
        grid = self.queue.batch(["a"], 2)
        grid[0][0]["start"]()
        self.assertEqual(self.queue.jobs["a"]["state"], "done")

    def test_report_summary(self):
        self.registry.register("flaky", flaky(5))
        self.queue.add("a", "ok")
        self.queue.add("b", "flaky")
        self.queue.run("a")
        self.queue.run("b")
        self.assertEqual(self.queue.report(["a", "b"])["summary"], {"done": 1, "failed": 1})

    def test_remove_finished(self):
        self.queue.add("a", "ok")
        self.queue.add("b", "ok")
        self.queue.run("a")
        self.assertEqual(self.queue.remove_finished(), ["a"])
        self.assertEqual(self.queue.order, ["b"])
        self.assertNotIn("a", self.queue.jobs)

    def test_succeeded(self):
        self.queue.add("a", "ok")
        self.queue.add("b", "ok")
        self.queue.run("a")
        self.assertFalse(self.queue.succeeded(["a", "b"]))
        self.queue.run("b")
        self.assertTrue(self.queue.succeeded(["a", "b"]))


if __name__ == "__main__":
    unittest.main()
