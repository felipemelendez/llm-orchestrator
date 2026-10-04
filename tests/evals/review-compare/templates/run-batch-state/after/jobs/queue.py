"""Run registered jobs in batches, with retries and a report."""
import copy
import functools

from jobs.registry import Registry

FINISHED = ("done", "failed")


class RetryableError(Exception):
    """Raised by a handler when the job may succeed if run again."""


def merge_options(defaults, overrides):
    options = copy.deepcopy(defaults)
    for key, value in overrides.items():
        if isinstance(value, dict) and isinstance(options.get(key), dict):
            options[key].update(value)
        else:
            options[key] = value
    return options


def summary(records, counts=None):
    """Count records by state."""
    counts = {} if counts is None else counts
    for record in records:
        counts[record["state"]] = counts.get(record["state"], 0) + 1
    return counts


class Queue:
    def __init__(self, registry: Registry):
        self.registry = registry
        self.jobs = {}
        self.order = []

    def add(self, job_id, name, **overrides):
        handler, defaults = self.registry.get(name)
        if job_id in self.jobs:
            raise ValueError(f"duplicate job id {job_id!r}")
        self.jobs[job_id] = {
            "name": name,
            "handler": handler,
            "options": merge_options(defaults, overrides),
            "state": "pending",
            "attempts": 0,
            "errors": [],
            "result": None,
        }
        self.order.append(job_id)
        return self.jobs[job_id]

    def run(self, job_id):
        job = self.jobs[job_id]
        retries = job["options"].get("retries", 0)
        while job["attempts"] <= retries:
            job["attempts"] += 1
            try:
                job["result"] = job["handler"](job["options"])
            except RetryableError as exc:
                job["errors"].append(str(exc))
            except Exception as error:
                job["state"] = "failed"
                job["errors"].append(str(error))
                raise
            else:
                job["state"] = "done"
                return job
        job["state"] = "failed"
        return job

    def batch(self, job_ids, width):
        if width < 1:
            raise ValueError("width must be at least 1")
        rows = max(1, -(-len(job_ids) // width))
        grid = [[None] * width for _ in range(rows)]
        for index, job_id in enumerate(job_ids):
            start = functools.partial(self.run, job_id)
            grid[index // width][index % width] = {"job": job_id, "start": start}
        return grid

    def record(self, job_id):
        job = self.jobs[job_id]
        return {"job": job_id, "state": job["state"], "attempts": job["attempts"]}

    def report(self, job_ids):
        records = [self.record(job_id) for job_id in job_ids]
        return {
            "summary": summary(records),
            "details": [f"{record['job']}: {record['state']}" for record in records],
        }

    def remove_finished(self):
        removed = []
        for job_id in list(self.order):
            if self.jobs[job_id]["state"] in FINISHED:
                self.order.remove(job_id)
                del self.jobs[job_id]
                removed.append(job_id)
        return removed

    def succeeded(self, job_ids):
        states = [self.jobs[job_id]["state"] for job_id in job_ids]
        return bool(states) and all(state == "done" for state in states)
