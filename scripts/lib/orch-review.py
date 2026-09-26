#!/usr/bin/env python3
"""Run one Standard or Full review of the current change and decide its verdict.

`run` starts the built-in reviewers (Claude Code's `/code-review` and `codex review`) in
disposable clones, has a prover rank each finding and write its repro, runs each repro in a
sandbox, runs the refuter on Full, and writes review.json. `wait` reports when a detached run
has finished. `record` appends the agent's disposition of each finding to the outcome log.
The rules (R1 to R21) are in docs/specs/review-design.md.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REFERENCES = ROOT / "skills/requesting-code-review/references"
TEMPLATE_LAWS = ROOT / "skills/cadence/references/laws.md"
SIGNALS = HERE / "orch-signals.sh"

CLAUDE_ALIAS = "opus"
EFFORT = "high"
RANKS = ("mild", "serious", "catastrophic")
KINDS = ("defect", "spec-gap", "scope-creep", "test-tampering", "test-gap", "style")
BLOCKING = {"verified", "unverified", "promoted", "unresolved", "unjudged"}
BUILTIN = {"claude": "code-review", "codex": "codex-review"}
OTHER = {"claude": "codex", "codex": "claude"}
REVIEW_TOOLS = "Read,Grep,Glob,Bash,Agent"
REVIEW_INSTRUCTION = ("The change must implement the spec in {spec}. Read it, and report every place where the "
                      "change does not meet it, as well as any other defect.")
SPEC_IN_COPY = ".git/orch-review/spec.md"
PATCH_IN_COPY = ".git/orch-review/patch.diff"
PROVER_BATCH = 10
PROVER_PARALLEL = 4
REPRO_TIMEOUT = 600
LAUNCH_TIMEOUT = 3600
OUTPUT_LIMIT = 200_000

_spec = importlib.util.spec_from_file_location("orch_task_resources", HERE / "orch-task-resources.py")
resources = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(resources)


class Failure(Exception):
    pass


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def git(cwd, *args, check=True):
    result = subprocess.run(["git", "-C", str(cwd), *args], stdin=subprocess.DEVNULL, capture_output=True,
                            text=True, check=False)
    if check and result.returncode:
        raise Failure(f"git {args[0]} failed: {result.stderr.strip()}")
    return result.stdout if check else result


def nested(path, root):
    return path == root or root in path.parents


def clip(text):
    return text if len(text) <= OUTPUT_LIMIT else text[:OUTPUT_LIMIT] + "\n[output truncated]\n"


def harm_ranking(text):
    """The "Harm ranking" paragraph and its list, up to the next heading or bold paragraph."""
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.startswith("**Harm ranking")), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].startswith("#") or lines[i].startswith("**")), len(lines))
    return "\n".join(lines[start:end]).strip()


def security_pattern():
    match = re.search(r"^ORCH_SIG_SECURITY_DIFF='([^']*)'", SIGNALS.read_text(), re.M)
    if not match:
        raise Failure("ORCH_SIG_SECURITY_DIFF is missing from orch-signals.sh")
    return re.compile(match.group(1), re.I)


def tree_lines(project, tree, name):
    """Lines of one file in the reviewed tree, or None when it is not there."""
    name = name.removeprefix("./") if isinstance(name, str) else ""
    if not name or name.startswith("/") or ".." in Path(name).parts:
        return None
    result = git(project, "cat-file", "blob", f"{tree}:{name}", check=False)
    return result.stdout.splitlines() if result.returncode == 0 else None


def file_line_valid(project, tree, evidence):
    """R9: the quoted line exists in the reviewed files and matches, ignoring outer spaces."""
    if not isinstance(evidence, dict) or evidence.get("type") != "file-line":
        return False, "not file-line evidence"
    line, quote = evidence.get("line"), evidence.get("quote")
    if type(line) is not int or line < 1 or not isinstance(quote, str) or not quote.strip():
        return False, "file-line evidence needs a line number and a quote"
    lines = tree_lines(project, tree, evidence.get("file"))
    if lines is None:
        return False, "the file is not in the reviewed change"
    if line > len(lines) or lines[line - 1].strip() != quote.strip():
        return False, "the quote does not match that line"
    return True, "the quote matches the reviewed line"


def command_variants(command):
    """A command as the launch ran it, plus the inner script of a `<shell> -lc <script>` wrapper."""
    variants = {command.strip()}
    try:
        words = shlex.split(command)
    except ValueError:
        return variants
    if len(words) == 3 and Path(words[0]).name in {"sh", "bash", "zsh"} and words[1] in {"-c", "-lc"}:
        variants.add(words[2].strip())
    return variants


BACKGROUND_ACK = re.compile(r"^Command running in background with ID:", re.M)


def test_run_valid(commands, evidence):
    """R9: the launch's own stream shows exactly that command, and every output line appears in its output."""
    command, output = evidence.get("command"), evidence.get("output")
    if not isinstance(command, str) or not isinstance(output, str):
        return False, "test-run evidence needs a command and its output"
    wanted = [line.rstrip() for line in output.splitlines() if line.strip()]
    if not wanted:
        return False, "test-run evidence has no output line"
    for run in commands:
        if run.get("background") or BACKGROUND_ACK.search(run["output"]):
            continue  # a background launch returns before the command finishes
        if command.strip() in command_variants(run["command"]):
            seen = {line.rstrip() for line in run["output"].splitlines()}
            if all(line in seen for line in wanted):
                return True, "the command and its output are in the prover's session"
    return False, "no command in the prover's session matches the command and output"


def evidence_valid(project, tree, commands, evidence):
    if isinstance(evidence, dict) and evidence.get("type") == "test-run":
        return test_run_valid(commands, evidence)
    return file_line_valid(project, tree, evidence)


def load_config(project):
    path = project / "docs/llm-orchestrator/cadence.json"
    if not path.is_file():
        return {}
    config = read_json(path)
    if not isinstance(config, dict):
        raise Failure("docs/llm-orchestrator/cadence.json is not a JSON object")
    return config


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def review_plan(path, writer, ready):
    """R3: which built-ins review, where the prover and refuter run, and where experiments run."""
    if not ready:
        return None
    if path == "standard":
        providers = [OTHER[writer]] if OTHER[writer] in ready else [writer]
        same = providers[0] == writer
    elif len(ready) == 2:
        providers, same = ["claude", "codex"], False
    else:
        providers, same = [ready[0], ready[0]], True
    twice = len(providers) == 2 and providers[0] == providers[1]
    reviewers = [{"name": f"{BUILTIN[provider]}-{n}" if twice else BUILTIN[provider], "provider": provider,
                  "builtin": BUILTIN[provider]} for n, provider in enumerate(providers, 1)]
    return {"reviewers": reviewers, "same_provider": same,
            "helper": "claude" if "claude" in ready else "codex",
            "experiments": "codex-sandbox" if "codex" in ready else "claude-runner"}


def verdict_line(verdict, path, plan):
    if not plan or not plan.get("same_provider"):
        return verdict
    provider = plan["reviewers"][0]["provider"]
    if path == "full":
        return f"{verdict} (both reviews came from one provider, {provider}: the same provider reviewed twice)"
    return f"{verdict} (the review came from the writer's own provider, {provider}: the same provider)"


