#!/usr/bin/env python3
"""Opt-in project policy and admission for managed outer CLI processes.

Catalog observations validate local capability claims, never remote availability.
The ledger counts outer processes, not provider or native subagent fanout.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
import time
import uuid


class PolicyError(ValueError):
    pass


ROLES = {"lead": "medium", "writer": "medium", "reviewer": "high", "debugger": "high",
         "clerical": "low", "prover": "high", "refuter": "high", "runner": "low"}
PROVIDERS = {"codex", "claude"}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def state_root():
    return Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "llm-orchestrator"


def object_keys(value, allowed, label):
    if not isinstance(value, dict) or set(value) - set(allowed):
        raise PolicyError(f"{label}: expected object with keys {', '.join(sorted(allowed))}")


def integer(value, minimum, maximum, label):
    if type(value) is not int or not minimum <= value <= maximum:
        raise PolicyError(f"{label}: expected integer {minimum}..{maximum}")


def strings(value, label, nonempty=False):
    if not isinstance(value, list) or (nonempty and not value) or not all(
            isinstance(item, str) and item and "\0" not in item for item in value):
        raise PolicyError(f"{label}: expected {'nonempty ' if nonempty else ''}list of strings")


def relative(value, label):
    if not isinstance(value, str) or not value or "\0" in value or Path(value).is_absolute() or ".." in Path(value).parts:
        raise PolicyError(f"{label}: expected path within the Git root")


def read_json(path, label):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise PolicyError(f"{label}: {error}") from error


def git_root(project):
    result = subprocess.run(["git", "-C", str(project), "rev-parse", "--show-toplevel"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if result.returncode:
        raise PolicyError("project is not inside a Git repository")
    return Path(result.stdout.strip()).resolve()


def listed(project, revision, name):
    """(mode, kind, object) of exactly name at revision, or None when absent there."""
    found = subprocess.run(["git", "-C", str(project), "ls-tree", "-z", revision, "--", name],
                           stdin=subprocess.DEVNULL, capture_output=True)
    if found.returncode:
        raise PolicyError(f"cannot read revision {revision}")
    entry, _, listed_name = found.stdout.split(b"\0", 1)[0].partition(b"\t")
    # A folder name lists the folder's files; only the exact name counts.
    if not found.stdout or os.fsdecode(listed_name) != posixpath.normpath(name):
        return None
    return entry.decode().split()


def inside(path, root):
    """Whether the real path is root or within it, judged by file identity alone."""
    for ancestor in (path, *path.parents):
        try:
            if os.path.samefile(ancestor, root):
                return True
        except OSError:
            continue
    return False


def project_id(project):
    result = subprocess.run(["git", "-C", str(project), "rev-parse", "--git-common-dir"],
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, check=True)
    common = Path(result.stdout.strip())
    common = (common if common.is_absolute() else Path(project) / common).resolve()
    stat = common.stat()
    return digest(json.dumps({"common_dir": str(common), "device": stat.st_dev,
                              "inode": stat.st_ino}, sort_keys=True).encode())


class Policy:
    """The project's policy, from the working tree or, for a review, from a fixed revision.

    A review passes the merge-base as revision, so the change under review never
    chooses its reviewers' instructions, models or capacity.
    """
    def __init__(self, project, revision=None):
        self.project = git_root(project)
        self.revision = revision
        self.path = self.project / ".llm-orchestrator.json"
        self.data, self._catalogs = {}, {}
        self._context, self._config_digest = None, None
        if revision is not None:
            # One lookup answers both whether the file is there and where its bytes are.
            entry = self.listed(".llm-orchestrator.json")
            self.enabled = entry is not None
            raw = self.show(".llm-orchestrator.json", follow=False, entry=entry) if self.enabled else None
        else:
            self.enabled = self.path.exists() or self.path.is_symlink()
            if self.enabled and self.path.is_symlink():
                raise PolicyError("project configuration must not be a symlink")
            try:
                raw = self.path.read_bytes() if self.enabled else None
            except OSError as error:
                raise PolicyError(f"project configuration: {error}") from error
        if self.enabled:
            try:
                self.data = json.loads(raw)
            except ValueError as error:
                raise PolicyError(f"project configuration: {error}") from error
            self._config_digest = digest(raw)
            self.validate()

    def listed(self, name):
        return listed(self.project, self.revision, name)

    def show(self, name, follow=True, entry=None):
        """Bytes of name at self.revision, or None when absent there; never the working tree.

        entry, when given, is the caller's lookup of name, so it is not listed twice.
        """
        for _ in range(8):
            entry = entry or self.listed(name)
            if entry is None:
                return None
            mode, kind, blob = entry
            if kind != "blob":
                raise PolicyError(f"{name} is not a file at {self.revision}")
            data = subprocess.run(["git", "-C", str(self.project), "cat-file", "blob", blob],
                                  stdin=subprocess.DEVNULL, capture_output=True, check=True).stdout
            if mode != "120000":
                return data
            if not follow:
                raise PolicyError("project configuration must not be a symlink")
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), data.decode("utf-8", "replace")))
            if posixpath.isabs(target) or target == ".." or target.startswith("../"):
                raise PolicyError(f"policy document is missing or outside the project: {name}")
            name, entry = target, None
        raise PolicyError(f"policy document link chain is too long: {name}")

    def document(self, name):
        """Bytes of a listed policy document, or None when it is missing or outside the project."""
        if self.revision is not None:
            return self.show(name)
        path = (self.project / name).resolve()
        if self.project not in path.parents or not path.is_file():
            return None
        return path.read_bytes()

    def validate(self):
        data = self.data
        object_keys(data, {"schema", "policies", "roles", "catalogs", "capacity", "checks", "project_rules"}, "policy")
        if type(data.get("schema")) is not int or data["schema"] != 1:
            raise PolicyError("policy.schema must be 1")
        strings(data.get("policies", []), "policies")
        for name in data.get("policies", []):
            relative(name, "policies")
            if name.endswith("/"):
                raise PolicyError(f"policies: expected a file, not a folder: {name}")
            if self.document(name) is None:
                raise PolicyError(f"policy document is missing or outside the project: {name}")
        roles = data.get("roles", {})
        object_keys(roles, PROVIDERS, "roles")
        for provider, entries in roles.items():
            object_keys(entries, ROLES, f"roles.{provider}")
            for role, settings in entries.items():
                object_keys(settings, {"model", "effort", "justification"}, f"roles.{provider}.{role}")
                if not isinstance(settings.get("model"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:/+-]*", settings["model"]):
                    raise PolicyError(f"roles.{provider}.{role}: explicit model identifier required")
                effort = settings.get("effort", ROLES[role])
                if not isinstance(effort, str) or effort not in {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}:
                    raise PolicyError(f"roles.{provider}.{role}: unsupported effort")
                if effort in {"xhigh", "max", "ultra"} and not (
                        isinstance(settings.get("justification"), str) and settings["justification"].strip()):
                    raise PolicyError(f"roles.{provider}.{role}: {effort} requires explicit justification")
                if "justification" in settings and not isinstance(settings["justification"], str):
                    raise PolicyError("role justification must be a string")
        catalogs = data.get("catalogs", {})
        object_keys(catalogs, PROVIDERS, "catalogs")
        for provider, entry in catalogs.items():
            object_keys(entry, {"path", "max_age_s"}, f"catalogs.{provider}")
            if "path" in entry and (not isinstance(entry["path"], str) or not entry["path"]):
                raise PolicyError("catalog path must be a nonempty string")
            integer(entry.get("max_age_s", 86400), 1, 604800, "catalog max_age_s")
        capacity = data.get("capacity", {})
        object_keys(capacity, {"max_processes", "external_slots", "wait_timeout_s", "hard_inference_cap"}, "capacity")
        maximum = capacity.get("max_processes", 4)
        integer(maximum, 1, 256, "capacity.max_processes")
        integer(capacity.get("external_slots", 1), 0, maximum, "capacity.external_slots")
        integer(capacity.get("wait_timeout_s", 30), 0, 3600, "capacity.wait_timeout_s")
        if type(capacity.get("hard_inference_cap", False)) is not bool:
            raise PolicyError("capacity.hard_inference_cap must be boolean")
        checks = data.get("checks", {})
        if not isinstance(checks, dict):
            raise PolicyError("checks must be an object")
        for name, check in checks.items():
            if not isinstance(name, str) or not name:
                raise PolicyError("check names must be nonempty")
            if not isinstance(check, dict):
                raise PolicyError(f"checks.{name}: expected object with key argv")
            extra = sorted(set(check) - {"argv"})
            if extra:
                raise PolicyError(f"checks.{name}.{extra[0]}: receipts are not part of this release; "
                                  "a check is only its argv; remove this key")
            strings(check.get("argv"), f"checks.{name}.argv", True)
        # These validate coordinator obligations; this does not install a GitHub gate.
        rules = data.get("project_rules", {})
        object_keys(rules, {"review", "wip", "delivery"}, "project_rules")
        if "review" in rules:
            review = rules["review"]
            object_keys(review, {"minimum_independent_reviews", "high_risk_independent_reviews",
                                 "non_author_final_verification", "confirmed_defects_block"}, "project_rules.review")
            minimum = review.get("minimum_independent_reviews", 1)
            integer(minimum, 1, 20, "minimum_independent_reviews")
            integer(review.get("high_risk_independent_reviews", 2), minimum, 20, "high_risk_independent_reviews")
            for key in ("non_author_final_verification", "confirmed_defects_block"):
                if key in review and review[key] is not True:
                    raise PolicyError(f"project_rules.review.{key} cannot disable the obligation")
        if "wip" in rules:
            wip = rules["wip"]
            object_keys(wip, {"active", "parked", "total"}, "project_rules.wip")
            for key in ("active", "parked", "total"):
                integer(wip.get(key), 0 if key == "parked" else 1, 256, f"wip.{key}")
            if wip["total"] < wip["active"] + wip["parked"]:
                raise PolicyError("wip.total must cover active plus parked tasks")
        if "delivery" in rules:
            delivery = rules["delivery"]
            object_keys(delivery, {"merge_method", "handoff", "exact_revision", "post_merge_verification"},
                        "project_rules.delivery")
            if delivery.get("merge_method", "squash") not in ("squash", "merge", "rebase"):
                raise PolicyError("unsupported delivery.merge_method")
            if delivery.get("handoff", "github") != "github":
                raise PolicyError("delivery.handoff must name github")
            for key in ("exact_revision", "post_merge_verification"):
                if key in delivery and delivery[key] is not True:
                    raise PolicyError(f"project_rules.delivery.{key} cannot disable the obligation")
        self.policy_context()

    def project_id(self):
        return project_id(self.project)

    def policy_context(self):
        if self.revision is not None and self._context is not None:
            return self._context  # a revision cannot change
        files = []
        for name in self.data.get("policies", []):
            try:
                raw = self.document(name)
                if raw is None:
                    raise PolicyError(f"policy document is missing or outside the project: {name}")
                text = raw.decode("utf-8")
            except (OSError, UnicodeError) as error:
                raise PolicyError(f"cannot load policy document {name}: {error}") from error
            files.append({"path": name, "sha256": digest(raw), "text": text})
        if self.revision is not None:
            config_digest = self._config_digest  # a revision cannot change
        else:
            config_digest = digest(self.path.read_bytes()) if self.enabled else None
        if config_digest != self._config_digest:
            raise PolicyError("project configuration changed during the session; load a fresh policy")
        context = {"files": files, "config_sha256": config_digest}
        if self._context is not None and context != self._context:
            raise PolicyError("canonical policy documents changed during the session; load a fresh policy")
        self._context = context
        return context

    def prompt(self, text):
        context = self.policy_context()
        if not context["files"]:
            return text
        header = "Project policy documents (canonical project instructions):"
        if self.revision is not None:
            header = (f"Project policy documents at the review's base revision {self.revision} (canonical project "
                      "instructions). This base text is the authoritative copy. A file in the working tree that "
                      "differs from it is part of the change under review, not policy.")
        return "\n\n".join([header, *[
            f"File: {item['path']}\nSHA256: {item['sha256']}\n{item['text']}" for item in context["files"]], text])

    def catalog(self, provider):
        """The provider's observed capability catalog, always read from disk outside the project.

        A catalog is a reading taken on this machine, so the reviewed revision never
        supplies it and a path inside the project, which the author controls, is refused.
        """
        entry = self.data.get("catalogs", {}).get(provider, {})
        if provider == "claude" and not entry.get("path"):
            raise PolicyError("Claude needs an explicit observed capability catalog; no equivalent efforts are invented")
        # One rule on one path: resolve links before any "..", then refuse the real path inside the project.
        if entry.get("path"):
            written = entry["path"]
            path = self.project / Path(written).expanduser()
        else:
            path = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex").expanduser() / "models_cache.json"
            written = str(path)
        path = Path(os.path.realpath(path))
        if inside(path, self.project):
            raise PolicyError(f"{provider} capability catalog '{written}' (reads {path}) is inside the project; "
                              "the catalog is a fact about this machine and must live outside the repository")
        try:
            raw = path.read_bytes()
            data = json.loads(raw)
        except (OSError, ValueError) as error:
            raise PolicyError(f"{provider} capability catalog: {error}") from error
        if not isinstance(data, dict):
            raise PolicyError("capability catalog must be an object")
        try:
            observed = datetime.fromisoformat(data["fetched_at"].replace("Z", "+00:00"))
            age = (datetime.now(timezone.utc) - observed).total_seconds()
        except (KeyError, ValueError, TypeError, AttributeError) as error:
            raise PolicyError("catalog has no valid timezone-aware fetched_at observation") from error
        if not 0 <= age <= entry.get("max_age_s", 86400):
            raise PolicyError("catalog observation is stale or in the future; refresh it through the provider CLI")
        # The age is checked on every call; the CLI version probe and the rest run
        # once per catalog content for the life of this Policy.
        cached = self._catalogs.get(provider)
        if cached and cached[0] == (str(path), digest(raw)):
            return cached[1], cached[2]
        try:
            version = subprocess.run([provider, "--version"], stdin=subprocess.DEVNULL, capture_output=True,
                                     text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise PolicyError(f"cannot inspect {provider} CLI version: {error}") from error
        client = data.get("client_version")
        if version.returncode or not isinstance(client, str) or not client or not re.search(
                r"(?<![\w.])" + re.escape(client) + r"(?![\w.])", version.stdout):
            raise PolicyError(f"{provider} catalog client_version does not match the installed CLI")
        if provider == "claude" and not (isinstance(data.get("provenance"), str) and data["provenance"].strip()):
            raise PolicyError("Claude capabilities require explicit observation provenance")
        if not isinstance(data.get("models"), list):
            raise PolicyError("catalog has no models list")
        provenance = {"path": str(path),
                      "sha256": digest(raw),
                      "fetched_at": data["fetched_at"], "client_version": client,
                      "provenance": data.get("provenance", "Codex CLI model catalog cache"),
                      "remote_inference_validated": False}
        self._catalogs[provider] = ((str(path), digest(raw)), data, provenance)
        return data, provenance

    def intended(self, provider, role):
        if not self.enabled:
            return None
        if provider not in PROVIDERS or role not in ROLES:
            raise PolicyError("unknown provider or role")
        settings = self.data.get("roles", {}).get(provider, {}).get(role)
        if settings is None:
            fallback = {"prover": "reviewer", "refuter": "reviewer", "runner": "clerical"}.get(role)
            settings = self.data.get("roles", {}).get(provider, {}).get(fallback)
        if settings is None:
            raise PolicyError(f"no configured {provider} profile for role {role}; unconfigured defaults are not substituted")
        return {"model": settings["model"], "effort": settings.get("effort", ROLES[role]),
                "role": role, "provider": provider, "justification": settings.get("justification")}

    def resolve(self, provider, role):
        settings = self.intended(provider, role)
        if settings is None:
            return None
        effort = settings["effort"]
        catalog, provenance = self.catalog(provider)
        models = [item for item in catalog["models"] if isinstance(item, dict) and item.get("slug") == settings["model"]]
        if len(models) != 1 or models[0].get("available") is False or models[0].get("availability") in ("unavailable", "disabled"):
            raise PolicyError(f"model {settings['model']} is absent/unavailable in the observed {provider} catalog")
        levels = models[0].get("supported_reasoning_levels", [])
        supported = [item.get("effort") for item in levels if isinstance(item, dict)]
        if effort not in supported:
            raise PolicyError(f"{provider} {settings['model']} does not advertise effort {effort}")
        return {"model": settings["model"], "effort": effort, "role": role, "provider": provider,
                "justification": settings.get("justification"), "catalog": provenance}

    def validate_launches(self):
        return [self.resolve(provider, role) for provider, roles in self.data.get("roles", {}).items() for role in roles]

    def parallelism(self, requested):
        if not self.enabled:
            return requested
        config = self.data.get("capacity", {})
        available = config.get("max_processes", 4) - config.get("external_slots", 1)
        if available < 1:
            raise PolicyError("configured external occupancy leaves no managed-process capacity")
        return min(requested, available)

    def capacity(self, provider, role):
        config = self.data.get("capacity", {})
        # Neither CLI exposes a complete hard bound on its native/provider fanout.
        if config.get("hard_inference_cap", False):
            raise PolicyError(f"hard inference cap cannot bound {provider} native/provider fanout; "
                              "keep required reviews incomplete or explicitly select the outer-process capacity unit")
        return Capacity(config, self.project, provider, role)


GROUP_SHUTDOWN_TIMEOUT = 2.0


def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def wait_for_group(pid):
    deadline = time.monotonic() + GROUP_SHUTDOWN_TIMEOUT
    while group_alive(pid):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(0.05, remaining))
    return True


class Capacity:
    def __init__(self, config, project, provider, role):
        self.maximum, self.external = config.get("max_processes", 4), config.get("external_slots", 1)
        self.timeout = config.get("wait_timeout_s", 30)
        self.path = state_root() / "capacity.json"
        self.token = uuid.uuid4().hex
        self.record = {"token": self.token, "project": str(project), "provider": provider, "role": role,
                       "owner_pid": os.getpid(), "child_pid": None, "phase": "admitted",
                       "unit": "managed_outer_cli_process"}
        self.acquired = False
        self.owner_lock = None

    def owner_active(self, token):
        if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{32}", token):
            raise PolicyError("invalid capacity token")
        path = self.path.parent / f"capacity-owner-{token}.lock"
        try:
            lock = path.open("r")
        except FileNotFoundError:
            return False
        with lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return False
            except BlockingIOError:
                return True

    @contextmanager
    def locked(self, allow_budget_mismatch=False):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.with_suffix(".lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if self.path.exists():
                state = read_json(self.path, "capacity ledger")
                if not isinstance(state, dict) or state.get("schema") != 1 or not isinstance(state.get("leases"), dict):
                    raise PolicyError("malformed capacity ledger; inspect it without discarding other sessions' leases")
            else:
                state = {"schema": 1, "max_processes": self.maximum, "external_slots": self.external, "leases": {}}
            if not allow_budget_mismatch and (state.get("max_processes") != self.maximum
                                              or state.get("external_slots") != self.external):
                raise PolicyError("configured projects disagree on the shared capacity budget/external occupancy")
            yield state
            temporary = self.path.with_name(f".capacity-{uuid.uuid4().hex}")
            try:
                with temporary.open("w") as stream:
                    json.dump(state, stream, sort_keys=True)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, self.path)
            finally:
                temporary.unlink(missing_ok=True)

    def diagnostics(self):
        state = read_json(self.path, "capacity ledger") if self.path.exists() else None
        leases = []
        if state is not None:
            if not isinstance(state, dict) or not isinstance(state.get("leases"), dict):
                raise PolicyError("malformed capacity ledger")
            for token, record in state["leases"].items():
                child = record.get("child_pid")
                leases.append({**record, "token": token, "owner_active": self.owner_active(token),
                               "child_group_alive": group_alive(child) if type(child) is int and child > 0 else None})
        return {"path": str(self.path), "configured_budget": {"max_processes": self.maximum,
                "external_slots": self.external}, "registered_budget": None if state is None else {
                "max_processes": state.get("max_processes"), "external_slots": state.get("external_slots")},
                "leases": leases, "recovery": "Dead-owner admitted reservations are reclaimable because spawning was not authorized. "
                "Ownerless spawning reservations stay uncertain; never clear them by age or PID alone. "
                "Independently establish that every child stopped before repairing uncertain state. "
                "Budget reconciliation requires an empty ledger and the observed previous budget."}

    def reconcile(self, expected_maximum, expected_external):
        with self.locked(allow_budget_mismatch=True) as state:
            if (state.get("max_processes"), state.get("external_slots")) != (expected_maximum, expected_external):
                raise PolicyError("capacity budget changed since inspection; inspect again before reconciliation")
            if state["leases"]:
                raise PolicyError("capacity reconciliation requires no active or uncertain leases")
            state.update(max_processes=self.maximum, external_slots=self.external)
        return self.diagnostics()

    def __enter__(self):
        started = time.monotonic()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.owner_path = self.path.parent / f"capacity-owner-{self.token}.lock"
        self.owner_lock = self.owner_path.open("a")
        fcntl.flock(self.owner_lock, fcntl.LOCK_EX)
        try:
            return self.admit(started)
        except BaseException:
            self.owner_lock.close()
            self.owner_path.unlink(missing_ok=True)
            raise

    def admit(self, started):
        while True:
            with self.locked() as state:
                for token, lease in list(state["leases"].items()):
                    if not isinstance(lease, dict) or type(lease.get("owner_pid")) is not int:
                        raise PolicyError("malformed capacity lease; admission refused")
                    owner = self.owner_active(token)
                    child = lease.get("child_pid")
                    if child is not None and (type(child) is not int or child <= 0):
                        raise PolicyError("malformed capacity child PID")
                    phase = lease.get("phase", "spawning")  # old unphased state remains uncertain
                    if phase not in {"admitted", "spawning", "attached", "spawn_failed"}:
                        raise PolicyError("malformed capacity lease phase")
                    no_spawn = phase in {"admitted", "spawn_failed"} and child is None
                    stopped = child is not None and not group_alive(child)
                    # Admission is durable before spawning is authorized. Only that
                    # phase proves a dead owner never created a managed child.
                    if not owner and (no_spawn or stopped):
                        del state["leases"][token]
                        (self.path.parent / f"capacity-owner-{token}.lock").unlink(missing_ok=True)
                if len(state["leases"]) + self.external < self.maximum:
                    self.record["wait_s"] = round(time.monotonic() - started, 4)
                    state["leases"][self.token] = dict(self.record)
                    self.acquired = True
                    return self
            if time.monotonic() - started >= self.timeout:
                raise PolicyError("shared outer-process capacity exhausted; wait for managed processes, "
                                  "or inspect uncertain leases and externally reserved occupancy")
            time.sleep(min(0.05, max(0, self.timeout - (time.monotonic() - started))))

    def before_spawn(self):
        if not self.acquired or self.record.get("phase") != "admitted":
            raise PolicyError("managed spawn requires an admitted lease")
        self.record["phase"] = "spawning"
        with self.locked() as state:
            if self.token not in state["leases"]:
                raise PolicyError("capacity lease disappeared before spawning")
            state["leases"][self.token] = dict(self.record)

    def spawn_failed(self):
        # Popen raised OSError and reaped its failed exec child. Interruptions
        # do not take this path because their child lifetime is uncertain.
        if self.record.get("phase") != "spawning" or self.record.get("child_pid") is not None:
            raise PolicyError("cannot confirm startup failure after a process was attached")
        self.record["phase"] = "spawn_failed"
        with self.locked() as state:
            if self.token not in state["leases"]:
                raise PolicyError("capacity lease disappeared after startup failure")
            state["leases"][self.token] = dict(self.record)

    def attach(self, process):
        self.record.update(child_pid=process.pid, phase="attached")
        with self.locked() as state:
            if self.token not in state["leases"]:
                raise PolicyError("capacity lease disappeared before process attachment")
            state["leases"][self.token] = dict(self.record)

    def __exit__(self, *exception):
        try:
            if self.acquired:
                child = self.record.get("child_pid")
                # Reaping grandchildren may lag the outer process. Never hold the
                # shared ledger lock while waiting, and never infer stopped by age.
                stopped = (self.record.get("phase") in {"admitted", "spawn_failed"} if child is None
                           else wait_for_group(child))
                with self.locked() as state:
                    if stopped:
                        self.record["cleanup_status"] = "stopped"
                        state["leases"].pop(self.token, None)
                        self.acquired = False
                    else:
                        self.record.update(cleanup_status="pending", cleanup_reason=
                            "managed process group shutdown is unconfirmed; capacity lease retained")
                        state["leases"][self.token] = dict(self.record)
        finally:
            if self.owner_lock:
                self.owner_lock.close()
            if not self.acquired:
                self.owner_path.unlink(missing_ok=True)


def policy_context(project):
    return Policy(project).policy_context()
