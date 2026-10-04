"""Held-out check for run-batch-state: exits 0 only when the change meets its spec.

Never copied into a case repository. Runs with the repository as the working directory.
"""
import sys

sys.path.insert(0, ".")
from jobs.queue import Queue, RetryableError, summary  # noqa: E402
from jobs.registry import Registry  # noqa: E402


def check():
    registry = Registry()
    registry.register("ok", lambda options: options.get("tag"))
    registry.register("resize", lambda options: dict(options["limits"]),
                      {"retries": 0, "limits": {"timeout": 30, "memory": 256}})
    calls = {"n": 0}

    def broken(options):
        calls["n"] += 1
        raise ValueError("bad input")

    registry.register("broken", broken, {"retries": 2})

    def busy(options):
        raise RetryableError("busy")

    registry.register("busy", busy, {"retries": 1})

    # Options for one job do not leak into the defaults or another job.
    queue = Queue(registry)
    queue.add("r1", "resize", limits={"timeout": 5})
    queue.add("r2", "resize")
    assert registry.defaults("resize")["limits"] == {"timeout": 30, "memory": 256}, "defaults changed"
    assert queue.jobs["r2"]["options"]["limits"] == {"timeout": 30, "memory": 256}, "other job changed"

    # A non-retryable error reaches the caller after one call.
    queue.add("x", "broken")
    try:
        queue.run("x")
    except ValueError:
        pass
    else:
        raise AssertionError("a non-retryable error was swallowed")
    assert calls["n"] == 1, "a non-retryable error was retried"
    assert queue.jobs["x"]["state"] == "failed"

    # Grid rows are independent and each slot starts its own job.
    queue = Queue(registry)
    ids = ["a", "b", "c", "d", "e"]
    for job_id in ids:
        registry.register("tag-" + job_id, lambda options: options["tag"], {"tag": job_id})
        queue.add(job_id, "tag-" + job_id)
    grid = queue.batch(ids, 2)
    layout = [[slot and slot["job"] for slot in row] for row in grid]
    assert layout == [["a", "b"], ["c", "d"], ["e", None]], f"grid is {layout}"
    for row in grid:
        for slot in row:
            if slot:
                slot["start"]()
    for job_id in ids:
        job = queue.jobs[job_id]
        assert job["state"] == "done" and job["result"] == job_id, f"slot {job_id} ran another job"
        assert job["attempts"] == 1, f"{job_id} ran {job['attempts']} times"

    # The report has both a summary and the details.
    queue.add("f", "busy")
    queue.run("f")
    report = queue.report(ids + ["f"])
    assert report["summary"] == {"done": 5, "failed": 1}, f"summary is {report['summary']}"
    assert report["details"] == [f"{j}: done" for j in ids] + ["f: failed"], f"details are {report['details']}"
    again = queue.report(["a"])
    assert again["summary"] == {"done": 1}, f"second summary is {again['summary']}"
    assert summary([{"state": "done"}]) == {"done": 1}, "summary kept counts from an earlier call"
    assert summary([{"state": "done"}], {"done": 2}) == {"done": 3}

    # Empty input has not succeeded.
    assert queue.succeeded(["a", "b"]) is True
    assert not queue.succeeded([]), "an empty batch counted as succeeded"

    # Several finished jobs in a row are all removed.
    queue.add("p", "ok")
    removed = queue.remove_finished()
    assert removed == ids + ["f"], f"removed {removed}"
    assert queue.order == ["p"] and list(queue.jobs) == ["p"], f"left {queue.order}"


if __name__ == "__main__":
    try:
        check()
    except AssertionError as e:
        print(f"held-out check failed: {e}")
        sys.exit(1)
    print("held-out check passed")