class Review:
    def __init__(self, project, run_dir, options):
        self.project = project
        self.run_dir = run_dir
        self.options = options
        self.manager = None
        self.task = None
        self.token = None
        self.tree = None
        self.head = None
        self.sessions = []

    # Step 1
    def preflight(self):
        options, reasons = self.options, []
        providers = {"claude": self.check_claude(), "codex": self.check_codex()}
        for name in ("claude", "codex"):
            if providers[name]["state"] == "not signed in":
                reasons.append(f"preflight: {name} is installed but not signed in; sign in, or take it off PATH")
        ready = [name for name in ("claude", "codex") if providers[name]["ready"]]
        plan = review_plan(options["path"], options["writer"], ready)
        if plan is None:
            reasons.append("preflight: neither claude nor codex is installed and signed in")
        sandbox = providers["codex"]["ready"] and self.sandbox_starts()
        laws = self.project / "docs/llm-orchestrator/LAWS.md"
        ranking, source = None, None
        if laws.is_file():
            ranking, source = harm_ranking(laws.read_text()), "project LAWS.md"
        if not ranking and TEMPLATE_LAWS.is_file():
            ranking, source = harm_ranking(TEMPLATE_LAWS.read_text()), "template laws.md"
        if not ranking:
            reasons.append("preflight: no harm ranking in LAWS.md or the shipped template")
        submodules = self.submodules_dirty()
        if submodules:
            reasons.append(f"preflight: {submodules}")
        spec = Path(options["spec"])
        if not spec.is_file():
            reasons.append("preflight: the spec file does not exist")
        base = git(self.project, "rev-parse", "--verify", "-q", options["base"] + "^{commit}", check=False)
        merge_base = None
        if base.returncode:
            reasons.append("preflight: the base ref does not name a commit")
        else:
            found = git(self.project, "merge-base", base.stdout.strip(), "HEAD", check=False)
            if found.returncode or not found.stdout.strip():
                reasons.append("preflight: the base and HEAD have no merge-base")
            else:
                merge_base = found.stdout.strip()
        try:
            config = load_config(self.project)
        except Failure as error:
            config = {}
            reasons.append(f"preflight: {error}")
        review_config = config.get("review", {}) if isinstance(config.get("review", {}), dict) else {}
        copy_ignored = review_config.get("copy_ignored", [])
        if not isinstance(copy_ignored, list) or not all(
                isinstance(item, str) and item and not item.startswith("/") and ".." not in Path(item).parts
                for item in copy_ignored):
            reasons.append("preflight: review.copy_ignored must list relative paths")
            copy_ignored = []
        setup = review_config.get("setup")
        if setup is not None and not isinstance(setup, str):
            reasons.append("preflight: review.setup must be a string")
            setup = None
        runner = config.get("runner", {}) if isinstance(config.get("runner", {}), dict) else {}
        test_cmd = runner.get("test_cmd") if isinstance(runner.get("test_cmd"), str) else ""
        result = {"ok": not reasons, "reasons": reasons, "providers": providers, "plan": plan, "sandbox": sandbox,
                  "harm_ranking": ranking, "harm_ranking_source": source,
                  "spec": spec.read_text() if spec.is_file() else None, "spec_path": str(spec),
                  "base": base.stdout.strip() if base.returncode == 0 else None, "merge_base": merge_base,
                  "copy_ignored": copy_ignored, "setup": setup, "test_cmd": test_cmd}
        write_json(self.run_dir / "preflight.json", result)
        return result

    @staticmethod
    def check_claude():
        executable = shutil.which("claude")
        if not executable:
            return {"ready": False, "state": "not installed"}
        try:
            status = subprocess.run([executable, "auth", "status", "--json"], stdin=subprocess.DEVNULL,
                                    capture_output=True, text=True, timeout=30)
            signed_in = status.returncode == 0 and json.loads(status.stdout).get("loggedIn") is True
        except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired):
            signed_in = False
        return {"ready": signed_in, "state": "signed in" if signed_in else "not signed in",
                "executable": executable, "requested_model": CLAUDE_ALIAS}

    @staticmethod
    def check_codex():
        executable = shutil.which("codex")
        if not executable:
            return {"ready": False, "state": "not installed"}
        try:
            signed_in = subprocess.run([executable, "login", "status"], stdin=subprocess.DEVNULL,
                                       capture_output=True, timeout=30).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            signed_in = False
        config = codex_home() / "config.toml"
        settings = {}
        try:
            settings = tomllib.loads(config.read_text()) if config.is_file() else {}
        except (OSError, tomllib.TOMLDecodeError):
            pass
        model = settings.get("model")
        servers = settings.get("mcp_servers") if isinstance(settings.get("mcp_servers"), dict) else {}
        return {"ready": signed_in, "state": "signed in" if signed_in else "not signed in",
                "executable": executable, "requested_model": model if isinstance(model, str) else None,
                "mcp_servers": sorted(servers)}

    def sandbox_starts(self):
        probe = self.run_dir / "sandbox-probe"
        probe.mkdir()
        try:
            return subprocess.run(sandboxed(probe, ["true"]), stdin=subprocess.DEVNULL, capture_output=True,
                                  env=reduced_env("sandbox"), timeout=60).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False
        finally:
            shutil.rmtree(probe, ignore_errors=True)

    def submodules_dirty(self):
        result = git(self.project, "submodule", "foreach", "--quiet", "--recursive",
                     "git status --porcelain", check=False)
        if result.returncode:
            return "the submodule check failed"
        return "a submodule has uncommitted changes" if result.stdout.strip() else None

    # Step 2
    def start_state(self, preflight):
        tree = resources.fingerprint(self.project)
        base = preflight["merge_base"]
        numstat = git(self.project, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                      "--numstat", "-z", base, tree)
        files = []
        for record in filter(None, numstat.split("\0")):
            added, deleted, name = record.split("\t", 2)
            count = (int(added) if added.isdigit() else 0) + (int(deleted) if deleted.isdigit() else 0)
            files.append({"file": name, "lines": count})
        diff = git(self.project, "-c", "core.quotePath=false", "diff", "--no-ext-diff", "--no-textconv",
                   "--no-renames", base, tree) if files else ""
        submodules = [entry.split("\t", 1)[1] for entry in git(self.project, "ls-tree", "-r", "-z", tree).split("\0")
                      if entry.startswith("160000 ")]
        state = {"tree": tree, "head": git(self.project, "rev-parse", "HEAD").strip(), "base": base,
                 "submodules": submodules, "files": files, "diff_lines": sum(item["lines"] for item in files),
                 "security": bool(security_pattern().search(diff))}
        (self.run_dir / "change.diff").write_text(diff)
        write_json(self.run_dir / "fingerprint-start.json", state)
        return state, diff

    # Step 3
    def make_copy(self, preflight, directory):
        """A fresh clone at the merge-base holding the reviewed tree as its uncommitted change, with the
        spec in its .git, the copy_ignored paths and setup; returns (path, fingerprint, problem)."""
        created = self.manager.create(self.task["id"], self.token, "clone", tree=self.tree, head=self.head)
        copy = Path(created["path"])
        (copy / SPEC_IN_COPY).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(preflight["spec_path"], copy / SPEC_IN_COPY)
        for name in preflight["copy_ignored"]:
            source = self.project / name
            if not source.exists():
                continue
            (copy / name).parent.mkdir(parents=True, exist_ok=True)
            copy_on_write(source, copy / name)
        if preflight["setup"]:
            try:
                setup = subprocess.run(["sh", "-c", preflight["setup"]], cwd=copy, stdin=subprocess.DEVNULL,
                                       capture_output=True, text=True, timeout=REPRO_TIMEOUT)
                (directory / "setup.log").write_text(clip(setup.stdout + setup.stderr))
                if setup.returncode:
                    return copy, None, f"review.setup exited {setup.returncode}"
            except subprocess.TimeoutExpired:
                return copy, None, "review.setup timed out"
        return copy, resources.fingerprint(copy), None

    def new_launch(self, name, role, provider, preflight, **extra):
        directory = self.run_dir / "launches" / name
        directory.mkdir(parents=True)
        requested = preflight["providers"][provider].get("requested_model")
        record = {"name": name, "role": role, "provider": provider, "status": "dropout",
                  "requested_model": requested, "requested_effort": EFFORT, "served_model": [],
                  "served_effort": [], "started": now(), **extra}
        return directory, record

    def close_launch(self, directory, record):
        record["finished"] = now()
        write_json(directory / "launch.json", record)
        return record

    # Step 4: the reviewers (R3 to R6)
    def reviewer(self, planned, preflight, state):
        directory, record = self.new_launch(planned["name"], "reviewer", planned["provider"], preflight,
                                            builtin=planned["builtin"],
                                            same_provider=preflight["plan"]["same_provider"])
        try:
            copy, fingerprint, problem = self.make_copy(preflight, directory)
            record["copy_fingerprint"] = fingerprint
            instruction = REVIEW_INSTRUCTION.format(spec=copy / SPEC_IN_COPY)
            if state["security"]:
                instruction += "\n\n" + (REFERENCES / "security-lens.md").read_text()
            (directory / "instruction.txt").write_text(instruction)
            if problem or fingerprint != self.tree:
                record["reason"] = problem or "the copy does not match the fingerprint"
            elif planned["provider"] == "claude":
                record.update(run_code_review(copy, instruction, directory, self.run_dir))
                self.sessions.append(dict(record.pop("session_cleanup"), launch=record["name"]))
            else:
                codex = preflight["providers"]["codex"]
                record.update(run_codex_review(copy, instruction, directory, codex.get("requested_model"),
                                               codex.get("mcp_servers", [])))
        except (resources.Unsafe, Failure, OSError) as error:
            record["reason"] = f"the launch could not start: {error}"
        return self.close_launch(directory, record)

    def reviewer_findings(self, launch, prefix):
        """Step 5: the parsed findings of one reviewer, kept even from a dropout (R7, R19)."""
        parsed = read_json(self.run_dir / "launches" / launch["name"] / "findings.json")
        findings = []
        for n, item in enumerate(parsed if isinstance(parsed, list) else [], 1):
            findings.append({
                "id": f"{prefix}-{n}", "reviewer": launch["name"], "builtin": launch["builtin"],
                "provider": launch["provider"], "file": item.get("file"), "line": item.get("line"),
                "words": item.get("words"), "priority": item.get("priority"), "reviewer_finding": item.get("raw"),
                "from_dropout": launch["status"] != "complete", "status": "unjudged", "prover": None,
                "prover_result": None, "prover_rank": None, "rank": None, "kind": None, "mild_reason": None,
                "floors": [], "floor_rank": "mild", "rank_raised": False, "rank_lowered": False,
                "rank_replaced": False, "kind_replaced": False, "evidence_valid": False, "evidence_reason": None,
                "repro": None, "not_runnable": None, "missing_repro": False, "receipts": {}, "reproduced": False})
        return findings

    # Step 6: the prover (R8, R9, R12, R13)
    def prover_prompt(self, preflight, state, diff, batch):
        shown = [{"id": f["id"], "reviewer": f["builtin"], "file": f["file"], "line": f["line"],
                  "priority": f["priority"], "words": f["words"]} for f in batch]
        return "\n".join([
            "Brief: prover", "", (REFERENCES / "prover.md").read_text(),
            "## The specification", "", preflight["spec"], "",
            "## Harm ranking", "", preflight["harm_ranking"], "",
            "## Test command", "",
            preflight["test_cmd"] or "no test command is configured; find and run the project's tests", "",
            "## The change", "",
            "Your working directory is a copy of the repository whose HEAD is the merge-base, so "
            "`git diff HEAD` shows the whole change as uncommitted.", "",
            "<diff>", diff, "</diff>", "",
            "## The findings", "",
            "Finding ids: " + ", ".join(f["id"] for f in batch), "",
            "```json", json.dumps(shown, indent=2, ensure_ascii=False), "```", ""])

    def launch_model(self, name, role, provider, prompt, schema, preflight):
        """A prover or refuter launch: T5's model launch in a fresh copy (R3)."""
        directory, record = self.new_launch(name, role, provider, preflight)
        (directory / "prompt.txt").write_text(prompt)
        try:
            copy, fingerprint, problem = self.make_copy(preflight, directory)
            record["copy_fingerprint"] = fingerprint
            if problem or fingerprint != self.tree:
                record["reason"] = problem or "the copy does not match the fingerprint"
            elif provider == "claude":
                record.update(run_claude(copy, prompt, schema, directory, self.run_dir, role))
            else:
                codex = preflight["providers"]["codex"]
                record.update(run_codex(copy, prompt, schema, directory, codex.get("requested_model"),
                                        codex.get("mcp_servers", []), role))
        except (resources.Unsafe, Failure, OSError) as error:
            record["reason"] = f"the launch could not start: {error}"
        return self.close_launch(directory, record)

    def prove(self, preflight, state, diff, findings):
        batches, groups = [], {}
        for found in findings:
            if not found["from_dropout"]:
                groups.setdefault(found["reviewer"], []).append(found)
        for group in groups.values():
            for start in range(0, len(group), PROVER_BATCH):
                batches.append(group[start:start + PROVER_BATCH])
        names = [f"prover-{n}" for n in range(1, len(batches) + 1)]
        write_json(self.run_dir / "provers.json",
                   [{"name": name, "ids": [f["id"] for f in batch]} for name, batch in zip(names, batches)])
        schema = (REFERENCES / "prover-schema.json").read_text()
        helper = preflight["plan"]["helper"]
        with ThreadPoolExecutor(max_workers=PROVER_PARALLEL) as pool:
            launches = list(pool.map(lambda job: self.launch_model(
                job[0], "prover", helper, self.prover_prompt(preflight, state, diff, job[1]), schema, preflight),
                zip(names, batches)))
        extra = 0
        for launch, batch in zip(launches, batches):
            output = read_json(self.run_dir / "launches" / launch["name"] / "output.json", {})
            commands = read_json(self.run_dir / "launches" / launch["name"] / "commands.json", [])
            results, wanted = {}, {f["id"] for f in batch}
            for item in output.get("results", []) if isinstance(output, dict) else []:
                key = item.get("id") if isinstance(item, dict) else None
                if key in wanted and key not in results:
                    results[key] = item
                else:
                    extra += 1  # the prover cannot add findings (R8)
            for found in batch:
                found["prover"] = launch["name"]
                if launch["status"] == "complete":
                    self.apply_proof(found, results.get(found["id"]), commands)
        return extra

    def apply_proof(self, found, result, commands):
        """R8 step 1, R9, R12: the prover's result, before the experiments."""
        found["prover_result"] = result
        if result is None:
            found["prover_missing"] = True
            return
        rank, kind = result.get("rank"), result.get("kind")
        found["prover_rank"] = rank
        found["rank_replaced"] = rank not in RANKS
        found["kind_replaced"] = kind not in KINDS
        rank = "serious" if found["rank_replaced"] else rank
        kind = "defect" if found["kind_replaced"] else kind
        reason = result.get("mild_reason")
        found["mild_reason"] = reason if isinstance(reason, str) and reason.strip() else None
        confidence = result.get("confidence")
        found["confidence"] = float(confidence) if type(confidence) in (int, float) else None
        found["claim"] = result.get("claim")
        found["kind"] = kind
        found["evidence"] = result.get("evidence")
        found["evidence_valid"], found["evidence_reason"] = evidence_valid(
            self.project, self.tree, commands, result.get("evidence"))
        repro = result.get("repro")
        found["repro"] = (repro if isinstance(repro, dict) and isinstance(repro.get("command"), str)
                          and repro["command"].strip() and isinstance(repro.get("patch"), str) else None)
        not_runnable = result.get("not_runnable")
        found["not_runnable"] = (not_runnable if isinstance(not_runnable, str) and not_runnable.strip()
                                 and not found["repro"] else None)
        # R12: a serious or catastrophic rank the prover gave itself needs a repro or not_runnable.
        found["missing_repro"] = rank != "mild" and not found["repro"] and not found["not_runnable"]
        at_least_serious = kind in ("defect", "spec-gap") or (
            kind == "test-tampering" and not self.options["allow_test_changes"])
        codex_floor = found["builtin"] == "codex-review" and found["priority"] in (0, 1)
        found["floor_rank"] = "serious" if at_least_serious or codex_floor else "mild"
        found["rank"] = rank
        if rank == "mild":  # step 1
            if at_least_serious:
                raise_rank(found, 1, f"a {kind} finding is at least serious")
            elif not found["mild_reason"]:
                raise_rank(found, 1, "a mild rank needs a mild_reason")

    def late_floors(self, found):
        """R8 steps 2 and 3, after the experiments."""
        if found["prover_result"] is None:
            return
        first = found["receipts"].get("1", {})
        failing = bool(first.get("ran") and not first.get("timed_out") and first.get("exit_code") not in (0, None))
        if found["kind"] == "test-gap" and not failing and found["rank"] != "mild":
            found["floors"].append({"step": 2, "from": found["rank"], "to": "mild",
                                    "reason": "a test-gap without a failing receipt 1 claims only missing coverage"})
            found["rank"], found["rank_lowered"] = "mild", True
            found["mild_reason"] = found["mild_reason"] or "a test-gap: no failing command shows a wrong result"
        if found["builtin"] == "codex-review" and found["priority"] in (0, 1) and found["rank"] == "mild":
            raise_rank(found, 3, f"codex review gave it priority {found['priority']}")

    def experiments(self, preflight, findings):
        chosen = [f for f in findings if f["prover_result"] is not None and f["repro"]
                  and (f["rank"] != "mild" or f["floor_rank"] != "mild")]
        runner = preflight["plan"]["experiments"] == "claude-runner"
        with ThreadPoolExecutor(max_workers=PROVER_PARALLEL) as pool:
            list(pool.map(lambda f: (self.run_runner_experiment if runner else self.experiment)(f, preflight),
                          chosen))

    def experiment(self, found, preflight):
        """R10 with Codex: receipt 1, git apply, receipt 2, each under `codex sandbox` in a fresh copy."""
        directory = self.run_dir / "experiments" / found["id"]
        directory.mkdir(parents=True)
        command, patch = found["repro"]["command"], found["repro"]["patch"]
        if not preflight["sandbox"]:
            reason = "not run: the sandbox could not start (codex sandbox is unavailable)"
            found["receipts"] = {"1": {"ran": False, "command": command, "reason": reason},
                                 "2": {"ran": False, "command": command, "reason": reason}}
        else:
            copy, fingerprint, problem = self.make_copy(preflight, directory)
            if problem:
                reason = f"not run: {problem}"
                found["receipts"] = {"1": {"ran": False, "command": command, "reason": reason},
                                     "2": {"ran": False, "command": command, "reason": reason}}
            else:
                first = receipt(copy, ["sh", "-c", command], command, fingerprint)
                applied = receipt(copy, ["git", "apply", "--whitespace=nowarn", "-"], "git apply", None,
                                  stdin=patch)
                if applied["exit_code"] == 0:
                    second = receipt(copy, ["sh", "-c", command], command, resources.fingerprint(copy))
                else:
                    second = {"ran": False, "command": command, "reason": "not run: the patch did not apply"}
                found["receipts"] = {"1": first, "apply": applied, "2": second}
        self.finish_experiment(found, directory)

    def run_runner_experiment(self, found, preflight):
        """R10 with Claude only: a runner launch runs the exact command lines in a fresh copy."""
        directory = self.run_dir / "experiments" / found["id"]
        directory.mkdir(parents=True)
        command, patch = found["repro"]["command"], found["repro"]["patch"]
        lines = [command, f"git apply --whitespace=nowarn {PATCH_IN_COPY}", command]
        launch, receipts = self.runner(f"runner-{found['id']}", lines, preflight, patch)
        found["runner"] = launch["name"]
        first, applied, second = receipts
        if applied.get("ran") and applied.get("exit_code") not in (0, None):
            second = dict(second, ran=False, reason="not run: the patch did not apply")
        found["receipts"] = {"1": first, "apply": dict(applied, command="git apply"), "2": second}
        self.finish_experiment(found, directory)

    def runner(self, name, lines, preflight, patch=None):
        """A Claude runner launch (R10): the probe, then each line as `sh -c '<line>'; echo ORCH-EXIT=$?`."""
        directory, record = self.new_launch(name, "runner", "claude", preflight)
        receipts = [{"ran": False, "command": line, "reason": "not run: the runner did not start"} for line in lines]
        try:
            copy, fingerprint, problem = self.make_copy(preflight, directory)
            record["copy_fingerprint"] = fingerprint
            if problem or fingerprint != self.tree:
                record["reason"] = problem or "the copy does not match the fingerprint"
            else:
                if patch is not None:
                    (copy / PATCH_IN_COPY).write_text(patch)
                fields, receipts = run_runner(copy, lines, directory, self.run_dir, fingerprint)
                record.update(fields)
        except (resources.Unsafe, Failure, OSError) as error:
            record["reason"] = f"the launch could not start: {error}"
        for item in receipts:
            item["runner"] = name
        return self.close_launch(directory, record), receipts

    @staticmethod
    def finish_experiment(found, directory):
        for key, value in found["receipts"].items():
            write_json(directory / f"receipt-{key}.json", value)
        first, second = found["receipts"]["1"], found["receipts"]["2"]
        found["reproduced"] = bool(first.get("ran") and not first.get("timed_out")
                                   and first.get("exit_code") not in (0, None)
                                   and second.get("ran") and not second.get("timed_out")
                                   and second.get("exit_code") == 0)

    # Step 7: the refuter (R14 to R16)
    def refuter_prompt(self, preflight, findings):
        judged = [f for f in findings if f["status"] in ("verified", "unverified")]
        raisable = [f for f in findings if f["status"] == "mild"]
        shown = [{key: f[key] for key in (
            "id", "reviewer", "file", "line", "priority", "words", "prover_result", "rank", "kind", "floors",
            "evidence_valid", "repro", "not_runnable", "reproduced", "receipts", "status")}
            for f in judged + raisable]
        return "\n".join([
            "Brief: refuter", "", (REFERENCES / "refuter.md").read_text(),
            "## The specification", "", preflight["spec"], "",
            "## Harm ranking", "", preflight["harm_ranking"], "",
            "## The findings, with the prover's results and the receipts of each fix experiment", "",
            "Judge these ids: " + ", ".join(f["id"] for f in judged), "",
            "Mild ids you may RAISE: " + (", ".join(f["id"] for f in raisable) or "none"), "",
            "```json", json.dumps(shown, indent=2, ensure_ascii=False), "```", "",
            "Your working directory is a fresh copy of the repository whose HEAD is the merge-base; "
            "`git diff HEAD` shows the change.", ""])

    def refute(self, preflight, findings):
        refuter = self.launch_model("refuter", "refuter", preflight["plan"]["helper"],
                                    self.refuter_prompt(preflight, findings),
                                    (REFERENCES / "refuter-schema.json").read_text(), preflight)
        if refuter["status"] != "complete":
            return
        output = read_json(self.run_dir / "launches/refuter/output.json", {})
        by_id = {f["id"]: f for f in findings}
        checked, seen = [], set()
        for raw in output.get("verdicts", []) if isinstance(output, dict) else []:
            item = raw if isinstance(raw, dict) else {}
            entry = {"raw": raw, "id": item.get("id"), "verdict": item.get("verdict"), "rank": item.get("rank"),
                     "scenario": item.get("scenario"), "drop_check": item.get("drop_check"),
                     "explanation": item.get("explanation"), "drop_receipt": None}
            found = by_id.get(entry["id"])
            if found and entry["id"] not in seen and drop_check_needed(found, entry):
                entry["drop_receipt"] = self.drop_check(found, entry["drop_check"]["command"], preflight)
            seen.add(entry["id"])
            checked.append(entry)
        write_json(self.run_dir / "refuter.json", checked)

    def drop_check(self, found, command, preflight):
        """R15: the script runs the refuter's drop command itself, on a fresh unpatched copy."""
        directory = self.run_dir / "drop-checks" / found["id"]
        directory.mkdir(parents=True)
        if preflight["plan"]["experiments"] == "claude-runner":
            launch, receipts = self.runner(f"drop-{found['id']}", [command], preflight)
            result = receipts[0]
        elif not preflight["sandbox"]:
            result = {"ran": False, "command": command, "reason": "not run: codex sandbox could not start"}
        else:
            copy, fingerprint, problem = self.make_copy(preflight, directory)
            result = ({"ran": False, "command": command, "reason": f"not run: {problem}"} if problem
                      else receipt(copy, ["sh", "-c", command], command, fingerprint))
        write_json(directory / "receipt.json", result)
        return result

    # The whole run
    def execute(self):
        started = time.time()
        errors = []
        try:
            preflight = self.preflight()
            if preflight["ok"]:
                self.run_steps(preflight)
            self.finish_state()
        except Exception as error:  # a failed step never becomes a pass: decide() reads errors.json
            errors.append(f"{type(error).__name__}: {error}")
            write_json(self.run_dir / "errors.json", errors)
        finally:
            self.cleanup()
            review = decide(self.run_dir)
            review["duration_s"] = round(time.time() - started, 1)
            write_json(self.run_dir / "review.json", review)
            append_outcome(outcome_row(self.run_dir, review))
        return review

    def run_steps(self, preflight):
        state, diff = self.start_state(preflight)
        self.tree, self.head = state["tree"], preflight["merge_base"]
        if not state["files"] or state["submodules"]:
            # Copies hold no submodule contents; filling them would need the network or the real
            # module store, so a change with submodules is not reviewed (decide() says why).
            return
        self.manager = resources.Manager()
        self.task = self.manager.start(self.project, f"review {self.run_dir.name}")
        self.token = self.manager.acquire(self.task["id"], "orch-review")["token"]
        planned = preflight["plan"]["reviewers"]
        with ThreadPoolExecutor(max_workers=len(planned)) as pool:
            launches = list(pool.map(lambda item: self.reviewer(item, preflight, state), planned))
        findings = []
        for launch in launches:
            findings += self.reviewer_findings(launch, launch["name"])
        extra = self.prove(preflight, state, diff, findings)
        self.experiments(preflight, findings)
        for found in findings:
            self.late_floors(found)
            found["status"] = initial_status(found)
        write_json(self.run_dir / "findings.json", {"findings": findings, "prover_extra_ids": extra})
        provers = read_json(self.run_dir / "provers.json", [])
        complete = all(launch["status"] == "complete" for launch in launches) and all(
            read_json(self.run_dir / "launches" / batch["name"] / "launch.json", {}).get("status") == "complete"
            for batch in provers)
        if (self.options["path"] == "full" and complete
                and any(f["status"] in ("verified", "unverified") for f in findings)):
            self.refute(preflight, findings)

    def finish_state(self):
        start = read_json(self.run_dir / "fingerprint-start.json")
        if start is None:
            return
        write_json(self.run_dir / "fingerprint-end.json",
                   {"tree": resources.fingerprint(self.project), "submodules": self.submodules_dirty()})

    def cleanup(self):
        record = {"sessions": self.sessions, "task": None}
        if self.task:
            try:
                self.manager.release(self.task["id"], self.token, stopped=True)
                result = self.manager.finish(self.task["id"])
                record["task"] = {"status": result["status"], "kept": result.get("reasons", [])}
            except (resources.Unsafe, OSError) as error:
                record["task"] = {"status": "blocked", "kept": [str(error)]}
        write_json(self.run_dir / "cleanup.json", record)


