# Run jobs in batches

Add `jobs/queue.py` with a `Queue` built on a `Registry`, and a module-level
`summary(records, counts=None)`.

- `Queue.add(job_id, name, **overrides)` adds a pending job for the handler
  registered as `name`. Its options are the handler's defaults with the
  overrides applied; an override that is a dict updates the matching nested
  dict key by key instead of replacing it. Options set for one job never
  change the handler's registered defaults or any other job's options. A
  repeated `job_id` is a `ValueError`; an unknown name is `UnknownJob`.
- `Queue.run(job_id)` calls the handler with the job's options dict. A
  handler that raises `RetryableError` is called again, up to
  `options["retries"]` extra times (0 when absent); each such error message
  is kept in the job's `errors`. When the retries run out the job is
  `failed`. Any other exception from a handler is not retried: the job
  becomes `failed` and the exception reaches the caller. A handler that
  returns makes the job `done` with its return value in `result`.
  `attempts` counts the calls made.
- `Queue.batch(job_ids, width)` lays the jobs out row by row in a grid
  `width` slots wide, with as many rows as needed and `None` in unused
  slots. Each filled slot is `{"job": job_id, "start": callable}`; calling
  `start()` runs that slot's own job. Rows are independent lists. A width
  below 1 is a `ValueError`.
- `Queue.report(job_ids)` returns `{"summary": ..., "details": ...}`. The
  summary counts the jobs by state; the details list has one line
  `"<job_id>: <state>"` per job, in order.
- `summary(records, counts=None)` counts records by their `state`, adding to
  `counts` when given; each call without `counts` starts from an empty dict.
- `Queue.remove_finished()` drops every `done` or `failed` job from the
  queue, including several in a row, and returns their ids in queue order.
- `Queue.succeeded(job_ids)` is true when every listed job is `done`. An
  empty list has not succeeded.
