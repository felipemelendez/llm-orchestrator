---
description: Review the current change with orch-review.py — Standard by default, Full with --full. Saves no file in the repository.
---

You are running `/llm-orchestrator:review`.

User input: $ARGUMENTS (optional: a base ref, and `--full`)

Steps:

1. Invoke `requesting-code-review` and follow it.

2. Read the arguments:
   - `--full` selects the Full review; otherwise run Standard.
   - Any other argument is the base ref. Without one, use
     `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@'`,
     and `origin/main` if that fails.

3. Find the spec the change must implement: the plan or spec named in this
   conversation, else the newest file in `docs/llm-orchestrator/specs/`. If
   there is none, ask the person which file states what the change must do.

4. Start the run in a new directory outside the repository, then wait:

   ```bash
   RUN_DIR="$(mktemp -d)/review"
   python3 "$REVIEW" run --detach --path <standard|full> --writer claude --base "$BASE" --spec "$SPEC" --run-dir "$RUN_DIR"
   python3 "$REVIEW" wait "$RUN_DIR" --seconds 540
   ```

   `$REVIEW` is found as `requesting-code-review` shows. Repeat `wait` until it
   reports `finished` or `crashed`.

5. Report:

```
Verdict:
- READY | READY-WITH-FIXES | NOT-READY | INCOMPLETE — <one line>
Findings:
- <id> <rank> <status> — <file:line> — <claim>
Incomplete because:
- <each reason, when INCOMPLETE>
Review:
- <run dir>/review.json
Next:
- Handle the findings with receiving-code-review, then run orch-review.py record.
```

Constraints:
- Never report `INCOMPLETE` or a crashed run as a pass.
- Never replace a reviewer that dropped out; report it.
- Save nothing in the repository; the review lives in the run directory.