def raise_rank(found, step, reason):
    found["floors"].append({"step": step, "from": found["rank"], "to": "serious", "reason": reason})
    found["rank"], found["rank_raised"] = "serious", True


def initial_status(found):
    """R11 and R18 before the refuter."""
    if found["from_dropout"] or found["prover_result"] is None:
        return "unjudged"
    if found["rank"] == "mild":
        return "mild"
    if found["evidence_valid"] and (found["reproduced"] or found["not_runnable"]):
        return "verified"
    return "unverified"


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


def claude_config_dir():
    return Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")


def copy_on_write(source, target):
    flags = ["-cR"] if sys.platform == "darwin" else ["-R", "--reflink=auto"]
    if subprocess.run(["cp", *flags, str(source), str(target)], capture_output=True).returncode:
        shutil.rmtree(target, ignore_errors=True) if target.is_dir() else target.unlink(missing_ok=True)
        subprocess.run(["cp", "-R", str(source), str(target)], check=True, capture_output=True)


def sandboxed(copy, argv):
    return ["codex", "sandbox", "-P", ":workspace", "-C", str(copy), "--", *argv]


BASE_ENV = ("PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ",
            "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME")
PROVIDER_ENV = {
    "claude": ("CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
               "CLAUDE_CODE_OAUTH_TOKEN"),
    "codex": ("CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"),
    # `codex sandbox` reads its permission profiles from the config stack under $CODEX_HOME;
    # it reaches no model, so it gets no key.
    "sandbox": ("CODEX_HOME",),
}


