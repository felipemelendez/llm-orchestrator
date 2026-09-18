#!/usr/bin/env python3
"""Filesystem, Git preservation and deterministic lifecycle concurrency checks."""

import importlib.util
import fcntl
import json
import multiprocessing
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[1] / "scripts/lib/orch-task-resources.py"
SPEC = importlib.util.spec_from_file_location("task_resources", SOURCE)
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)
CTX = multiprocessing.get_context("fork")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="orch-resources-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.project / "source.py").write_text("original\n")
        (self.project / ".gitignore").write_text("*.ignored\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.manager = MOD.Manager(self.root / "state")
        self.task = self.manager.start(self.project, "test")
        self.task_id = self.task["id"]
        self.scratch = Path(self.task["scratch"])

    def git(self, *args, cwd=None):
        return MOD.git(cwd or self.project, *args)

    def acquire(self, name="writer"):
        return self.manager.acquire(self.task_id, name)["token"]

    def release(self, token):
        return self.manager.release(self.task_id, token, stopped=True)

    def resource(self, kind="worktree", ref="HEAD", branch=None):
        token = self.acquire()
        result = self.manager.create(self.task_id, token, kind, ref, branch)
        self.release(token)
        return Path(result["path"])

    def assert_retained(self, path=None):
        result = self.manager.finish(self.task_id)
        self.assertEqual(result["status"], "closed", result)
        self.assertTrue(result["reasons"], result)
        self.assertTrue((path or self.scratch).exists())
        return result

    def spawn(self, target):
        process = CTX.Process(target=target)
        process.start()
        def stop():
            if process.is_alive():
                process.terminate()
            process.join(5)
        self.addCleanup(stop)
        return process

    def joined(self, process):
        process.join(8)
        self.assertFalse(process.is_alive(), "child did not finish")
        self.assertEqual(process.exitcode, 0)

    def hold_lock(self, path, mode=fcntl.LOCK_EX):
        entered, release = CTX.Event(), CTX.Event()
        def hold():
            with self.manager.file_lock(path, mode):
                entered.set()
                if not release.wait(8):
                    raise RuntimeError("test synchronization timeout")
        process = self.spawn(hold)
        self.assertTrue(entered.wait(5))
        return process, release

    def hook_fixture(self):
        """Exercise a copied shell entrypoint with only fixture-owned state."""
        fixture_home = self.root / "hook-home"
        fixture_home.mkdir()
        manager = MOD.Manager(fixture_home / ".cache/llm-orchestrator/task-resources")
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
        installed = self.root / "installed/scripts"
        (installed / "hooks").mkdir(parents=True)
        (installed / "lib").mkdir()
        shutil.copy2(SOURCE, installed / "lib/orch-task-resources.py")
        hook = installed / "hooks/orch-task-cleanup.sh"
        shutil.copy2(SOURCE.parents[1] / "hooks/orch-task-cleanup.sh", hook)
        env = {**os.environ, "HOME": str(fixture_home), "ORCH_HOOK_PROFILE": "standard",
               "ORCH_DISABLED_HOOKS": "", "ORCH_HOOK_DRY_RUN": "0"}
        def run(extra_env=None):
            started = time.monotonic()
            result = subprocess.run(["bash", str(hook)],
                                    input=json.dumps({"cwd": str(self.project)}),
                                    capture_output=True, text=True,
                                    env={**env, **(extra_env or {})}, timeout=2)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertLess(time.monotonic() - started, 2)
            return result
        return manager, run

    def test_finish_removes_owned_reports_and_copy_only(self):
        other = self.manager.start(self.project, "other task")
        copy = self.resource("copy")
        self.assertEqual((copy / "source.py").read_text(), "original\n")
        self.assertFalse((copy / ".git").exists())
        (self.scratch / "review.md").write_text("temporary")
        result = self.manager.finish(self.task_id)
        self.assertEqual(result["status"], "done", result)
        self.assertFalse(self.scratch.exists())
        self.assertTrue(Path(other["scratch"]).exists())
        self.assertTrue(self.project.exists())
        self.assertTrue(Path(result["state"]).exists())
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")

    def test_copy_includes_dirty_and_untracked_source_but_not_ignored(self):
        (self.project / "source.py").write_text("edited\n")
        (self.project / "new.py").write_text("new\n")
        (self.project / "private.ignored").write_text("not copied")
        copy = self.resource("copy")
        self.assertEqual((copy / "source.py").read_text(), "edited\n")
        self.assertTrue((copy / "new.py").exists())
        self.assertFalse((copy / "private.ignored").exists())

    def test_consumer_closes_admission_and_release_never_finishes(self):
        token = self.acquire("reviewer")
        self.assert_retained()
        with self.assertRaises(MOD.Unsafe):
            self.acquire("late verifier")
        with self.assertRaises(MOD.Unsafe):
            self.manager.create(self.task_id, token, "copy")
        self.release(token)
        self.assertTrue(self.scratch.exists())
        self.assertEqual(self.manager.read(self.task_id)["status"], "closed")
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_lease_generation_and_stopped_attestation(self):
        first = self.acquire()
        with self.assertRaises(MOD.Unsafe):
            self.manager.release(self.task_id, first)
        self.release(first)
        second = self.acquire()
        self.release(first)  # repeated old stop cannot release new generation
        self.assertIn(second, self.manager.read(self.task_id)["leases"])
        with self.assertRaises(MOD.Unsafe):
            self.release("0" * 32)
        self.assert_retained()

    def test_stop_retry_does_not_complete_open_or_old_tasks(self):
        os.utime(self.scratch, (1, 1))
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "open")
        self.assertEqual(self.manager.retry_project(self.project), {"tasks": []})
        self.assertTrue(self.scratch.exists())

    def test_mutex_is_separate_from_consumer_lease(self):
        token = self.acquire("reviewer")
        mutex = self.scratch / ".orch-active"
        mutex.mkdir()
        mutex.rmdir()  # worktree reaper is not a consumer release
        self.assert_retained()
        self.release(token)
        mutex.mkdir()
        result = self.assert_retained()
        self.assertIn("mutex", str(result["reasons"]))
        mutex.rmdir()
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_clean_detached_worktree_retained_commit_is_removed(self):
        worktree = self.resource()
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")
        self.assertFalse(worktree.exists())
        self.assertNotIn(str(worktree), self.git("worktree", "list", "--porcelain"))

    def test_unique_detached_commit_is_preserved(self):
        worktree = self.resource()
        (worktree / "source.py").write_text("unique\n")
        self.git("add", ".", cwd=worktree)
        self.git("commit", "-qm", "unique", cwd=worktree)
        self.assert_retained(worktree)

    def test_unmerged_branch_is_retained_when_worktree_removed(self):
        worktree = self.resource(branch="owned-unmerged")
        (worktree / "source.py").write_text("unique\n")
        self.git("add", ".", cwd=worktree)
        self.git("commit", "-qm", "unique", cwd=worktree)
        head = self.git("rev-parse", "HEAD", cwd=worktree).strip()
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")
        self.assertFalse(worktree.exists())
        self.assertEqual(self.git("rev-parse", "refs/heads/owned-unmerged").strip(), head)
        self.assertNotEqual(self.git("rev-parse", "main").strip(), head)

    def test_refs_preserved_across_entire_cleanup_set(self):
        first = self.resource(branch="retained")
        (first / "source.py").write_text("unique\n")
        self.git("add", ".", cwd=first)
        self.git("commit", "-qm", "unique", cwd=first)
        second = self.resource(ref="retained")
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        self.git("show-ref", "--verify", "refs/heads/retained")

    def test_dirty_staged_untracked_and_ignored_each_preserve(self):
        for change in ("tracked", "staged", "untracked", "ignored"):
            with self.subTest(change=change):
                task = self.manager.start(self.project, change)
                token = self.manager.acquire(task["id"], "writer")["token"]
                tree = Path(self.manager.create(task["id"], token, "worktree")["path"])
                name = {"tracked": "source.py", "staged": "source.py",
                        "untracked": "new", "ignored": "new.ignored"}[change]
                (tree / name).write_text("unique work")
                if change == "staged":
                    self.git("add", ".", cwd=tree)
                self.manager.release(task["id"], token, True)
                result = self.manager.finish(task["id"])
                self.assertEqual(result["status"], "closed", result)
                self.assertTrue((tree / name).exists())

    def test_git_locked_worktree_is_preserved(self):
        worktree = self.resource()
        self.git("worktree", "lock", str(worktree))
        self.assert_retained(worktree)

    def test_symlink_root_and_replaced_resource_are_preserved(self):
        copy = self.resource("copy")
        relocated = self.root / "relocated"
        copy.rename(relocated)
        copy.symlink_to(relocated, target_is_directory=True)
        self.assert_retained(copy)
        self.assertTrue((relocated / "source.py").exists())
        copy.unlink()
        copy.mkdir()
        (copy / "valuable").write_text("replacement")
        self.assert_retained(copy)
        self.assertTrue((copy / "valuable").exists())

    def test_replaced_scratch_does_not_delete_replacement(self):
        self.scratch.rename(self.root / "original-scratch")
        self.scratch.mkdir()
        (self.scratch / "valuable").write_text("replacement")
        self.assert_retained()
        self.assertTrue((self.scratch / "valuable").exists())

    def test_symlink_scratch_preserves_destination(self):
        self.scratch.rmdir()
        self.scratch.symlink_to(self.project, target_is_directory=True)
        self.assert_retained()
        self.assertTrue((self.project / "source.py").exists())

    def test_symlink_within_disposable_copy_never_follows_target(self):
        outside = self.root / "valuable"
        outside.mkdir()
        (outside / "keep").write_text("keep")
        (self.project / "link").symlink_to(outside, target_is_directory=True)
        copy = self.resource("copy")
        self.assertTrue((copy / "link").is_symlink())
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")
        self.assertTrue((outside / "keep").exists())

    def test_primary_or_unregistered_repository_is_never_removed(self):
        copy = self.resource("copy")
        self.git("init", "-q", cwd=copy)
        self.assert_retained(copy)
        other = self.manager.start(self.project, "unregistered")
        root = Path(other["scratch"])
        self.git("init", "--bare", "-q", str(root / "bare"))
        self.assertEqual(self.manager.finish(other["id"])["status"], "closed")
        self.assertTrue((root / "bare" / "HEAD").exists())

    def test_submodule_snapshot_is_rejected_and_source_preserved(self):
        external = self.root / "external"
        self.git("clone", "-q", str(self.project), str(external))
        self.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", str(external), "submodule")
        token = self.acquire()
        with self.assertRaises(MOD.Unsafe):
            self.manager.create(self.task_id, token, "copy")
        with self.assertRaises(MOD.Unsafe):
            self.manager.start(self.project / "submodule", "not a primary project")
        self.assertTrue((self.project / "submodule" / "source.py").exists())

    def test_unsupported_recursive_delete_preserves_resources(self):
        with mock.patch.object(MOD.shutil.rmtree, "avoids_symlink_attacks", False):
            self.assert_retained()

    def test_malformed_manifest_traversal_or_foreign_scratch_is_rejected(self):
        path = self.manager.paths(self.task_id)[0]
        original = path.read_text()
        state = json.loads(original)
        state["scratch"] = str(self.project)
        path.write_text(json.dumps(state))
        with self.assertRaises(MOD.Unsafe):
            self.manager.finish(self.task_id)
        state = json.loads(original)
        state["resources"] = [{"name": "../project", "kind": "copy", "identity": None, "removed": False}]
        path.write_text(json.dumps(state))
        with self.assertRaises(MOD.Unsafe):
            self.manager.finish(self.task_id)
        self.assertTrue(self.scratch.exists())
        self.assertTrue(self.project.exists())

    def test_state_storage_cannot_live_in_project_or_use_symlink(self):
        manager = MOD.Manager(self.project / "state")
        with self.assertRaises(MOD.Unsafe):
            manager.start(self.project, "invalid")
        link = self.root / "linked-state"
        link.symlink_to(self.manager.base, target_is_directory=True)
        with self.assertRaises(MOD.Unsafe):
            MOD.Manager(link)
        with self.assertRaises(MOD.Unsafe):
            self.manager.finish("../project")

    def test_partial_cleanup_preserves_recovery_and_retries(self):
        first, second = self.resource("copy"), self.resource("copy")
        real_remove = shutil.rmtree
        def fail_second(path, *args, **kwargs):
            if path == second:
                raise OSError("fixture refusal")
            return real_remove(path, *args, **kwargs)
        with mock.patch.object(MOD.shutil, "rmtree", side_effect=fail_second):
            result = self.manager.finish(self.task_id)
        self.assertEqual(result["status"], "closed")
        self.assertIn("fixture refusal", str(result["reasons"]))
        self.assertFalse(first.exists())
        self.assertTrue(second.exists())
        self.assertTrue(Path(result["state"]).exists())
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_interrupted_delete_is_closed_and_retry_is_idempotent(self):
        copy = self.resource("copy")
        real_remove = shutil.rmtree
        def interrupt(path, *args, **kwargs):
            real_remove(path, *args, **kwargs)
            raise KeyboardInterrupt()
        with mock.patch.object(MOD.shutil, "rmtree", side_effect=interrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.manager.finish(self.task_id)
        self.assertFalse(copy.exists())
        self.assertEqual(self.manager.read(self.task_id)["status"], "closed")
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_finish_wins_against_new_consumer(self):
        entered, proceed, attempt = CTX.Event(), CTX.Event(), CTX.Event()
        outcomes = CTX.Queue()
        def finish():
            original = self.manager.cleanup
            def pause(state):
                entered.set()
                if not proceed.wait(5):
                    raise RuntimeError("test synchronization timeout")
                return original(state)
            self.manager.cleanup = pause
            outcomes.put(("finish", self.manager.finish(self.task_id)["status"]))
        def acquire():
            attempt.set()
            try:
                self.acquire("late")
                outcomes.put(("acquire", "unexpected admission"))
            except MOD.Unsafe:
                outcomes.put(("acquire", "closed"))
        first = self.spawn(finish)
        self.assertTrue(entered.wait(5))
        second = self.spawn(acquire)
        self.assertTrue(attempt.wait(5))
        with self.assertRaises(queue.Empty):
            outcomes.get(timeout=0.1)
        proceed.set()
        self.joined(first)
        self.joined(second)
        self.assertEqual({outcomes.get(timeout=1), outcomes.get(timeout=1)},
                         {("finish", "done"), ("acquire", "closed")})

    def test_acquire_wins_and_finish_preserves_resource(self):
        entered, proceed, attempt = CTX.Event(), CTX.Event(), CTX.Event()
        outcomes = CTX.Queue()
        def acquire():
            original = self.manager.save
            def pause(state):
                original(state)
                if state["leases"]:
                    entered.set()
                    if not proceed.wait(5):
                        raise RuntimeError("test synchronization timeout")
            self.manager.save = pause
            outcomes.put(("token", self.acquire("reviewer")))
        def finish():
            attempt.set()
            outcomes.put(("finish", self.manager.finish(self.task_id)["status"]))
        first = self.spawn(acquire)
        self.assertTrue(entered.wait(5))
        second = self.spawn(finish)
        self.assertTrue(attempt.wait(5))
        with self.assertRaises(queue.Empty):
            outcomes.get(timeout=0.1)
        proceed.set()
        self.joined(first)
        self.joined(second)
        values = dict([outcomes.get(timeout=1), outcomes.get(timeout=1)])
        self.assertEqual(values["finish"], "closed")
        self.assertTrue(self.scratch.exists())
        self.release(values["token"])
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_registration_and_finish_share_lock(self):
        token = self.acquire("copy maker")
        entered, proceed, attempt = CTX.Event(), CTX.Event(), CTX.Event()
        outcomes = CTX.Queue()
        def create():
            original = self.manager.snapshot
            def pause(project, destination):
                entered.set()
                if not proceed.wait(5):
                    raise RuntimeError("test synchronization timeout")
                original(project, destination)
            self.manager.snapshot = pause
            outcomes.put(("copy", self.manager.create(self.task_id, token, "copy")["path"]))
        def finish():
            attempt.set()
            outcomes.put(("finish", self.manager.finish(self.task_id)["status"]))
        first = self.spawn(create)
        self.assertTrue(entered.wait(5))
        second = self.spawn(finish)
        self.assertTrue(attempt.wait(5))
        with self.assertRaises(queue.Empty):
            outcomes.get(timeout=0.1)
        proceed.set()
        self.joined(first)
        self.joined(second)
        values = dict([outcomes.get(timeout=1), outcomes.get(timeout=1)])
        self.assertEqual(values["finish"], "closed")
        self.assertTrue(Path(values["copy"]).exists())
        with self.assertRaises(MOD.Unsafe):
            self.manager.create(self.task_id, token, "copy")
        self.release(token)
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_concurrent_finish_deletes_once(self):
        entered, proceed, attempt = CTX.Event(), CTX.Event(), CTX.Event()
        outcomes = CTX.Queue()
        def first_finish():
            original = self.manager.cleanup
            def pause(state):
                entered.set()
                if not proceed.wait(5):
                    raise RuntimeError("test synchronization timeout")
                result = original(state)
                outcomes.put("deleted")
                return result
            self.manager.cleanup = pause
            outcomes.put(self.manager.finish(self.task_id)["status"])
        def second_finish():
            attempt.set()
            outcomes.put(self.manager.finish(self.task_id)["status"])
        first = self.spawn(first_finish)
        self.assertTrue(entered.wait(5))
        second = self.spawn(second_finish)
        self.assertTrue(attempt.wait(5))
        with self.assertRaises(queue.Empty):
            outcomes.get(timeout=0.1)
        proceed.set()
        self.joined(first)
        self.joined(second)
        self.assertCountEqual([outcomes.get(timeout=1) for _ in range(3)], ["deleted", "done", "done"])

    def test_cli_contract_and_project_retry(self):
        command = [sys.executable, str(SOURCE), "--state-dir", str(self.manager.base)]
        result = subprocess.run(command + ["status", "--id", self.task_id], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["status"], "open")
        token = self.acquire("reader")
        result = subprocess.run(command + ["finish", "--id", self.task_id], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.release(token)
        result = subprocess.run(command + ["retry", "--project", str(self.project)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["tasks"][0]["status"], "done")

    def test_hook_requires_exact_proportional_opt_in(self):
        token = self.acquire()
        self.manager.finish(self.task_id)
        self.release(token)
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        for value in ({"enabled": False, "workflow": "proportional"},
                      {"enabled": True}, {"enabled": True, "workflow": "legacy"},
                      {"enabled": True, "workflow": "typo"}, [], {"enabled": "true"}):
            with self.subTest(value=value):
                config.write_text(json.dumps(value))
                with mock.patch("sys.stderr"):
                    MOD.hook_retry(self.manager.base, {"cwd": str(self.project)})
                self.assertTrue(self.scratch.exists())
        config.write_text("{invalid")
        with mock.patch("sys.stderr"):
            MOD.hook_retry(self.manager.base, {"cwd": str(self.project)})
        self.assertTrue(self.scratch.exists())
        config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
        MOD.hook_retry(self.manager.base, {"cwd": str(config.parent)})
        self.assertFalse(self.scratch.exists())

    def test_hook_ignores_open_task_and_other_project(self):
        second = self.root / "second-project"
        self.git("clone", "-q", str(self.project), str(second))
        foreign = self.manager.start(second, "foreign")
        token = self.manager.acquire(foreign["id"], "writer")["token"]
        self.manager.finish(foreign["id"])
        self.manager.release(foreign["id"], token, True)
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
        MOD.hook_retry(self.manager.base, {"cwd": str(self.project)})
        self.assertTrue(self.scratch.exists())
        self.assertTrue(Path(foreign["scratch"]).exists())

    def test_shell_stop_skips_held_unrelated_project_lock(self):
        manager, run_hook = self.hook_fixture()
        second = self.root / "second-project"
        self.git("clone", "-q", str(self.project), str(second))
        foreign = manager.start(second, "busy other project")
        before = manager.paths(foreign["id"])[0].read_bytes()
        local = manager.start(self.project, "finished local task")
        token = manager.acquire(local["id"], "reader")["token"]
        manager.finish(local["id"])
        manager.release(local["id"], token, True)
        child, release = self.hold_lock(manager.paths(foreign["id"])[1])
        result = run_hook()
        self.assertEqual(result.stderr, "")
        self.assertEqual(manager.read(local["id"])["status"], "done")
        self.assertEqual(manager.paths(foreign["id"])[0].read_bytes(), before)
        self.assertTrue(child.is_alive())
        release.set()
        self.joined(child)

    def test_shell_stop_skips_busy_matching_task_then_explicit_retry_completes(self):
        manager, run_hook = self.hook_fixture()
        task = manager.start(self.project, "busy matching task")
        token = manager.acquire(task["id"], "reader")["token"]
        manager.finish(task["id"])
        manager.release(task["id"], token, True)
        before = manager.paths(task["id"])[0].read_bytes()
        child, release = self.hold_lock(manager.paths(task["id"])[1])
        result = run_hook()
        self.assertIn("busy", result.stderr)
        self.assertIn(f"retry --id {task['id']}", result.stderr)
        self.assertEqual(manager.paths(task["id"])[0].read_bytes(), before)
        release.set()
        self.joined(child)
        self.assertEqual(manager.finish(task["id"], retry=True)["status"], "done")

    def test_shell_stop_never_waits_for_registry_admission_or_pruning(self):
        manager, run_hook = self.hook_fixture()
        task = manager.start(self.project, "old completed task")
        manager.finish(task["id"])
        state = manager.read(task["id"])
        state["finished_at"] = 1
        manager.save(state)
        manifest, lock, _ = manager.paths(task["id"])
        for mode in (fcntl.LOCK_SH, fcntl.LOCK_EX):
            with self.subTest(mode=mode):
                child, release = self.hold_lock(manager.base / ".registry.lock", mode)
                result = run_hook()
                self.assertIn("registry is busy", result.stderr)
                self.assertTrue(manifest.exists())
                self.assertTrue(lock.exists())
                release.set()
                self.joined(child)
        run_hook()
        self.assertFalse(manifest.exists())
        self.assertFalse(lock.exists())

    def test_routine_cleanup_defers_large_trees_without_traversing_or_deleting(self):
        token = self.acquire("reader")
        for index in range(2000):
            (self.scratch / f"report-{index}.md").write_text("temporary report")
        self.manager.finish(self.task_id)
        self.release(token)
        with mock.patch.object(self.manager, "repository_inside", side_effect=AssertionError("tree scan")), \
                mock.patch.object(MOD.shutil, "rmtree", side_effect=AssertionError("recursive delete")):
            MOD.shutil.rmtree.avoids_symlink_attacks = True
            result = self.manager.retry_project(self.project, routine=True)
        self.assertEqual(result["tasks"][0]["status"], "closed")
        self.assertIn(f"retry --id {self.task_id}", str(result["tasks"][0]["reasons"]))
        self.assertEqual(len(list(self.scratch.iterdir())), 2000)
        self.assertEqual(self.manager.read(self.task_id)["reasons"], result["tasks"][0]["reasons"])
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")
        self.assertFalse(self.scratch.exists())

    def test_routine_cleanup_defers_resources_and_preserves_unique_git_work(self):
        copy = self.resource("copy")
        worktree = self.resource()
        (worktree / "source.py").write_text("unique work\n")
        self.git("add", ".", cwd=worktree)
        self.git("commit", "-qm", "unique", cwd=worktree)
        token = self.acquire("reader")
        self.manager.finish(self.task_id)
        self.release(token)
        with mock.patch.object(self.manager, "worktree_safe", side_effect=AssertionError("Git cleanup")):
            result = self.manager.retry_project(self.project, routine=True)
        self.assertEqual(result["tasks"][0]["status"], "closed")
        self.assertTrue(copy.exists())
        self.assertTrue(worktree.exists())
        result = self.manager.finish(self.task_id, retry=True)
        self.assertEqual(result["status"], "closed")
        self.assertIn("no retained named ref", str(result["reasons"]))
        self.assertFalse(copy.exists())
        self.assertTrue(worktree.exists())
        self.git("branch", "retained-unique", cwd=worktree)
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "done")

    def test_routine_manifest_work_is_bounded_and_warns_without_losing_recovery(self):
        task_dir = self.manager.base / "tasks"
        for index in range(30):
            (task_dir / f"irrelevant-{index}").write_text("not a manifest")
        budget = MOD.RoutineBudget(entries=5, seconds=60)
        with mock.patch.object(self.manager, "read", wraps=self.manager.read) as reads:
            self.manager.retry_project(self.project, routine=True, budget=budget)
            self.manager.prune_completed(self.project, budget=budget)
        self.assertTrue(budget.exhausted)
        self.assertEqual(budget.remaining, 0)
        self.assertLessEqual(reads.call_count, 5)
        self.assertTrue(self.scratch.exists())
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
        budget = MOD.RoutineBudget(entries=0)
        with mock.patch.object(MOD, "RoutineBudget", return_value=budget), mock.patch("sys.stderr") as warning:
            MOD.hook_retry(self.manager.base, {"cwd": str(self.project)})
        self.assertIn("metadata budget exhausted", str(warning.write.call_args_list))
        self.assertIn("retry --project", str(warning.write.call_args_list))

    def test_routine_large_manifest_is_deferred_and_explicit_retry_recovers(self):
        state = self.manager.read(self.task_id)
        state["status"] = "closed"
        state["reasons"] = ["x" * (MOD.RoutineBudget.STATE_BYTES + 1)]
        self.manager.save(state)
        before = self.manager.paths(self.task_id)[0].read_bytes()
        result = self.manager.retry_project(self.project, routine=True)
        self.assertEqual(result["tasks"][0]["status"], "blocked")
        self.assertIn("record exceeds routine limit", str(result["tasks"][0]["reasons"]))
        self.assertIn(f"retry --id {self.task_id}", str(result["tasks"][0]["reasons"]))
        self.assertEqual(self.manager.paths(self.task_id)[0].read_bytes(), before)
        self.assertEqual(self.manager.retry_project(self.project)["tasks"][0]["status"], "done")

    def test_disposable_attribution_returns_unknown_on_busy_task_or_registry(self):
        self.acquire("writer")
        target = self.scratch / "probe.py"
        for lock in (self.manager.paths(self.task_id)[1], self.manager.base / ".registry.lock"):
            with self.subTest(lock=lock.name):
                child, release = self.hold_lock(lock)
                results = CTX.Queue()
                attribution = self.spawn(lambda: results.put(MOD.owned_disposable_target(target, self.project)))
                self.assertFalse(results.get(timeout=2))
                self.joined(attribution)
                release.set()
                self.joined(child)
        self.assertTrue(MOD.owned_disposable_target(target, self.project))

    def test_routine_git_discovery_and_disposable_attribution_are_time_bounded(self):
        _, run_hook = self.hook_fixture()
        self.acquire("writer")
        binaries = self.root / "slow-git-bin"
        binaries.mkdir()
        fake_git = binaries / "git"
        fake_git.write_text(f"#!{sys.executable}\nimport time\ntime.sleep(20)\n")
        fake_git.chmod(0o700)
        env = {"PATH": str(binaries) + os.pathsep + os.environ.get("PATH", "")}
        result = run_hook(env)
        self.assertIn("timed out", result.stderr)
        started = time.monotonic()
        with mock.patch.dict(os.environ, env):
            self.assertFalse(MOD.owned_disposable_target(self.scratch / "probe.py", self.project))
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(self.scratch.exists())

    def test_hook_malformed_payload_is_inert_and_warns(self):
        with mock.patch("sys.stderr") as warning:
            MOD.hook_retry(self.manager.base, ["bad payload"])
            self.assertTrue(warning.write.called)
        self.assertTrue(self.scratch.exists())
        command = [sys.executable, str(SOURCE), "--state-dir", str(self.manager.base), "hook-retry"]
        result = subprocess.run(command, input="{bad", capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("skipped", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_hook_non_git_directory_is_silent(self):
        with mock.patch("sys.stderr") as warning:
            MOD.hook_retry(self.manager.base, {"cwd": str(self.root)})
            self.assertFalse(warning.write.called)
        self.assertTrue(self.scratch.exists())

    def test_cleanup_hook_honors_disable_minimal_and_dry_run(self):
        fixture_home = self.root / "hook-home"
        fixture_home.mkdir()
        manager = MOD.Manager(fixture_home / ".cache/llm-orchestrator/task-resources")
        task = manager.start(self.project, "hook gates")
        token = manager.acquire(task["id"], "reader")["token"]
        manager.finish(task["id"])
        manager.release(task["id"], token, True)
        config = self.project / "docs/llm-orchestrator/cadence.json"
        config.parent.mkdir(parents=True)
        config.write_text(json.dumps({"enabled": True, "workflow": "proportional"}))
        command = ["bash", str(SOURCE.parents[1] / "hooks/orch-task-cleanup.sh")]
        env = {**os.environ, "HOME": str(fixture_home), "ORCH_HOOK_PROFILE": "standard",
               "ORCH_DISABLED_HOOKS": "", "ORCH_HOOK_DRY_RUN": "0"}
        for setting in ({"ORCH_HOOK_PROFILE": "minimal"},
                        {"ORCH_DISABLED_HOOKS": "other,orch-task-cleanup,third"},
                        {"ORCH_HOOK_DRY_RUN": "1"}):
            with self.subTest(setting=setting):
                result = subprocess.run(command, input=json.dumps({"cwd": str(self.project)}),
                                        env={**env, **setting}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(Path(task["scratch"]).exists())
        result = subprocess.run(command, input=json.dumps({"cwd": str(self.project)}),
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(Path(task["scratch"]).exists())

    def test_absent_artifact_root_settles_only_after_explicit_finish(self):
        self.scratch.rmdir()
        self.assertEqual(self.manager.finish(self.task_id, retry=True)["status"], "open")
        self.assertEqual(self.manager.finish(self.task_id)["status"], "done")

    def test_absent_root_with_unremoved_resource_stays_uncertain(self):
        copy = self.resource("copy")
        shutil.rmtree(self.scratch)
        result = self.manager.finish(self.task_id)
        self.assertEqual(result["status"], "closed")
        self.assertIn("ownership uncertain", str(result["reasons"]))
        self.assertFalse(copy.exists())

    def test_absent_root_from_incomplete_allocation_stays_uncertain(self):
        state = self.manager.read(self.task_id)
        state["identity"] = None
        self.manager.save(state)
        self.scratch.rmdir()
        result = self.manager.finish(self.task_id)
        self.assertEqual(result["status"], "closed")

    def test_owned_disposable_target_requires_real_lease_and_exact_project(self):
        target = self.scratch / "probe.py"
        self.assertFalse(MOD.owned_disposable_target(target, self.project))
        token = self.acquire("probe writer")
        self.assertTrue(MOD.owned_disposable_target(target, self.project))
        self.assertFalse(target.exists())  # recognition never creates target
        self.assertFalse(MOD.owned_disposable_target(target, self.root / "other-project"))
        copied = self.manager.create(self.task_id, token, "copy")
        copied_target = Path(copied["path"]) / "source.py"
        self.assertTrue(MOD.owned_disposable_target(copied_target, self.project))
        self.release(token)
        self.assertFalse(MOD.owned_disposable_target(copied_target, self.project))
        token = self.acquire("second writer")
        self.manager.finish(self.task_id)
        self.assertFalse(MOD.owned_disposable_target(copied_target, self.project))
        self.release(token)

    def test_owned_disposable_target_rejects_worktree_repo_spoof_and_symlinks(self):
        token = self.acquire()
        worktree = self.manager.create(self.task_id, token, "worktree")
        self.assertFalse(MOD.owned_disposable_target(Path(worktree["path"]) / "source.py", self.project))
        spoof = self.root / "fake-state/scratch" / ("a" * 32) / "probe.py"
        spoof.parent.mkdir(parents=True)
        before = sorted(str(path) for path in (self.root / "fake-state").rglob("*"))
        self.assertFalse(MOD.owned_disposable_target(spoof, self.project))
        self.assertEqual(before, sorted(str(path) for path in (self.root / "fake-state").rglob("*")))
        linked = self.scratch / "linked"
        linked.symlink_to(self.project, target_is_directory=True)
        self.assertFalse(MOD.owned_disposable_target(linked / "source.py", self.project))
        self.assertFalse(MOD.owned_disposable_target(self.scratch / ".." / "probe.py", self.project))
        repo = self.scratch / "unregistered-repo"
        repo.mkdir()
        self.git("init", "-q", cwd=repo)
        self.assertFalse(MOD.owned_disposable_target(repo / "source.py", self.project))
        copy = Path(self.manager.create(self.task_id, token, "copy")["path"])
        copy.rename(self.scratch / "moved-copy")
        copy.mkdir()
        self.assertFalse(MOD.owned_disposable_target(copy / "source.py", self.project))

    def test_owned_disposable_target_works_from_copied_skill_helper(self):
        installed = self.root / "installed-skill/scripts"
        (installed / "lib").mkdir(parents=True)
        shutil.copy2(SOURCE, installed / "lib/orch-task-resources.py")
        shutil.copy2(SOURCE.parents[2] / "skills/cadence/scripts/orch-task-resources.py",
                     installed / "orch-task-resources.py")
        command = [sys.executable, str(installed / "orch-task-resources.py"),
                   "--state-dir", str(self.manager.base)]
        result = subprocess.run(command + ["acquire", "--id", self.task_id, "--consumer", "installed"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lease = json.loads(result.stdout)
        result = subprocess.run(command + ["copy", "--id", self.task_id, "--token", lease["token"]],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        target = Path(json.loads(result.stdout)["path"]) / "source.py"
        self.assertTrue(MOD.owned_disposable_target(target, self.project))

    def test_successful_tombstones_expire_without_age_reaping_unfinished_work(self):
        opened = self.manager.start(self.project, "paused")
        token = self.acquire()
        self.manager.finish(self.task_id)
        closed = self.manager.read(self.task_id)
        closed["finished_at"] = 1
        self.manager.save(closed)
        done = self.manager.start(self.project, "finished")
        self.manager.finish(done["id"])
        state = self.manager.read(done["id"])
        state["finished_at"] = 1
        self.manager.save(state)
        done_state, done_lock, _ = self.manager.paths(done["id"])
        self.manager.prune_completed(now=MOD.Manager.RETENTION_SECONDS + 2)
        self.assertFalse(done_state.exists())
        self.assertFalse(done_lock.exists())
        self.assertTrue(self.scratch.exists())
        self.assertTrue(Path(opened["scratch"]).exists())
        self.assertIn(token, self.manager.read(self.task_id)["leases"])

    def test_pruning_never_unlinks_a_held_lifecycle_lock(self):
        self.manager.finish(self.task_id)
        state = self.manager.read(self.task_id)
        state["finished_at"] = 1
        self.manager.save(state)
        entered, proceed = CTX.Event(), CTX.Event()
        def operation():
            with self.manager.locked(self.task_id):
                entered.set()
                if not proceed.wait(5):
                    raise RuntimeError("test synchronization timeout")
        child = self.spawn(operation)
        self.assertTrue(entered.wait(5))
        self.manager.prune_completed(now=MOD.Manager.RETENTION_SECONDS + 2)
        manifest, lock, _ = self.manager.paths(self.task_id)
        self.assertTrue(manifest.exists())
        self.assertTrue(lock.exists())
        proceed.set()
        self.joined(child)
        self.manager.prune_completed(now=MOD.Manager.RETENTION_SECONDS + 2)
        self.assertFalse(manifest.exists())
        self.assertFalse(lock.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
