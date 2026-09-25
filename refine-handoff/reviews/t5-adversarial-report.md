Found eight issues. No files edited or real models called. Filesystem probes were blocked: all 68 repository tests failed during temporary-directory setup. Executed findings below use in-memory fixtures or a small process probe.

1. **CATASTROPHIC — Claude runs unrestricted Bash → writes outside its copy and access to the person’s tools remain possible — REASONED ([orch-review.py:run_claude](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:691)).**  
   SCENE: given a reviewer influenced by repository content; when Bash overwrites an ignored project file or invokes an authenticated CLI; expect containment. There is no process sandbox or environment isolation. The final fingerprint misses ignored and external files. The spec acknowledges this limitation; it still violates your safety requirement.

2. **CATASTROPHIC — missing findings artifact → `READY` with zero findings — EXECUTED (`decide()` with otherwise complete records but no `findings.json`: `READY raw_findings=0 reasons=[]`).**  
   SCENE: given completed seats; when findings storage is deleted or becomes unreadable; expect `INCOMPLETE`. [decide](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:878) defaults it to empty findings. The recommended run directory is also in the temporary area writable by fix experiments.

3. **CATASTROPHIC — accurate but non-contradicting quotation → serious defect dropped and `READY` — EXECUTED (`check_refuter()` → `decide()`: `READY dropped invalid_drops=0`).**  
   SCENE: given subtraction instead of addition, a failing first receipt and an unapplied patch; when the refuter quotes the test expecting four and says “the check expects 4”; expect the defect to remain blocking. [check_refuter](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:532) accepts any nonempty explanation. This exact unsupported drop is also the expected success case in `tests/test-review.py:792`.

4. **CATASTROPHIC — locally cloned Git objects share hardlinks → modifying the copy can corrupt the real repository — REASONED ([orch-task-resources.py:Manager.clone](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-task-resources.py:337)).**  
   SCENE: given the ordinary same-filesystem clone; when unrestricted Claude changes permissions and truncates a copied object or pack; expect only disposable data to change. `git clone --local` uses hardlinks without `--no-hardlinks`; removing `origin` does not isolate those bytes.

5. **SERIOUS — experiment timeout → descendant process survives — EXECUTED (`receipt()` with a shortened timeout and a spawned sleeper: `timed_out=True child_still_alive=True`).**  
   SCENE: given a reproduction spawning subprocesses; when its timeout expires; expect every consumer stopped before cleanup. [receipt](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:639) kills only the immediate process through `subprocess.run`, despite creating a process group. I killed the probe group afterward.

6. **SERIOUS — clean submodules → review copies lack their contents — REASONED ([orch-task-resources.py:Manager.clone](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-task-resources.py:337)).**  
   SCENE: given an initialized, clean submodule; when the copy is created; expect its recorded commit checked out. There is no recursive clone or submodule initialization. Checking gitlinks does not establish that their files are present.

7. **SERIOUS — background-command acknowledgement → accepted as completed test evidence — EXECUTED (fake Claude stream, then `test_run_valid()`: `True`).**  
   SCENE: given `run_in_background=True`; when Bash returns “Command running in background with ID: bg”; expect R9 rejection until completion. [run_claude](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:714) records the acknowledgement as command output without checking completion.

8. **SERIOUS — missing refuter verdict plus rank reduction → `READY-WITH-FIXES` — EXECUTED (`decide()` with `verdict=None`, `rank=mild` and accepted evidence: `READY-WITH-FIXES incomplete_reasons=[]`).**  
   SCENE: given a serious finding without a valid refuter verdict; when its rank is lowered; expect `INCOMPLETE` under R14. [adjudicate](/Users/felipe/src/llm-orchestrator-wt/t5-review-build/scripts/lib/orch-review.py:966) applies the reduction before checking the verdict and bypasses `unjudged`.

What held up in executed controls: missing seats, explicit dropouts, changed checkout fingerprints and `not_checked` produced `INCOMPLETE`; reproduced and `not_runnable` findings resisted drops; invented command-output lines were rejected.

Verification: BLOCKED — end-to-end tests require writable temporary storage; the reported in-memory and process probes ran.