def reduced_env(provider=None, **extra):
    """The environment for a launch or an experiment: the basics, plus only the variables the
    provider's CLI uses to reach its model. Cloud credentials and tokens (AWS_*, GITHUB_TOKEN and
    the like) are left out, so a launch cannot use the person's other accounts."""
    keep = BASE_ENV + PROVIDER_ENV.get(provider, ())
    return {**{key: os.environ[key] for key in keep if key in os.environ}, **extra}


def kill_group(process):
    """Stop the process and every child it started (they share its session and process group)."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    process.wait()


def receipt(copy, argv, command, fingerprint, stdin=None):
    started = time.monotonic()
    record = {"ran": True, "command": command, "argv": sandboxed(copy, argv), "fingerprint": fingerprint,
              "timed_out": False, "via": "codex-sandbox"}
    # Output goes to an unnamed file, not a pipe, so a child left in the background cannot hold
    # the receipt open. The whole process group is killed when the command ends or times out.
    with tempfile.TemporaryFile() as output:
        try:
            # Python checks a cached .pyc by source mtime in whole seconds and size, so a patch applied
            # within a second of receipt 1 could run the unpatched code; no bytecode is written instead.
            process = subprocess.Popen(record["argv"], cwd=copy, stdin=subprocess.PIPE, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True,
                                       env=reduced_env("sandbox", PYTHONDONTWRITEBYTECODE="1"))
        except OSError as error:
            record.update(ran=False, exit_code=None, output="", reason=f"could not start: {error}")
        else:
            try:
                process.communicate((stdin or "").encode(), timeout=REPRO_TIMEOUT)
                record["exit_code"] = process.returncode
            except subprocess.TimeoutExpired:
                record.update(exit_code=None, timed_out=True, reason=f"ran longer than {REPRO_TIMEOUT} seconds")
            finally:
                kill_group(process)
            output.seek(0)
            record["output"] = clip(output.read().decode(errors="replace"))
    record["duration_s"] = round(time.monotonic() - started, 2)
    return record


def run_process(argv, cwd, prompt, stream_path, launch_dir, env):
    """Run one launch; the prompt goes on stdin, or stdin is closed when there is none."""
    with open(stream_path, "wb") as stream, open(launch_dir / "stderr.log", "wb") as errors:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL if prompt is None else subprocess.PIPE,
                                   stdout=stream, stderr=errors, start_new_session=True, env=env)
        try:
            process.communicate(None if prompt is None else prompt.encode(), timeout=LAUNCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            kill_group(process)
            return None
        kill_group(process)
    return process.returncode


def stream_events(path):
    events = []
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return events
    for line in text.splitlines():
        if line.strip():
            try:
                event = json.loads(line)
            except ValueError:
                continue  # a stray log line; the checks below use only JSON events
            if isinstance(event, dict):
                events.append(event)
    return events


def claude_family(served):
    return bool(re.fullmatch(rf"claude-{CLAUDE_ALIAS}(?:-[a-zA-Z0-9.]+)+(?:\[[a-z0-9]+\])?", served))


CREDENTIAL_DIRS = ("~/.aws", "~/.ssh", "~/.gnupg", "~/.config/gh", "~/.config/gcloud", "~/.azure", "~/.kube",
                   "~/.docker", "~/.netrc", "~/.codex", "~/.claude")


def claude_sandbox(copy, run_dir):
    """Claude Code's Bash sandbox for a launch: writes only in its copy, no network, no reading the
    run directory or credential folders, and no fallback to running a command outside the sandbox."""
    return json.dumps({"sandbox": {
        "enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False,
        "autoAllowBashIfSandboxed": True, "excludedCommands": [],
        "filesystem": {"allowWrite": [str(copy)], "denyRead": [str(run_dir), *CREDENTIAL_DIRS]},
        "network": {"allowedDomains": [], "strictAllowlist": True}}})


def sandbox_probe(launch_dir):
    """A command whose result shows whether the launch's Bash runs in the sandbox: it tries to write
    outside the copy, which the sandbox refuses."""
    target = launch_dir / "sandbox-probe"
    return target, (f"touch {shlex.quote(str(target))} 2>&1 && echo ORCH-SANDBOX-OFF || echo ORCH-SANDBOX-ON")


def bash_calls(events):
    """The Bash calls in a Claude stream or transcript, in order, each with its result."""
    uses, calls = {}, []
    for event in events:
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        content = message.get("content") if isinstance(message.get("content"), list) else []
        for block in content:
            if not isinstance(block, dict):
                continue
            if event.get("type") == "assistant" and block.get("type") == "tool_use" and block.get("name") == "Bash":
                request = block.get("input") if isinstance(block.get("input"), dict) else {}
                call = {"command": request.get("command"), "output": None, "failed": None,
                        "background": request.get("run_in_background") is True,
                        "unsandboxed": request.get("dangerouslyDisableSandbox") is True}
                uses[block.get("id")] = call
                calls.append(call)
            if event.get("type") == "user" and block.get("type") == "tool_result" and block.get("tool_use_id") in uses:
                text = block.get("content")
                if isinstance(text, list):
                    text = "\n".join(part.get("text", "") for part in text if isinstance(part, dict))
                call = uses[block["tool_use_id"]]
                call["output"] = text if isinstance(text, str) else None
                call["failed"] = block.get("is_error") is True
    return calls


def probe_passed(calls, probe, target):
    """The first Bash call is the probe, answered ON with no OFF, and the probe file is absent."""
    first = calls[0] if calls else {}
    output = first.get("output") if isinstance(first.get("output"), str) else ""
    return (isinstance(first.get("command"), str) and first["command"].strip() == probe
            and "ORCH-SANDBOX-ON" in output and "ORCH-SANDBOX-OFF" not in output and not target.exists())


def finish_launch(fields, output, launch_dir):
    """Keep whatever answer the launch gave, even from a dropout (R19); complete only without a reason."""
    if isinstance(output, dict):
        write_json(launch_dir / "output.json", output)
    if not fields.get("reason"):
        fields["reason"] = None
        fields["status"] = "complete"
    return fields


def first_reason(*reasons):
    return next((reason for reason in reasons if reason), None)


def claude_result(events):
    """The init event, the final result event, and the served models from modelUsage."""
    init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), None)
    results = [e for e in events if e.get("type") == "result"]
    result = results[-1] if results else None
    usage = result.get("modelUsage") if result and isinstance(result.get("modelUsage"), dict) else {}
    return init, result, sorted(usage)


def claude_checks(code, init, result, served, calls):
    """R5 and R7 checks shared by every Claude launch."""
    if code is None:
        return f"timed out after {LAUNCH_TIMEOUT} seconds"
    if code != 0:
        return f"exits nonzero ({code})"
    if init is None:
        return "the stream has no system init event, so its MCP servers are unknown"
    if init.get("mcp_servers"):
        return "loaded MCP servers"
    if not result or result.get("is_error") is not False or result.get("subtype") != "success":
        return "no final result"
    if not served:
        return "no served model in the result's modelUsage"
    others = [model for model in served if not claude_family(model)]
    if others:
        return "a model outside the opus family served it: " + ", ".join(others)
    if any(call["unsandboxed"] for call in calls):
        return "a Bash call asked to run outside the sandbox"
    return None


def run_claude(copy, prompt, schema, launch_dir, run_dir, role):
    """The prover or refuter on Claude (T5's launch). Returns the launch fields."""
    target, probe = sandbox_probe(launch_dir)
    prompt = f"Sandbox check: run exactly this command first: {probe}\n\n{prompt}"
    argv = ["claude", "-p", "--settings", claude_sandbox(copy, run_dir),
            "--output-format", "stream-json", "--verbose", "--model", CLAUDE_ALIAS,
            "--effort", EFFORT, "--json-schema", schema, "--safe-mode", "--restricted",
            "--tools", "Read,Grep,Glob,Bash", "--allowedTools", "Read,Grep,Glob,Bash",
            "--permission-mode", "dontAsk", "--permission-prompts", "none", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--no-session-persistence"]
    stream = launch_dir / "stream.jsonl"
    code = run_process(argv, copy, prompt, stream, launch_dir, reduced_env("claude"))
    events = stream_events(stream)
    init, result, served = claude_result(events)
    calls = bash_calls(events)
    commands = [call for call in calls if isinstance(call["command"], str) and isinstance(call["output"], str)]
    write_json(launch_dir / "commands.json", commands)
    output = None
    if result and result.get("subtype") == "success" and result.get("is_error") is False:
        output = result.get("structured_output")
        if output is None and isinstance(result.get("result"), str):
            output = parse_json_text(result["result"])
    fields = {"served_model": served, "served_effort": [], "exit_code": code,
              "cost_usd": result.get("total_cost_usd") if result else None,
              "sandbox_check": calls[0]["output"] if calls else None}
    fields["reason"] = first_reason(
        claude_checks(code, init, result, served, calls),
        None if answer_shape_valid(output, role) else "no final result",
        None if probe_passed(calls, probe, target) else "the sandbox check did not show a refused write outside the copy")
    return finish_launch(fields, output, launch_dir)


def runner_line(line):
    return "sh -c '" + line.replace("'", "'\"'\"'") + "'; echo ORCH-EXIT=$?"


EXIT_MARKER = re.compile(r"^ORCH-EXIT=(\d+)\s*$")


def run_runner(copy, lines, launch_dir, run_dir, fingerprint):
    """R10's Claude runner: returns the launch fields and one receipt per line, in order."""
    target, probe = sandbox_probe(launch_dir)
    wrapped = [runner_line(line) for line in lines]
    prompt = ("Run these commands with your Bash tool, one call each, in this order, exactly as written, "
              "and nothing else. Give each call a timeout of 600000 milliseconds. Then reply DONE.\n"
              + "".join(f"{n}. {command}\n" for n, command in enumerate([probe, *wrapped], 1)))
    argv = ["claude", "-p", "--settings", claude_sandbox(copy, run_dir), "--output-format", "stream-json",
            "--verbose", "--model", CLAUDE_ALIAS, "--effort", EFFORT, "--safe-mode", "--restricted",
            "--tools", "Bash", "--allowedTools", "Bash", "--permission-mode", "dontAsk",
            "--permission-prompts", "none", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
            "--no-session-persistence"]
    (launch_dir / "prompt.txt").write_text(prompt)
    stream = launch_dir / "stream.jsonl"
    code = run_process(argv, copy, prompt, stream, launch_dir, reduced_env("claude", PYTHONDONTWRITEBYTECODE="1"))
    events = stream_events(stream)
    init, result, served = claude_result(events)
    calls = bash_calls(events)
    write_json(launch_dir / "commands.json", calls)
    receipts = []
    for n, (line, command) in enumerate(zip(lines, wrapped), 1):
        call = calls[n] if n < len(calls) else {}
        item = {"ran": False, "command": line, "call": command, "fingerprint": fingerprint if n == 1 else None,
                "timed_out": False, "via": "claude-runner"}
        text = call.get("output") if isinstance(call.get("output"), str) else None
        tail = text.rstrip("\n").splitlines()[-1:] if text else []
        marker = EXIT_MARKER.match(tail[0]) if tail else None
        if call.get("command") != command:
            item["reason"] = "the runner's call is not the given line, or not in its place"
        elif not marker:
            item["reason"] = "the runner's result has no ORCH-EXIT marker"
        else:
            body = text.rstrip("\n").splitlines()[:-1]
            item.update(ran=True, exit_code=int(marker.group(1)), output=clip("\n".join(body)))
        receipts.append(item)
    fields = {"served_model": served, "served_effort": [], "exit_code": code,
              "cost_usd": result.get("total_cost_usd") if result else None,
              "sandbox_check": calls[0]["output"] if calls else None}
    fields["reason"] = first_reason(
        claude_checks(code, init, result, served, calls),
        None if probe_passed(calls, probe, target) else "the sandbox check did not show a refused write outside the copy",
        None if len(calls) <= len(lines) + 1 else "the runner ran a command it was not given")
    return finish_launch(fields, None, launch_dir), receipts


def session_folder(session):
    """R5: the one folder under projects/ that holds an entry named exactly <session>."""
    projects = claude_config_dir() / "projects"
    try:
        folders = [path for path in projects.iterdir() if path.is_dir() and not path.is_symlink()]
    except OSError as error:
        return None, f"cannot list {projects}: {error}"
    matches = [folder for folder in folders if os.path.lexists(folder / session)]
    if len(matches) != 1:
        return None, f"{len(matches)} project folders hold session {session}, not 1"
    return matches[0], None


def claude_temp_parents(folder_name):
    roots = {os.path.realpath(root) for root in (os.environ.get("TMPDIR"), "/tmp") if root}
    return [Path(root) / f"claude-{os.getuid()}" / folder_name for root in sorted(roots)]


def delete_session(session):
    """R5: remove only the files of the kept session, by its exact id, and report any failure."""
    record = {"session_id": session, "status": "deleted", "removed": [], "problems": []}
    folder, problem = session_folder(session)
    if problem:
        record.update(status="failed", problems=[problem])
        return record
    temp_parents = claude_temp_parents(folder.name)
    for target in [folder / f"{session}.jsonl", folder / session, *[parent / session for parent in temp_parents]]:
        if not os.path.lexists(target):
            continue
        try:
            if target.is_symlink() or not target.is_dir():
                target.unlink()
            else:
                shutil.rmtree(target)
            record["removed"].append(str(target))
        except OSError as error:
            record["problems"].append(f"{target}: {error}")
    for parent in [folder, *temp_parents]:
        try:
            if parent.is_dir() and not parent.is_symlink() and not any(parent.iterdir()):
                parent.rmdir()
        except OSError:
            pass
    if record["problems"]:
        record["status"] = "failed"
    return record


def sandbox_attached(events, run_dir, copy):
    """R5: a sandbox_instructions attachment lists the run directory under read deny and the copy
    under write allow."""
    def holds(paths, wanted):
        wanted = os.path.realpath(wanted)
        return isinstance(paths, list) and any(isinstance(p, str) and os.path.realpath(os.path.expanduser(p))
                                               == wanted for p in paths)
    for event in events:
        attachment = event.get("attachment")
        if not isinstance(attachment, dict) or attachment.get("type") != "sandbox_instructions":
            continue
        content = attachment.get("content") if isinstance(attachment.get("content"), str) else ""
        for line in content.splitlines():
            if not line.startswith("Filesystem: "):
                continue
            try:
                config = json.loads(line[len("Filesystem: "):])
            except ValueError:
                continue
            read = config.get("read") if isinstance(config, dict) and isinstance(config.get("read"), dict) else {}
            write = config.get("write") if isinstance(config, dict) and isinstance(config.get("write"), dict) else {}
            if holds(read.get("denyOnly"), run_dir) and holds(write.get("allowOnly"), copy):
                return True
    return False


FENCE = re.compile(r"```[^\n`]*\n(.*?)```", re.S)


def code_review_findings(text):
    """R7: the findings of a /code-review reply, or (None, why) when it is not positively parsed."""
    if not isinstance(text, str):
        return None, "the reply has no text"
    arrays = []
    for block in FENCE.finditer(text):
        try:
            value = json.loads(block.group(1).strip())
        except ValueError:
            continue
        if isinstance(value, list):
            arrays.append(value)
    if not arrays:
        return None, "the reply has no fenced JSON array of findings"
    if not all(isinstance(item, dict) and isinstance(item.get("file"), str) for value in arrays for item in value):
        return None, "a fenced JSON array is not a list of findings that each name a file"
    findings = []
    for item in (item for value in arrays for item in value):
        line = item.get("line")
        words = [str(item[key]) for key in ("summary", "failure_scenario") if isinstance(item.get(key), str)
                 and item[key].strip()]
        findings.append({"file": item["file"], "line": line if type(line) is int else None,
                         "summary": item.get("summary"), "failure_scenario": item.get("failure_scenario"),
                         "priority": None, "words": "\n".join(words), "raw": item})
    return findings, None


CODEX_REVIEW_KEYS = ("findings", "overall_correctness", "overall_explanation", "overall_confidence_score")
PRIORITY_LINE = re.compile(r"^\s*- \[P\d+\]", re.M)


def relative_to(path, root):
    real, base = os.path.realpath(path), os.path.realpath(root)
    return os.path.relpath(real, base) if real.startswith(base + os.sep) else path


def codex_review_findings(message, stdout, root):
    """R7: the findings of a `codex review` final message, or (None, why) when it is not positively parsed."""
    if not isinstance(message, str):
        return None, "the review rollout has no final message"
    try:
        reply = json.loads(message.strip())
    except ValueError:
        return None, "the final message is not the review JSON object"
    if not isinstance(reply, dict) or any(key not in reply for key in CODEX_REVIEW_KEYS):
        return None, "the final message lacks " + ", ".join(k for k in CODEX_REVIEW_KEYS if not (
            isinstance(reply, dict) and k in reply))
    items, correctness = reply["findings"], reply["overall_correctness"]
    if not isinstance(items, list):
        return None, "findings is not a list"
    if correctness not in ("patch is correct", "patch is incorrect"):
        return None, f"overall_correctness is {correctness!r}"
    if not items and correctness != "patch is correct":
        return None, "no findings, but the patch is called incorrect"
    if items and correctness != "patch is incorrect":
        return None, "findings, but the patch is called correct"
    findings = []
    for item in items:
        location = item.get("code_location") if isinstance(item, dict) else None
        lines = location.get("line_range") if isinstance(location, dict) else None
        if not (isinstance(item, dict) and isinstance(item.get("title"), str) and isinstance(item.get("body"), str)
                and isinstance(location, dict) and isinstance(location.get("absolute_file_path"), str)
                and isinstance(lines, dict) and type(lines.get("start")) is int):
            return None, "a finding lacks a title, body or code location"
        priority = item.get("priority")
        if type(priority) is not int:
            match = re.match(r"\[P(\d+)\]", item["title"])
            priority = int(match.group(1)) if match else None
        findings.append({"file": relative_to(location["absolute_file_path"], root), "line": lines["start"],
                         "title": item["title"], "body": item["body"], "priority": priority,
                         "confidence_score": item.get("confidence_score"),
                         "words": f"{item['title']}\n{item['body']}", "raw": item})
    if stdout is not None and len(PRIORITY_LINE.findall(stdout)) != len(findings):
        return None, (f"stdout lists {len(PRIORITY_LINE.findall(stdout))} [P<n>] lines, "
                      f"the final message {len(findings)} findings")
    return findings, None


def review_rollout(stderr, home):
    """R6: the one rollout, among the conversations the stderr log names, whose source is the review."""
    ids = list(dict.fromkeys(re.findall(r"conversation\.id=([0-9A-Za-z-]+)", stderr or "")))
    reviews, helpers = [], []
    for conversation in ids:
        for path in sorted((Path(home) / "sessions").glob(f"**/rollout-*-{conversation}.jsonl")):
            events = stream_events(path)
            meta = next((e.get("payload") for e in events if e.get("type") == "session_meta"), None)
            if isinstance(meta, dict) and meta.get("source") == {"subagent": "review"}:
                reviews.append((path, events))
            else:
                helpers += [e["payload"]["model"] for e in events if e.get("type") == "turn_context"
                            and isinstance(e.get("payload"), dict) and isinstance(e["payload"].get("model"), str)]
    if len(reviews) != 1:
        return None, None, sorted(set(helpers)), f"{len(reviews)} review rollouts among the logged conversations, not 1"
    return reviews[0][0], reviews[0][1], sorted(set(helpers)), None


def rollout_message(events):
    completes = [e["payload"] for e in events if e.get("type") == "event_msg" and isinstance(e.get("payload"), dict)
                 and e["payload"].get("type") == "task_complete"]
    return completes[-1].get("last_agent_message") if completes else None


def codex_log_mcp(stderr):
    """R6: MCP use in the codex log: a tool result from an MCP tool, or a start line naming a server."""
    for line in (stderr or "").splitlines():
        if 'event.name="codex.tool_result"' in line and "mcp_tool=true" in line:
            return "an MCP tool ran (codex.tool_result has mcp_tool=true)"
        if 'event.name="codex.conversation_starts"' in line:
            # The log_only line names the servers; the trace_safe line gives only their count.
            names = re.search(r'mcp_servers="([^"]*)"', line)
            count = re.search(r"mcp_server_count=(\d+)", line)
            if (names and names.group(1).strip()) or (count and count.group(1) != "0") or not (names or count):
                return "an MCP server started (a codex.conversation_starts line names or counts one)"
    return None


def run_code_review(copy, instruction, launch_dir, run_dir):
    """R5: Claude Code's /code-review, proved from its stream and its kept subagent transcript."""
    target, probe = sandbox_probe(launch_dir)
    session = str(uuid.uuid4())
    text = (f"/code-review {EFFORT} Sandbox check: before anything else, run exactly this command with your "
            f"Bash tool: {probe}\n\n{instruction}")
    argv = ["claude", "-p", text, "--model", CLAUDE_ALIAS, "--effort", EFFORT, "--safe-mode", "--restricted",
            "--tools", REVIEW_TOOLS, "--allowedTools", REVIEW_TOOLS, "--permission-mode", "dontAsk",
            "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config",
            '{"mcpServers":{}}', "--session-id", session, "--settings", claude_sandbox(copy, run_dir)]
    stream = launch_dir / "stream.jsonl"
    code = run_process(argv, copy, None, stream, launch_dir, reduced_env("claude"))
    events = stream_events(stream)
    init, result, served = claude_result(events)
    task = next((e.get("task_id") for e in events if e.get("type") == "system"
                 and e.get("subtype") == "task_started" and e.get("description") == "/code-review"), None)
    transcript, calls, all_calls, missing = [], [], [], None
    folder, problem = session_folder(session)
    if problem:
        missing = f"no /code-review transcript: {problem}"
    elif not (isinstance(task, str) and re.fullmatch(r"[A-Za-z0-9_-]+", task)):
        missing = "no /code-review transcript: the stream names no /code-review task"
    else:
        path = folder / session / "subagents" / f"agent-{task}.jsonl"
        if not path.is_file():
            missing = "no /code-review transcript at " + str(path)
        else:
            transcript = stream_events(path)
            shutil.copyfile(path, launch_dir / "transcript.jsonl")
            calls = bash_calls(transcript)
            for other in [folder / f"{session}.jsonl", *sorted((folder / session).glob("subagents/agent-*.jsonl"))]:
                all_calls += bash_calls(stream_events(other))
    write_json(launch_dir / "commands.json", calls)
    reply = result.get("result") if result else None
    findings, parse_problem = code_review_findings(reply)
    if findings is not None:
        write_json(launch_dir / "findings.json", findings)
    fields = {"served_model": served, "served_effort": [], "exit_code": code, "session_id": session,
              "cost_usd": result.get("total_cost_usd") if result else None,
              "sandbox_check": calls[0]["output"] if calls else None,
              "permission_denials": result.get("permission_denials") if result else None}
    fields["reason"] = first_reason(
        claude_checks(code, init, result, served, all_calls),
        missing,
        None if sandbox_attached(transcript, run_dir, copy) else
        "the transcript's sandbox_instructions do not deny reading the run directory and allow writing the copy",
        None if probe_passed(calls, probe, target) else "the sandbox check did not show a refused write outside the copy",
        f"the reply is not parsed: {parse_problem}" if parse_problem else None)
    fields["session_cleanup"] = delete_session(session)
    return finish_launch(fields, None, launch_dir)


def run_codex_review(copy, instruction, launch_dir, requested, servers):
    """R6: `codex review`, proved from its stderr log and the review's rollout."""
    argv = ["codex", "review", "--uncommitted", "-c", f'model_reasoning_effort="{EFFORT}"',
            "-c", 'sandbox_mode="read-only"', "-c", "developer_instructions=" + json.dumps(instruction),
            *codex_mcp_off(servers)]
    stdout_path = launch_dir / "stdout.txt"
    code = run_process(argv, copy, None, stdout_path, launch_dir,
                       reduced_env("codex", RUST_LOG="warn,codex_otel=info"))
    stdout = stdout_path.read_text(errors="replace")
    stderr = (launch_dir / "stderr.log").read_text(errors="replace")
    path, events, helpers, missing = review_rollout(stderr, codex_home())
    contexts = [e["payload"] for e in events or [] if e.get("type") == "turn_context" and isinstance(e.get("payload"), dict)]
    served = list(dict.fromkeys(c.get("model") for c in contexts if isinstance(c.get("model"), str)))
    efforts = list(dict.fromkeys(c.get("effort") for c in contexts if isinstance(c.get("effort"), str)))
    sandboxes = []
    for context in contexts:
        policy = context.get("sandbox_policy")
        policy = policy.get("type") if isinstance(policy, dict) else policy
        if isinstance(policy, str) and policy not in sandboxes:
            sandboxes.append(policy)
    developer = any(
        e.get("type") == "response_item" and isinstance(e.get("payload"), dict)
        and e["payload"].get("type") == "message" and e["payload"].get("role") == "developer"
        and any(isinstance(part, dict) and isinstance(part.get("text"), str) and instruction in part["text"]
                for part in e["payload"].get("content") or [])
        for e in events or [])
    findings, problem = (codex_review_findings(rollout_message(events), stdout, copy) if events is not None
                         else (None, None))
    if findings is not None:
        write_json(launch_dir / "findings.json", findings)
    if path:
        shutil.copyfile(path, launch_dir / "rollout.jsonl")
    fields = {"served_model": served, "served_effort": efforts, "served_sandbox": sandboxes, "exit_code": code,
              "helper_models": helpers, "rollout": str(path) if path else None,
              "model_compared": requested is not None}
    mismatched = [model for model in served if requested is not None and model != requested]
    fields["reason"] = first_reason(
        f"timed out after {LAUNCH_TIMEOUT} seconds" if code is None else None,
        f"exits nonzero ({code})" if code not in (None, 0) else None,
        missing,
        codex_log_mcp(stderr),
        "the review rollout has no turn_context" if not contexts else None,
        "no served model" if contexts and not served else None,
        "the served model differs from config.toml's: " + ", ".join(mismatched) if mismatched else None,
        f"the served effort is {', '.join(efforts) or 'missing'}, not {EFFORT}" if efforts != [EFFORT] else None,
        f"the served sandbox is {', '.join(sandboxes) or 'missing'}, not read-only" if sandboxes != ["read-only"] else None,
        None if developer else "no developer message carries the instruction",
        f"the reply is not parsed: {problem}" if problem else None)
    return finish_launch(fields, None, launch_dir)


def codex_mcp_off(servers):
    """Arguments that turn off each MCP server named in config.toml, and the apps and plugins features."""
    argv = []
    for name in servers:
        key = name if re.fullmatch(r"[A-Za-z0-9_-]+", name) else json.dumps(name)
        argv += ["-c", f"mcp_servers.{key}.enabled=false"]
    return argv + ["--disable", "apps", "--disable", "plugins"]


def codex_mcp_servers(path):
    """The MCP servers codex started, from its codex.conversation_starts log line, or None when absent."""
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return None
    for line in text.splitlines():
        if 'event.name="codex.conversation_starts"' in line:
            match = re.search(r'mcp_servers="([^"]*)"', line)
            if match:
                return [name.strip() for name in match.group(1).split(",") if name.strip()]
    return None


def run_codex(copy, prompt, schema, launch_dir, requested, servers, role):
    """The prover or refuter on Codex (T5's `codex exec` launch). Served model and effort come from
    the session rollout named by the thread id."""
    schema_path = launch_dir / "schema.json"
    schema_path.write_text(schema)
    result_path = launch_dir / "last-message.json"
    argv = ["codex", "exec", "--json", "-s", "workspace-write", "-C", str(copy),
            "-c", f'model_reasoning_effort="{EFFORT}"', *codex_mcp_off(servers),
            "--output-schema", str(schema_path), "-o", str(result_path), "-"]
    stream = launch_dir / "stream.jsonl"
    # At codex_otel=info, codex logs the MCP servers it started.
    code = run_process(argv, copy, prompt, stream, launch_dir,
                       reduced_env("codex", RUST_LOG="warn,codex_otel=info"))
    thread, commands, usage = None, [], {}
    for event in stream_events(stream):
        if event.get("type") == "thread.started":
            thread = event.get("thread_id")
        item = event.get("item") if isinstance(event.get("item"), dict) else {}
        if (event.get("type") == "item.completed" and item.get("type") == "command_execution"
                and isinstance(item.get("command"), str) and item.get("exit_code") is not None):
            commands.append({"command": item["command"], "output": item.get("aggregated_output") or "",
                             "failed": item.get("exit_code") != 0})
        if event.get("type") == "turn.completed" and isinstance(event.get("usage"), dict):
            for key, value in event["usage"].items():
                if isinstance(value, int):
                    usage[key] = usage.get(key, 0) + value
    write_json(launch_dir / "commands.json", commands)
    served, efforts = rollout_models(thread)
    output = parse_json_text(result_path.read_text()) if result_path.is_file() else None
    mismatched = [model for model in served if requested is not None and model != requested]
    mcp = codex_mcp_servers(launch_dir / "stderr.log")
    fields = {"served_model": served, "served_effort": efforts, "exit_code": code, "tokens": usage,
              "thread_id": thread, "model_compared": requested is not None, "mcp_servers": mcp}
    fields["reason"] = first_reason(
        f"timed out after {LAUNCH_TIMEOUT} seconds" if code is None else None,
        f"exits nonzero ({code})" if code not in (None, 0) else None,
        "loaded MCP servers" if mcp else None,
        None if answer_shape_valid(output, role) else "no final result",
        "no served model" if not served else None,
        "the served model differs from the requested one: " + ", ".join(mismatched) if mismatched else None,
        "no MCP server list in the codex log, so an MCP server may have loaded" if mcp is None else None)
    return finish_launch(fields, output, launch_dir)


def rollout_models(thread):
    if not isinstance(thread, str) or not re.fullmatch(r"[0-9a-fA-F-]+", thread):
        return [], []
    models, efforts = [], []
    for path in (codex_home() / "sessions").glob(f"**/rollout-*-{thread}.jsonl"):
        for event in stream_events(path):
            payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
            if event.get("type") == "turn_context":
                if isinstance(payload.get("model"), str) and payload["model"] not in models:
                    models.append(payload["model"])
                if isinstance(payload.get("effort"), str) and payload["effort"] not in efforts:
                    efforts.append(payload["effort"])
    return models, efforts


def parse_json_text(text):
    text = text.strip()
    fenced = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, re.S)
    try:
        return json.loads(fenced.group(1) if fenced else text)
    except ValueError:
        return None


def answer_shape_valid(output, role):
    if not isinstance(output, dict):
        return False
    return isinstance(output.get("verdicts" if role == "refuter" else "results"), list)


def lower_than(rank, other):
    return RANKS.index(rank) < RANKS.index(other)


def drop_check_valid_shape(check):
    return (isinstance(check, dict) and isinstance(check.get("command"), str) and check["command"].strip()
            and isinstance(check.get("expected_output"), str)
            and any(line.strip() for line in check["expected_output"].splitlines()))


def drop_check_needed(found, verdict):
    """R15, R16: a drop check runs only for a verdict that could drop or lower a finding."""
    if found["status"] not in ("verified", "unverified") or found["reproduced"] or found["not_runnable"]:
        return False
    if not drop_check_valid_shape(verdict["drop_check"]):
        return False
    lowering = verdict["rank"] in RANKS and lower_than(verdict["rank"], found["rank"])
    return verdict["verdict"] == "DROPPED" or lowering


def drop_proved(found, verdict, tree):
    """R15: the script's own drop-check run, on a fresh unpatched copy of the reviewed tree, exited 0 and
    printed every expected line as a whole line."""
    if found["reproduced"] or found["not_runnable"] or not drop_check_valid_shape(verdict.get("drop_check")):
        return False
    result = verdict.get("drop_receipt") if isinstance(verdict.get("drop_receipt"), dict) else {}
    if not (result.get("ran") and not result.get("timed_out") and result.get("exit_code") == 0
            and result.get("fingerprint") == tree and isinstance(result.get("output"), str)):
        return False
    seen = {line.rstrip() for line in result["output"].splitlines()}
    wanted = [line.rstrip() for line in verdict["drop_check"]["expected_output"].splitlines() if line.strip()]
    return bool(wanted) and all(line in seen for line in wanted)


def adjudicate(findings, verdicts, tree):
    """R14 to R16: apply the refuter's verdicts."""
    by_id = {}
    for verdict in verdicts:
        if isinstance(verdict, dict) and isinstance(verdict.get("id"), str):
            by_id.setdefault(verdict["id"], verdict)
    for found in findings:
        verdict = by_id.get(found["id"])
        if verdict:
            found["refuter"] = {key: verdict.get(key) for key in (
                "verdict", "rank", "scenario", "drop_check", "explanation")}
            found["drop_receipt"] = verdict.get("drop_receipt")
        if found["status"] == "mild":
            if verdict and verdict.get("verdict") == "RAISE":
                new = verdict.get("rank") if verdict.get("rank") in ("serious", "catastrophic") else "serious"
                found["rank_before_refuter"], found["rank"], found["status"] = found["rank"], new, "promoted"
            continue
        if found["status"] not in ("verified", "unverified"):
            continue
        if not verdict or verdict.get("verdict") not in ("PROMOTED", "DROPPED", "UNRESOLVED", "RAISE"):
            found["status"] = "unjudged"
            continue
        proved = drop_proved(found, verdict, tree)
        target = verdict.get("rank")
        if target in RANKS and target != found["rank"]:
            if lower_than(found["rank"], target):
                found["rank_before_refuter"], found["rank"] = found["rank"], target  # stricter, always allowed
            elif proved:  # R16: only with a valid drop check, and never below a floor of R8
                new = target if not lower_than(target, found["floor_rank"]) else found["floor_rank"]
                if lower_than(new, found["rank"]):
                    found["rank_before_refuter"], found["rank"] = found["rank"], new
        if verdict["verdict"] == "DROPPED":
            scenario = verdict.get("scenario")
            found["status"] = "dropped" if proved and isinstance(scenario, str) and scenario.strip() else "unresolved"
        elif found["rank"] == "mild":
            found["status"] = "mild"
            found["mild_reason"] = found["mild_reason"] or verdict.get("explanation") or \
                "the refuter lowered it with a passing drop check"
        elif verdict["verdict"] == "UNRESOLVED":
            found["status"] = "unresolved"
        else:
            found["status"] = "promoted"


def decide(run_dir):
    """R17 to R19: the verdict, from the files in the run directory only."""
    reasons = []

    def required(name, kind):
        value = read_json(run_dir / name)
        if not isinstance(value, kind):
            reasons.append(f"{name} is missing or unreadable")
            return None
        return value

    run = required("run.json", dict) or {}
    preflight = required("preflight.json", dict)
    errors = read_json(run_dir / "errors.json", [])
    reasons += errors if isinstance(errors, list) else ["errors.json is unreadable"]
    start = end = None
    findings, provers, extra, reviewed = [], [], 0, False
    if preflight and not preflight.get("ok"):
        reasons += preflight.get("reasons") or ["the preflight failed"]
    elif preflight:
        start = required("fingerprint-start.json", dict)
        end = required("fingerprint-end.json", dict)
        if start and not start.get("files"):
            reasons.append("the change is empty: nothing was reviewed")
        if start and start.get("submodules"):
            reasons.append("the change has submodules (" + ", ".join(start["submodules"])
                           + "); review copies cannot hold them, so nothing was reviewed")
        elif start and start.get("files"):
            reviewed = True
            recorded = required("findings.json", dict)
            provers = required("provers.json", list) or []
            if recorded is not None:
                findings, extra = recorded.get("findings"), recorded.get("prover_extra_ids", 0)
                if not isinstance(findings, list):
                    reasons.append("findings.json is missing or unreadable")
                    findings = []
    plan = (preflight or {}).get("plan") or {}
    tree = start["tree"] if start else None
    launches = []

    def needed(name, role, what):
        launch = read_json(run_dir / "launches" / name / "launch.json")
        if not isinstance(launch, dict):
            reasons.append(f"{name}: the {what} did not run")
            launch = {"name": name, "role": role, "status": "missing"}
        elif launch.get("status") != "complete":
            reasons.append(f"{name}: dropout, {launch.get('reason')}")
        launches.append(launch)
        return launch

    if reviewed:
        for planned in plan.get("reviewers", []):
            needed(planned["name"], "reviewer", "reviewer")
        for batch in provers:
            if isinstance(batch, dict):
                needed(batch.get("name"), "prover", "prover")
    # The refuter is needed when every reviewer and prover launch is complete (R14).
    complete = reviewed and not any(launch.get("status") != "complete" for launch in launches)
    counts = {"raw_findings": len(findings), "invalid_evidence": 0, "raised_ranks": 0, "lowered_ranks": 0,
              "replaced_ranks": 0, "replaced_kinds": 0, "patches_not_applied": 0, "reproduced": 0,
              "prover_extra_ids": extra if isinstance(extra, int) else 0}
    runners = []
    for found in findings:
        counts["raised_ranks"] += found.get("rank_raised", False)
        counts["lowered_ranks"] += found.get("rank_lowered", False)
        counts["replaced_ranks"] += found.get("rank_replaced", False)
        counts["replaced_kinds"] += found.get("kind_replaced", False)
        counts["reproduced"] += found.get("reproduced", False)
        if found.get("prover_result") is not None:
            counts["invalid_evidence"] += not found.get("evidence_valid")
        if found.get("prover_missing"):
            reasons.append(f"{found['id']}: the prover returned no result for it")
        if found.get("missing_repro"):
            reasons.append(f"{found['id']}: the prover ranked it {found.get('prover_rank')} with neither repro "
                           "nor not_runnable (R12)")
        receipts = found.get("receipts") or {}
        if (receipts.get("apply") or {}).get("exit_code") not in (None, 0):
            counts["patches_not_applied"] += 1
        first = receipts.get("1") or {}
        if first.get("ran") and first.get("fingerprint") != tree:
            reasons.append(f"{found['id']}: the repro copy fingerprint differs from the reviewed state")
        if found.get("runner"):
            runners.append(found["runner"])
    for name in runners:
        needed(name, "runner", "runner")
    if run.get("path") == "full" and complete and any(f.get("status") in ("verified", "unverified")
                                                      for f in findings):
        refuter = needed("refuter", "refuter", "refuter")
        verdicts = read_json(run_dir / "refuter.json")
        if refuter.get("status") == "complete" and not isinstance(verdicts, list):
            reasons.append("refuter.json is missing or unreadable")
        verdicts = verdicts if isinstance(verdicts, list) else []
        for verdict in verdicts:
            result = verdict.get("drop_receipt") if isinstance(verdict, dict) else None
            if isinstance(result, dict) and result.get("runner"):
                needed(result["runner"], "runner", "runner")
            if isinstance(result, dict) and result.get("ran") and result.get("fingerprint") != tree:
                reasons.append(f"{verdict.get('id')}: the drop copy fingerprint differs from the reviewed state")
        adjudicate(findings, verdicts, tree)
    unjudged = [f["id"] for f in findings if f.get("status") == "unjudged"]
    if unjudged:
        reasons.append("unjudged: " + ", ".join(unjudged))
    if end is not None:
        if end.get("tree") != tree:
            reasons.append("the real checkout changed during the review")
        if end.get("submodules"):
            reasons.append(f"at the end of the review, {end['submodules']}")
    counts["mild"] = sum(f.get("status") == "mild" for f in findings)
    if reasons:
        verdict = "INCOMPLETE"
    elif any(f.get("status") in BLOCKING for f in findings):
        verdict = "NOT-READY"
    elif any(f.get("status") == "mild" for f in findings):
        verdict = "READY-WITH-FIXES"
    else:
        verdict = "READY"
    return {"verdict": verdict, "verdict_line": verdict_line(verdict, run.get("path"), plan),
            "incomplete_reasons": reasons, "run_id": run.get("run_id"), "path": run.get("path"),
            "writer": run.get("writer"), "same_provider": bool(plan.get("same_provider")),
            "reviewers": [planned["builtin"] for planned in plan.get("reviewers", [])],
            "tree": tree, "base": start["base"] if start else None,
            "diff_lines": start["diff_lines"] if start else 0,
            "launches": [{key: launch.get(key) for key in (
                "name", "role", "provider", "builtin", "status", "reason", "requested_model", "served_model",
                "requested_effort", "served_effort", "served_sandbox", "same_provider", "cost_usd", "tokens",
                "sandbox_check", "session_id")} for launch in launches],
            "findings": findings, "counts": counts, "cleanup": read_json(run_dir / "cleanup.json")}


def outcome_path():
    state = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return state / "llm-orchestrator" / "review-outcomes.jsonl"


def append_outcome(*rows):
    path = outcome_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        for row in rows:
            stream.write(json.dumps(row, sort_keys=True) + "\n")


def outcome_row(run_dir, review):
    """R20: one row per run, naming the reviewers, with no claim text or code."""
    run = read_json(run_dir / "run.json", {})
    costs = [launch["cost_usd"] for launch in review["launches"] if type(launch.get("cost_usd")) in (int, float)]
    tokens = {}
    for launch in review["launches"]:
        for key, value in (launch.get("tokens") or {}).items():
            tokens[key] = tokens.get(key, 0) + value
    return {"row": "review", "run_id": review["run_id"], "date": now(),
            "repository": Path(run.get("project", "")).name, "path": review["path"],
            "writer": review["writer"], "reviewers": review["reviewers"], "same_provider": review["same_provider"],
            "diff_lines": review["diff_lines"],
            "launches": [{key: launch.get(key) for key in (
                "name", "role", "provider", "builtin", "status", "requested_model", "served_model",
                "requested_effort", "served_effort")} for launch in review["launches"]],
            "verdict": review["verdict"], "incomplete_reasons": review["incomplete_reasons"],
            "counts": review["counts"], "duration_s": review.get("duration_s"),
            "cost_usd": round(sum(costs), 4) if costs else None, "tokens": tokens or None}


def command_run(args):
    project = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip()).resolve()
    run_dir = Path(args.run_dir).expanduser().absolute()
    if args.child:
        options = read_json(run_dir / "run.json")
        if not options or (run_dir / "review.json").exists():
            print("orch-review: the run directory has no pending run", file=sys.stderr)
            return 2
    else:
        if run_dir.exists() or run_dir.is_symlink():
            print(f"orch-review: the run directory already exists: {run_dir}", file=sys.stderr)
            return 2
        resolved = run_dir.resolve()
        if nested(resolved, project):
            print("orch-review: the run directory must be outside the repository", file=sys.stderr)
            return 2
        if any(nested(resolved, root) for root in temporary_roots()):
            print("orch-review: the run directory must be outside every temporary directory, because the "
                  "sandboxes let reviewers and fix experiments write there", file=sys.stderr)
            return 2
        run_dir.mkdir(parents=True, mode=0o700)
        options = {"run_id": uuid.uuid4().hex, "project": str(project), "path": args.path,
                   "writer": args.writer, "base": args.base, "spec": str(Path(args.spec).absolute()),
                   "allow_test_changes": args.allow_test_changes, "started": now()}
        write_json(run_dir / "run.json", options)
        if args.detach:
            with open(run_dir / "run.log", "ab") as log:
                child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "run", "--child",
                                          "--run-dir", str(run_dir)], cwd=project, stdin=subprocess.DEVNULL,
                                         stdout=log, stderr=log, start_new_session=True)
            (run_dir / "pid").write_text(str(child.pid))
            print(json.dumps({"status": "started", "run_dir": str(run_dir), "pid": child.pid,
                              "next": f"orch-review.py wait {run_dir} --seconds 540"}))
            return 0
    (run_dir / "pid").write_text(str(os.getpid()))
    review = Review(project, run_dir, options).execute()
    print(json.dumps(summary(run_dir, review)))
    return 0


