#!/usr/bin/env python3
"""Owned, opt-in task scratch lifecycle shared by Claude and Codex.

Consumers acquire a lease *before* accessing scratch, and explicitly attest that
they and their children stopped when releasing it. Stop hooks may only `retry`.
No age, PID, final-message text, or worktree mutex establishes task completion.
State and flock files live outside scratch and remain as small recovery records.
Successful records expire after seven days; unfinished records never expire.
Routine Stop retries only empty-root cleanup within a bounded registry scan.
Its limit warning requires explicit `retry --project` to visit the full registry
and prune completed records; nonempty tasks report their explicit retry command.
"""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import uuid


class Unsafe(Exception):
    pass


class RoutineBudget:
    """Bound metadata work across both parts of one routine cleanup invocation."""

    STATE_BYTES = 64 * 1024

    def __init__(self, entries=64, seconds=0.5):
        self.remaining = entries
        self.deadline = time.monotonic() + seconds
        self.exhausted = False

    def take(self):
        if self.remaining <= 0 or time.monotonic() >= self.deadline:
            self.exhausted = True
            return False
        self.remaining -= 1
        return True


def ident(path):
    value = path.lstat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
        raise Unsafe(f"not an owned directory: {path}")
    return [value.st_dev, value.st_ino]


def git(project, *args, timeout=None):
    try:
        result = subprocess.run(["git", "-C", str(project), *args],
                                capture_output=True, text=True, check=False, timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise Unsafe(f"git {' '.join(args[:2])} timed out") from error
    if result.returncode:
        raise Unsafe(f"git {' '.join(args[:2])}: {result.stderr.strip()}")
    return result.stdout


def canonical(value):
    path = Path(value).expanduser().absolute()
    if ".." in path.parts or path.is_symlink():
        raise Unsafe(f"symlink root or traversal: {path}")
    return path.resolve()


def nested(path, root):
    return path == root or root in path.parents


def identity_valid(value):
    return value is None or (isinstance(value, list) and len(value) == 2
                             and all(type(item) is int and item >= 0 for item in value))


class Manager:
    RETENTION_SECONDS = 7 * 24 * 60 * 60

    @staticmethod
    def default_base():
        return Path.home() / ".cache" / "llm-orchestrator" / "task-resources"

    def __init__(self, state_dir=None, create=True):
        self.base = canonical(state_dir or self.default_base())
        if create:
            self.base.mkdir(parents=True, mode=0o700, exist_ok=True)
        for directory in (self.base, self.base / "tasks", self.base / "locks", self.base / "scratch"):
            if create:
                directory.mkdir(mode=0o700, exist_ok=True)
            ident(directory)
            if directory.stat().st_mode & 0o077:
                raise Unsafe(f"state directory must be private (mode 700): {directory}")

    def paths(self, task_id):
        if not isinstance(task_id, str) or not re.fullmatch(r"[0-9a-f]{32}", task_id):
            raise Unsafe("invalid task id")
        return (self.base / "tasks" / f"{task_id}.json",
                self.base / "locks" / f"{task_id}.lock",
                self.base / "scratch" / task_id)

    @contextlib.contextmanager
    def file_lock(self, path, mode=fcntl.LOCK_EX, create=True):
        fd = os.open(path, (os.O_CREAT if create else 0) | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, mode)
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or info.st_ino != path.lstat().st_ino):
                raise Unsafe("lifecycle lock ownership changed")
            yield
        finally:
            os.close(fd)

    @contextlib.contextmanager
    def locked(self, task_id, new=False, existing_only=False, nonblocking=False):
        state_path, lock_path, _ = self.paths(task_id)
        for name in ("tasks", "locks", "scratch"):
            ident(self.base / name)
        # Shared admission remains held while acquiring the per-task lock.
        # Pruning cannot unlink its inode and admit a second lock holder.
        mode = fcntl.LOCK_NB if nonblocking else 0
        with contextlib.ExitStack() as task_lock:
            with self.file_lock(self.base / ".registry.lock", fcntl.LOCK_SH | mode,
                                create=not existing_only):
                if not new and not state_path.exists():
                    raise Unsafe("unknown or expired completed task")
                if new and (state_path.exists() or lock_path.exists()):
                    raise Unsafe("task identity already exists")
                task_lock.enter_context(self.file_lock(lock_path, fcntl.LOCK_EX | mode,
                                                       create=not existing_only))
            yield state_path

    def read(self, task_id, max_bytes=None):
        path, _, scratch = self.paths(task_id)
        value = path.lstat()
        if (not stat.S_ISREG(value.st_mode) or value.st_uid != os.getuid()
                or value.st_nlink != 1):
            raise Unsafe("unsafe task state")
        # Routine callers never read an arbitrarily large retained manifest.
        # O_NONBLOCK also prevents a replaced special file from stalling a hook.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            opened = os.fstat(stream.fileno())
            if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.getuid()
                    or opened.st_nlink != 1 or (opened.st_dev, opened.st_ino)
                    != (value.st_dev, value.st_ino)):
                raise Unsafe("task state ownership changed")
            raw = stream.read() if max_bytes is None else stream.read(max_bytes + 1)
        if max_bytes is not None and len(raw) > max_bytes:
            raise Unsafe(f"task record exceeds routine limit; run retry --id {task_id}")
        state = json.loads(raw)
        if (not isinstance(state, dict) or state.get("version") != 1
                or state.get("id") != task_id or state.get("scratch") != str(scratch)
                or state.get("status") not in {"open", "closed", "done"}
                or not isinstance(state.get("leases"), dict)
                or not isinstance(state.get("released"), list)
                or not isinstance(state.get("resources"), list)
                or not identity_valid(state.get("identity"))
                or not identity_valid(state.get("project_identity"))
                or not isinstance(state.get("common_dir"), str)):
            raise Unsafe("malformed task state")
        project = canonical(state["project"])
        if str(project) != state["project"] or nested(scratch, project):
            raise Unsafe("scratch is inside project or project path changed")
        seen = set()
        for resource in state["resources"]:
            if not isinstance(resource, dict):
                raise Unsafe("malformed resource record")
            name = resource.get("name", "")
            if (not re.fullmatch(r"(?:copy|worktree)-[0-9a-f]{32}", name)
                    or name in seen or resource.get("kind") not in {"copy", "worktree"}
                    or not name.startswith(resource["kind"] + "-")
                    or not identity_valid(resource.get("identity"))
                    or type(resource.get("removed")) is not bool):
                raise Unsafe("malformed resource ownership")
            seen.add(name)
        for token, consumer in state["leases"].items():
            if not re.fullmatch(r"[0-9a-f]{32}", token) or not isinstance(consumer, str):
                raise Unsafe("malformed consumer lease")
        return state

    def save(self, state):
        path, _, _ = self.paths(state["id"])
        fd, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(state, stream, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def result(self, state):
        return {**state, "state": str(self.paths(state["id"])[0]),
                "recovery": f"retry --id {state['id']}"}

    def start(self, project, task):
        project = canonical(project)
        top = canonical(git(project, "rev-parse", "--show-toplevel").strip())
        if (project != top or nested(self.base, project) or nested(project, self.base)
                or git(project, "rev-parse", "--show-superproject-working-tree").strip()):
            raise Unsafe("project must be its Git root and state storage must be outside it")
        task_id = uuid.uuid4().hex
        _, _, scratch = self.paths(task_id)
        common = Path(git(project, "rev-parse", "--git-common-dir").strip())
        common = canonical(common if common.is_absolute() else project / common)
        with self.locked(task_id, new=True):
            state = dict(version=1, id=task_id, task=task, project=str(project),
                         project_identity=ident(project),
                         common_dir=str(common),
                         scratch=str(scratch), identity=None, status="open", leases={},
                         released=[], resources=[], reasons=[])
            # An interrupted allocation is registered but never retroactively claimed.
            self.save(state)
            scratch.mkdir(mode=0o700)
            state["identity"] = ident(scratch)
            self.save(state)
            return self.result(state)

    def owned(self, path, expected):
        if expected is None or ident(path) != expected or path.resolve() != path:
            raise Unsafe(f"resource missing, replaced or uncertain: {path}")

    def project_valid(self, state, timeout=None):
        project = Path(state["project"])
        self.owned(project, state["project_identity"])
        common = git(project, "rev-parse", "--git-common-dir", timeout=timeout).strip()
        actual = canonical(Path(common) if Path(common).is_absolute() else project / common)
        if str(actual) != state["common_dir"]:
            raise Unsafe("project repository changed")
        return project

    def acquire(self, task_id, consumer):
        with self.locked(task_id):
            state = self.read(task_id)
            if state["status"] != "open":
                raise Unsafe("task is closed to new consumers")
            self.owned(Path(state["scratch"]), state["identity"])
            if not consumer or consumer in state["leases"].values():
                raise Unsafe("consumer must be named and cannot hold duplicate leases")
            token = uuid.uuid4().hex
            state["leases"][token] = consumer
            self.save(state)
            return {"id": task_id, "token": token, "scratch": state["scratch"]}

    def release(self, task_id, token, stopped=False):
        if not stopped:
            raise Unsafe("release requires --stopped after verifying consumer and children stopped")
        with self.locked(task_id):
            state = self.read(task_id)
            if token in state["leases"]:
                del state["leases"][token]
                state["released"].append(token)
                self.save(state)
            elif token not in state["released"]:
                raise Unsafe("unknown consumer generation")
            return self.result(state)

    def create(self, task_id, token, kind, ref="HEAD", branch=None):
        if kind not in {"copy", "worktree"} or ref.startswith("-") or (branch and branch.startswith("-")):
            raise Unsafe("invalid resource kind or Git ref")
        with self.locked(task_id):
            state = self.read(task_id)
            if state["status"] != "open" or token not in state["leases"]:
                raise Unsafe("resource creation needs an active lease on an open task")
            project = self.project_valid(state)
            scratch = Path(state["scratch"])
            self.owned(scratch, state["identity"])
            name = f"{kind}-{uuid.uuid4().hex}"
            path = scratch / name
            resource = dict(name=name, kind=kind, identity=None, removed=False)
            state["resources"].append(resource)
            self.save(state)
            if kind == "worktree":
                # Never claim an existing branch as owned; branches are always retained.
                args = ["worktree", "add"]
                args += ["-b", branch] if branch else ["--detach"]
                git(project, *args, str(path), ref)
            else:
                path.mkdir(mode=0o700)
            resource["identity"] = ident(path)
            self.save(state)
            if kind == "copy":
                self.snapshot(project, path)
            return {"id": task_id, "path": str(path), "kind": kind}

    def snapshot(self, project, destination):
        # An explicitly disposable copy of current tracked and nonignored files.
        # Never copy .git, ignored dependency trees, submodules, or external links.
        names = set(git(project, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split("\0"))
        for name in sorted(names - {""}):
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts or ".git" in relative.parts:
                raise Unsafe("unsafe snapshot path")
            source = project / relative
            if any(part.is_symlink() for part in source.parents if part != project and nested(part, project)):
                raise Unsafe(f"snapshot parent is a symlink: {source}")
            if not source.exists() and not source.is_symlink():
                continue
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if source.is_symlink():
                target.symlink_to(os.readlink(source))
            elif source.is_file():
                shutil.copy2(source, target)
            else:
                raise Unsafe(f"submodule or unsupported snapshot entry: {source}")

    def worktree_safe(self, state, path):
        project = self.project_valid(state)
        records = git(project, "worktree", "list", "--porcelain", "-z").split("\0\0")
        match = [record.split("\0") for record in records
                 if record.split("\0")[0] == f"worktree {path}"]
        marker = path / ".git"
        if (len(match) != 1 or marker.is_symlink() or not marker.is_file()
                or any(line == "locked" or line.startswith("locked ") for line in match[0])
                or git(path, "rev-parse", "--show-superproject-working-tree").strip()):
            raise Unsafe("not an unlocked owned linked worktree")
        common = git(path, "rev-parse", "--git-common-dir").strip()
        if str(canonical(Path(common) if Path(common).is_absolute() else path / common)) != state["common_dir"]:
            raise Unsafe("worktree belongs to another repository")
        if git(path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"):
            raise Unsafe("worktree contains tracked, staged, untracked or ignored changes")
        head = git(path, "rev-parse", "HEAD").strip()
        if not git(project, "for-each-ref", "--contains", head, "--format=%(refname)",
                   "refs/heads", "refs/tags", "refs/remotes").strip():
            raise Unsafe("worktree commits have no retained named ref")

    def cleanup(self, state, routine=False):
        scratch = Path(state["scratch"])
        reasons = []
        if state["leases"]:
            return ["active consumers: " + ", ".join(state["leases"].values())]
        if not scratch.exists() and not scratch.is_symlink():
            # A completed task with every resource already removed has nothing
            # left to recover if its artifact root was subsequently removed by
            # hand. Unknown allocations and unremoved worktrees stay uncertain.
            settled = (state["identity"] is not None
                       and all(resource["removed"] for resource in state["resources"]))
            return [] if state.get("deleting_root") or settled else ["scratch is missing; ownership uncertain"]
        self.owned(scratch, state["identity"])
        if not shutil.rmtree.avoids_symlink_attacks:
            return ["Python lacks safe descriptor-based recursive deletion"]
        if (scratch / ".orch-active").exists() or (scratch / ".orch-active").is_symlink():
            return ["scratch has an active or uncertain writer mutex"]
        if routine:
            # Stop never traverses trees, invokes Git cleanup or starts recursive
            # deletion. Even a previously small tree may have grown since finish.
            deferred = [f"cleanup deferred; run retry --id {state['id']} for complete cleanup"]
            if any(not resource["removed"] for resource in state["resources"]):
                return deferred
            with os.scandir(scratch) as entries:
                if next(entries, None) is not None:
                    return deferred
            state["deleting_root"] = True
            self.save(state)
            self.owned(scratch, state["identity"])
            scratch.rmdir()  # one empty owned directory; a new child prevents removal
            return []
        for resource in state["resources"]:
            path = scratch / resource["name"]
            if resource["removed"]:
                if path.exists() or path.is_symlink():
                    reasons.append(f"replacement appeared after removal: {path}")
                continue
            try:
                if not path.exists() and not path.is_symlink() and resource.get("deleting"):
                    resource["removed"] = True
                    self.save(state)
                    continue
                self.owned(path, resource["identity"])
                if (path / ".orch-active").exists() or (path / ".orch-active").is_symlink():
                    raise Unsafe("active or uncertain writer mutex")
                if resource["kind"] == "worktree":
                    self.worktree_safe(state, path)
                elif self.repository_inside(path):
                    raise Unsafe("copy contains a repository; writer ownership is uncertain")
                resource["deleting"] = True
                self.save(state)
                self.owned(path, resource["identity"])
                if resource["kind"] == "worktree":
                    git(Path(state["project"]), "worktree", "remove", str(path))
                else:
                    shutil.rmtree(path)
                resource["removed"] = True
                self.save(state)
            except (Unsafe, OSError) as error:
                reasons.append(f"{path}: {error}")
        if reasons:
            return reasons
        if self.repository_inside(scratch):
            return ["unregistered repository remains in scratch"]
        state["deleting_root"] = True
        self.save(state)
        self.owned(scratch, state["identity"])
        shutil.rmtree(scratch)
        return []

    @staticmethod
    def repository_inside(path):
        for _, dirs, files in os.walk(path, followlinks=False):
            if ".git" in dirs or ".git" in files or ".orch-active" in dirs or ".orch-active" in files:
                return True
            if "HEAD" in files and "objects" in dirs and "refs" in dirs:
                return True  # bare repositories also contain unique work
        return False

    def finish(self, task_id, retry=False):
        with self.locked(task_id):
            state = self.read(task_id)
            if state["status"] == "done" or (retry and state["status"] == "open"):
                return self.result(state)
            return self.finish_locked(state)

    def finish_locked(self, state, routine=False):
        state["status"] = "closed"
        self.save(state)  # admission stays closed even after interruption/failure
        try:
            state["reasons"] = self.cleanup(state, routine=True) if routine else self.cleanup(state)
        except (Unsafe, OSError) as error:
            state["reasons"] = [str(error)]
        if not state["reasons"]:
            state["status"] = "done"
            state["finished_at"] = time.time()
        self.save(state)
        return self.result(state)

    def task_paths(self, budget=None):
        # glob/sorting can enumerate the entire registry before the first yield.
        with os.scandir(self.base / "tasks") as entries:
            while budget is None or budget.take():
                entry = next(entries, None)
                if entry is None:
                    return
                if entry.name.endswith(".json"):
                    yield Path(entry.path)

    def retry_project(self, project, routine=False, budget=None):
        project = str(canonical(project))
        budget = (budget or RoutineBudget()) if routine else None
        max_bytes = RoutineBudget.STATE_BYTES if routine else None
        results = []
        for path in self.task_paths(budget):
            try:
                # This atomic-manifest read only selects candidates. Recheck
                # under admission/task locks before changing or deleting anything.
                state = self.read(path.stem, max_bytes=max_bytes)
                if state["project"] != project or state["status"] != "closed":
                    continue
                with self.locked(path.stem, nonblocking=routine, existing_only=routine):
                    state = self.read(path.stem, max_bytes=max_bytes)
                    if state["project"] == project and state["status"] == "closed":
                        results.append(self.finish_locked(state, routine=routine))
            except BlockingIOError:
                results.append({"state": str(path), "status": "blocked", "reasons": [
                    f"task lifecycle is busy; run retry --id {path.stem}"]})
            except (Unsafe, OSError, ValueError, KeyError, TypeError) as error:
                results.append({"state": str(path), "status": "blocked", "reasons": [str(error)]})
        return {"tasks": results}

    def prune_completed(self, project=None, now=None, budget=None):
        """Expire safe tombstones; Stop supplies a budget, explicit CLI visits all."""
        now = time.time() if now is None else now
        try:
            with self.file_lock(self.base / ".registry.lock", fcntl.LOCK_EX | fcntl.LOCK_NB):
                for path in self.task_paths(budget):
                    try:
                        _, lock, scratch = self.paths(path.stem)
                        with self.file_lock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB):
                            state = self.read(path.stem, max_bytes=(
                                RoutineBudget.STATE_BYTES if budget is not None else None))
                            if (state["status"] != "done" or state["leases"]
                                    or (project is not None and state["project"] != str(project))
                                    or type(state.get("finished_at")) not in (int, float)
                                    or now - state["finished_at"] < self.RETENTION_SECONDS
                                    or scratch.exists() or scratch.is_symlink()):
                                continue
                            # Nobody holds/waits for this lock, and admission is closed.
                            # Remove lock first: interruption then leaves an intact done
                            # tombstone, whose next operation may recreate its lock.
                            lock.unlink()
                            path.unlink()
                    except (Unsafe, OSError, ValueError, KeyError, TypeError):
                        continue  # uncertain records remain for explicit recovery
        except BlockingIOError:
            return ["completed-task pruning deferred: task registry is busy"]
        return []


def owned_disposable_target(path, project):
    """Recognize leased disposable scratch from existing helper state, read-only.

    Infer custom storage from its exact managed layout, never from a filename
    prefix alone. Writer worktrees are deliberately outside this exemption.
    False means unknown ownership; callers must retain normal source uncertainty.
    """
    try:
        target = Path(path).expanduser().absolute()
        if ".." in target.parts or target.resolve() != target:
            return False
        project = canonical(project)
        for scratch in (target, *target.parents):
            if scratch.parent.name != "scratch" or not re.fullmatch(r"[0-9a-f]{32}", scratch.name):
                continue
            manager = Manager(scratch.parent.parent, create=False)
            with manager.locked(scratch.name, existing_only=True, nonblocking=True):
                state = manager.read(scratch.name, max_bytes=RoutineBudget.STATE_BYTES)
                if (state["project"] != str(project) or state["status"] != "open"
                        or not state["leases"]):
                    return False
                manager.project_valid(state, timeout=0.5)
                manager.owned(scratch, state["identity"])
                relative = target.relative_to(scratch)
                if ".git" in relative.parts:
                    return False
                if relative.parts:
                    for resource in state["resources"]:
                        if resource["name"] == relative.parts[0]:
                            if resource["kind"] != "copy" or resource["removed"]:
                                return False
                            manager.owned(scratch / resource["name"], resource["identity"])
                for ancestor in (target, *target.parents):
                    if not nested(ancestor, scratch):
                        break
                    if ((ancestor / ".git").exists() or (ancestor / ".git").is_symlink()
                            or ((ancestor / "HEAD").exists() and (ancestor / "objects").is_dir()
                                and (ancestor / "refs").is_dir())):
                        return False
                return True
    except (Unsafe, OSError, ValueError, KeyError, TypeError):
        pass
    return False


def hook_retry(state_dir=None, payload=None):
    """A Stop is only a chance to retry an explicitly finished opted-in task."""
    try:
        if payload is None:
            if sys.stdin.isatty():
                return
            payload = json.load(sys.stdin)
        if not isinstance(payload, dict):
            raise Unsafe("hook payload must be an object")
        # The same starting point as orch_cadence_find in scripts/lib/orch-project.sh.
        cwd = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
        if not isinstance(cwd, str):
            raise Unsafe("hook cwd must be a path")
        resolved_cwd = canonical(cwd)
        budget = RoutineBudget()
        probe = subprocess.run(["git", "-C", str(resolved_cwd), "rev-parse", "--show-toplevel"],
                               capture_output=True, text=True, check=False,
                               timeout=max(0.001, budget.deadline - time.monotonic()),
                               env={**os.environ, "LC_ALL": "C"})
        if probe.returncode:
            if "not a git repository" in probe.stderr:
                return  # A normal Stop outside a repository is not an error.
            raise Unsafe(f"cannot locate hook project: {probe.stderr.strip()}")
        project = canonical(probe.stdout.strip())
        # The nearest cadence.json from the start up to the Git root, as
        # orch_cadence_find decides it; tasks stay keyed by the Git root.
        config_path = next((d / "docs/llm-orchestrator/cadence.json"
                            for d in [resolved_cwd, *resolved_cwd.parents]
                            if nested(d, project)
                            if (d / "docs/llm-orchestrator/cadence.json").exists()), None)
        if config_path is None:
            return
        config = json.loads(config_path.read_text())
        if not isinstance(config, dict) or type(config.get("enabled")) is not bool:
            raise Unsafe("invalid cadence enabled setting")
        if not config["enabled"]:
            return
        workflow = config.get("workflow", "legacy")
        if workflow not in {"legacy", "proportional"}:
            raise Unsafe("invalid cadence workflow setting")
        if workflow != "proportional":
            return
        if not canonical(state_dir or Manager.default_base()).exists():
            return
        manager = Manager(state_dir)
        result = manager.retry_project(project, routine=True, budget=budget)
        for task in result["tasks"]:
            if task["status"] != "done":
                print(f"task cleanup retained {task.get('state')}: {task.get('reasons')}", file=sys.stderr)
        for reason in manager.prune_completed(project, budget=budget):
            print(f"task cleanup skipped: {reason}", file=sys.stderr)
        if budget.exhausted:
            print(f"task cleanup deferred: routine metadata budget exhausted; "
                  f"run retry --project {project} for complete cleanup", file=sys.stderr)
    except (Unsafe, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        print(f"task cleanup skipped: {error}", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", help="private external state directory (default: user cache)")
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("start")
    start.add_argument("--project", required=True)
    start.add_argument("--task", required=True)
    sub.add_parser("hook-retry")
    for command in ("acquire", "release", "copy", "worktree", "finish", "status", "retry"):
        item = sub.add_parser(command)
        item.add_argument("--id", required=command != "retry")
        if command == "acquire":
            item.add_argument("--consumer", required=True)
        if command in {"release", "copy", "worktree"}:
            item.add_argument("--token", required=True)
        if command == "release":
            item.add_argument("--stopped", action="store_true")
        if command == "worktree":
            item.add_argument("--ref", default="HEAD")
            item.add_argument("--branch")
        if command == "retry":
            item.add_argument("--project")
    args = parser.parse_args(argv)
    if args.command == "hook-retry":
        hook_retry(args.state_dir)
        return 0
    try:
        manager = Manager(args.state_dir)
        if args.command == "start":
            result = manager.start(args.project, args.task)
        elif args.command == "acquire":
            result = manager.acquire(args.id, args.consumer)
        elif args.command == "release":
            result = manager.release(args.id, args.token, args.stopped)
        elif args.command in {"copy", "worktree"}:
            result = manager.create(args.id, args.token, args.command,
                                    getattr(args, "ref", "HEAD"), getattr(args, "branch", None))
        elif args.command == "status":
            with manager.locked(args.id):
                result = manager.result(manager.read(args.id))
        elif args.command == "retry" and args.project and not args.id:
            result = manager.retry_project(args.project)
        elif args.command == "retry" and (args.project or not args.id):
            raise Unsafe("retry needs exactly one of --id or --project")
        else:
            result = manager.finish(args.id, retry=args.command == "retry")
        manager.prune_completed()
        print(json.dumps(result, sort_keys=True))
        return 2 if result.get("status") == "closed" or any(
            task.get("status") in {"closed", "blocked"} for task in result.get("tasks", [])) else 0
    except (Unsafe, OSError, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "blocked", "error": str(error)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