def temporary_roots():
    """Directories the Codex and Claude sandboxes leave writable besides the copy."""
    roots = [os.environ.get("TMPDIR"), tempfile.gettempdir(), "/tmp", "/var/tmp"]
    if sys.platform == "darwin":
        found = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True,
                               stdin=subprocess.DEVNULL)
        roots.append(found.stdout.strip() if found.returncode == 0 else None)
    return {Path(root).resolve() for root in roots if root}


def summary(run_dir, review):
    warnings = []
    for session in ((review.get("cleanup") or {}).get("sessions") or []):
        if session.get("status") != "deleted":
            warnings.append(f"could not delete the kept /code-review session {session.get('session_id')}: "
                            + "; ".join(session.get("problems") or []))
    return {"status": "finished", "verdict": review["verdict"],
            "verdict_line": review.get("verdict_line", review["verdict"]),
            "same_provider": review.get("same_provider", False), "review": str(run_dir / "review.json"),
            "incomplete_reasons": review["incomplete_reasons"],
            "blocking": [f["id"] for f in review["findings"] if f["status"] in BLOCKING],
            "mild": [{"id": f["id"], "mild_reason": f.get("mild_reason")} for f in review["findings"]
                     if f["status"] == "mild"],
            "warnings": warnings}


def command_wait(args):
    run_dir = Path(args.run_dir).expanduser().absolute()
    deadline = time.monotonic() + args.seconds
    while True:
        review = read_json(run_dir / "review.json")
        if review is not None:
            print(json.dumps(summary(run_dir, review)))
            return 0
        pid = (run_dir / "pid").read_text().strip() if (run_dir / "pid").is_file() else ""
        if not pid.isdigit() or not alive(int(pid)):
            time.sleep(0.5)
            if (run_dir / "review.json").exists():
                continue
            print(json.dumps({"status": "crashed", "verdict": "INCOMPLETE", "run_dir": str(run_dir),
                              "reason": "the run stopped without writing review.json; start a new run"}))
            return 1
        if time.monotonic() >= deadline:
            print(json.dumps({"status": "running", "run_dir": str(run_dir),
                              "next": f"orch-review.py wait {run_dir} --seconds {args.seconds}"}))
            return 3
        time.sleep(1)


def command_record(args):
    """R21: one disposition per finding, appended to the outcome log."""
    run_dir = Path(args.run_dir).expanduser().absolute()
    review = read_json(run_dir / "review.json")
    run = read_json(run_dir / "run.json", {})
    if review is None:
        return fail("the run has no review.json")
    if (run_dir / "dispositions.json").exists():
        return fail("dispositions were already recorded for this run")
    dispositions = read_json(args.dispositions)
    if not isinstance(dispositions, dict):
        return fail("the dispositions file must be a JSON object keyed by finding id")
    ids = [f["id"] for f in review["findings"]]
    problems = [f"{name}: no disposition" for name in ids if name not in dispositions]
    problems += [f"{name}: not a finding of this review" for name in dispositions if name not in ids]
    project = Path(run.get("project", "."))
    for found in review["findings"]:
        entry = dispositions.get(found["id"])
        if entry is None:
            continue
        kind = entry.get("disposition") if isinstance(entry, dict) else None
        if kind == "fixed":
            if not (isinstance(entry.get("check"), str) and entry["check"].strip()):
                problems.append(f"{found['id']}: fixed needs the check that failed before and passes after")
        elif kind == "refuted":
            valid, why = file_line_valid(project, review["tree"], entry.get("evidence"))
            if not valid:
                problems.append(f"{found['id']}: refuted needs a file-line quote from the reviewed files ({why})")
        elif kind == "ignored":
            if not (isinstance(entry.get("reason"), str) and entry["reason"].strip()):
                problems.append(f"{found['id']}: ignored needs a reason")
            elif found["status"] in BLOCKING and entry.get("person_approved") is not True:
                problems.append(f"{found['id']}: a blocking finding is ignored only when the person said so "
                                "(person_approved: true)")
        else:
            problems.append(f"{found['id']}: the disposition must be fixed, refuted or ignored")
    if problems:
        return fail("; ".join(problems))
    write_json(run_dir / "dispositions.json", dispositions)
    append_outcome(*[{"row": "finding", "run_id": review["run_id"], "date": now(), "finding": f["id"],
                      "reviewer": f.get("reviewer"), "provider": f["provider"], "rank": f.get("rank"),
                      "kind": f.get("kind"), "status": f["status"],
                      "disposition": dispositions[f["id"]]["disposition"]}
                     for f in review["findings"]])
    print(json.dumps({"status": "recorded", "findings": len(ids)}))
    return 0


def fail(message):
    print(f"orch-review: {message}", file=sys.stderr)
    return 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="review the current change")
    run.add_argument("--run-dir", required=True, help="a new directory outside the repository")
    run.add_argument("--child", action="store_true", help=argparse.SUPPRESS)
    run.add_argument("--detach", action="store_true", help="start in the background; then call wait")
    run.add_argument("--path", choices=["standard", "full"])
    run.add_argument("--writer", choices=["claude", "codex"], help="the harness that wrote the change")
    run.add_argument("--base", help="the ref the change is reviewed against")
    run.add_argument("--spec", help="the file the change must implement")
    run.add_argument("--allow-test-changes", action="store_true",
                     help="the task may change tests; a test-tampering finding may then be mild")
    wait = commands.add_parser("wait", help="wait for a detached run to finish")
    wait.add_argument("run_dir")
    wait.add_argument("--seconds", type=int, default=540)
    record = commands.add_parser("record", help="record what happened to each finding")
    record.add_argument("run_dir")
    record.add_argument("--dispositions", required=True)
    args = parser.parse_args(argv)
    if args.command == "run":
        if not args.child and not all((args.path, args.writer, args.base, args.spec)):
            parser.error("run needs --path, --writer, --base and --spec")
        return command_run(args)
    if args.command == "wait":
        return command_wait(args)
    return command_record(args)


if __name__ == "__main__":
    sys.exit(main())
