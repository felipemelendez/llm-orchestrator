#!/usr/bin/env python3
"""Run one Standard or Full review of the current change and decide its verdict.

`run` reviews the change in disposable clones, checks each finding's evidence,
runs proposed fixes in a sandbox, runs the refuter on Full, and writes
review.json. `wait` reports when a detached run has finished. `record` appends
the agent's disposition of each finding to the outcome log.
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
KINDS = ("defect", "spec-gap", "scope-creep", "test-tampering")
NOT_CHECKED = ("tests-not-run", "files-not-read", "claim-unverified")
BLOCKING = {"verified", "unverified", "promoted", "unresolved", "unjudged"}
CONFIDENCE_FLOOR = 0.8
PART_LINES = 150
REPRO_TIMEOUT = 600
SEAT_TIMEOUT = 3600
OUTPUT_LIMIT = 200_000

_spec = importlib.util.spec_from_file_location("orch_task_resources", HERE / "orch-task-resources.py")
resources = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(resources)

SEAT_RULES = """\
## What to return

Return one JSON object that matches the schema: `findings` and `not_checked`.

Each finding has `file`, `line`, `rank` (catastrophic, serious or mild, graded
by the harm ranking), `kind` (defect, spec-gap, scope-creep or test-tampering),
`confidence` (0.0 to 1.0), `claim` (the state, and the wrong result it gives),
`evidence`, `repro` and `not_runnable`. Set unused fields to null.

`evidence` is one of:

- `{"type": "file-line", "file", "line", "quote"}`: `quote` is the exact text
  of that line in your copy. The script checks it against the reviewed files.
- `{"type": "test-run", "command", "output"}`: `command` is exactly a command
  you ran with your shell tool, and every line of `output` is copied whole from
  its output. The script checks both against your own session.

Every serious or catastrophic finding needs either `repro` or `not_runnable`:

- `repro`: `command` fails on the change as it is; `patch` is your proposed
  fix as a unified diff that `git apply` accepts at the repository root, after
  which `command` passes. The script runs both itself, in a fresh copy, in a
  sandbox with no network and no writes outside the copy.
- `not_runnable`: why no command can show the failure.

A serious or catastrophic finding with neither makes the review incomplete.

`not_checked` lists only what you did not check, each as `{"category",
"text"}` with category tests-not-run, files-not-read or claim-unverified.
Every item makes the review incomplete, so list what you really did not check
and nothing else.

Report everything you find with its confidence. Zero findings is a valid
result. You work in a disposable copy: edit it freely, it is thrown away. Never
change files outside it.
"""


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
    """A command as the seat ran it, plus the inner script of a `<shell> -lc <script>` wrapper."""
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
    """R9: the seat's own stream shows exactly that command, and every output line appears in its output."""
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
                return True, "the command and its output are in the seat's session"
    return False, "no command in the seat's session matches the command and output"


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


class Review:
    def __init__(self, project, run_dir, options):
        self.project = project
        self.run_dir = run_dir
        self.options = options
        self.manager = None
        self.task = None
        self.token = None

    # Step 1
    def preflight(self):
        options, reasons = self.options, []
        full = options["path"] == "full"
        needed = {"claude", "codex"} if full else {options["writer"]}
        providers = {"claude": self.check_claude(), "codex": self.check_codex()}
        for name in sorted(needed):
            if not providers[name]["ready"]:
                reasons.append(f"preflight: {name} is {providers[name]['state']}")
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
        if base.returncode:
            reasons.append("preflight: the base ref does not name a commit")
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
        result = {"ok": not reasons, "reasons": reasons, "providers": providers, "sandbox": sandbox,
                  "harm_ranking": ranking, "harm_ranking_source": source,
                  "spec": spec.read_text() if spec.is_file() else None,
                  "base": base.stdout.strip() if base.returncode == 0 else None,
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
            return subprocess.run(sandboxed(probe, ["true"]), stdin=subprocess.DEVNULL, capture_output=True, env=reduced_env(),
                                  timeout=60).returncode == 0
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

    # Steps 2 and 4
    def start_state(self, preflight):
        tree = resources.fingerprint(self.project)
        base = git(self.project, "merge-base", preflight["base"], "HEAD").strip()
        numstat = git(self.project, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                      "--numstat", "-z", base, tree)
        files = []
        for record in filter(None, numstat.split("\0")):
            added, deleted, name = record.split("\t", 2)
            count = (int(added) if added.isdigit() else 0) + (int(deleted) if deleted.isdigit() else 0)
            files.append({"file": name, "lines": count})
        parts = []
        if self.options["split"]:
            # Whole files in diff order; a file over the limit is a part of its own.
            for item in files:
                if parts and parts[-1]["lines"] + item["lines"] <= PART_LINES:
                    parts[-1]["files"].append(item["file"])
                    parts[-1]["lines"] += item["lines"]
                else:
                    parts.append({"files": [item["file"]], "lines": item["lines"]})
        elif files:
            parts.append({"files": [item["file"] for item in files],
                          "lines": sum(item["lines"] for item in files)})
        for n, part in enumerate(parts, 1):
            part["number"] = n
            part["diff"] = git(self.project, "-c", "core.quotePath=false", "--literal-pathspecs", "diff",
                               "--no-ext-diff", "--no-textconv", "--no-renames", base, tree, "--", *part["files"])
        full_diff = "".join(part["diff"] for part in parts)
        submodules = [entry.split("\t", 1)[1] for entry in git(self.project, "ls-tree", "-r", "-z", tree).split("\0")
                      if entry.startswith("160000 ")]
        state = {"tree": tree, "head": git(self.project, "rev-parse", "HEAD").strip(), "base": base,
                 "submodules": submodules,
                 "files": files, "diff_lines": sum(item["lines"] for item in files),
                 "security": bool(security_pattern().search(full_diff))}
        write_json(self.run_dir / "parts.json", parts)
        write_json(self.run_dir / "fingerprint-start.json", state)
        return state, parts

    # Step 3
    def make_copy(self, preflight, launch_dir):
        """A fresh clone with copy_ignored paths and setup; returns (path, fingerprint, problem)."""
        created = self.manager.create(self.task["id"], self.token, "clone", tree=self.tree)
        copy = Path(created["path"])
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
                (launch_dir / "setup.log").write_text(clip(setup.stdout + setup.stderr))
                if setup.returncode:
                    return copy, None, f"review.setup exited {setup.returncode}"
            except subprocess.TimeoutExpired:
                return copy, None, "review.setup timed out"
        return copy, resources.fingerprint(copy), None

    # Step 5
    def seat_prompt(self, preflight, state, parts, part, brief):
        sections = [f"Brief: {brief}", f"Part: {part['number']} of {len(parts)}", "",
                    (REFERENCES / f"{brief}.md").read_text()]
        if state["security"]:
            sections.append((REFERENCES / "security-lens.md").read_text())
        sections.append(SEAT_RULES)
        sections += ["## The specification", "", preflight["spec"], "",
                     "## Harm ranking", "", preflight["harm_ranking"], "",
                     "## Test command", "",
                     preflight["test_cmd"] or "no test command is configured; find and run the project's tests",
                     "", "## The change", "",
                     f"Your working directory is a copy of the repository with the change applied. "
                     f"`git diff {state['base']}` shows the whole change.", "",
                     "Changed files:"]
        sections += [f"- {item['file']} ({item['lines']} lines)" for item in state["files"]]
        if len(parts) > 1:
            sections += ["", "Review only the files of this part:"]
            sections += [f"- {name}" for name in part["files"]]
        sections += ["", "<diff>", part["diff"], "</diff>", ""]
        return "\n".join(sections)

    def launch(self, name, provider, brief, prompt, schema, preflight):
        launch_dir = self.run_dir / "launches" / name
        launch_dir.mkdir(parents=True)
        (launch_dir / "prompt.txt").write_text(prompt)
        record = {"name": name, "provider": provider, "brief": brief, "status": "dropout",
                  "requested_model": preflight["providers"][provider].get("requested_model"),
                  "requested_effort": EFFORT, "served_model": [], "served_effort": [],
                  "started": now()}
        role = "refuter" if brief == "refuter" else "seat"
        try:
            copy, fingerprint, problem = self.make_copy(preflight, launch_dir)
            record["copy_fingerprint"] = fingerprint
            if problem or fingerprint != self.tree:
                record["reason"] = problem or "the copy does not match the fingerprint"
            elif provider == "claude":
                record.update(run_claude(copy, prompt, schema, launch_dir, self.run_dir, role))
            else:
                codex = preflight["providers"]["codex"]
                record.update(run_codex(copy, prompt, schema, launch_dir, codex.get("requested_model"),
                                        codex.get("mcp_servers", []), role))
        except (resources.Unsafe, Failure, OSError) as error:
            record["reason"] = f"the launch could not start: {error}"
        record["finished"] = now()
        write_json(launch_dir / "launch.json", record)
        return record

    # Step 6
    def validate(self, launch, part_number, preflight):
        """R8, R9, R11 to R13 for one complete seat launch, and the R10 fix experiments."""
        launch_dir = self.run_dir / "launches" / launch["name"]
        output = read_json(launch_dir / "output.json")
        commands = read_json(launch_dir / "commands.json", [])
        findings = []
        for n, raw in enumerate(output["findings"], 1):
            item = raw if isinstance(raw, dict) else {}
            rank = item.get("rank")
            found = {"id": f"{launch['brief']}-{part_number}-{n}", "seat": launch["brief"],
                     "part": part_number, "provider": launch["provider"], "raw": raw,
                     "file": item.get("file"), "line": item.get("line"), "claim": item.get("claim"),
                     "kind": item.get("kind"), "original_rank": rank, "rank": rank,
                     "rank_replaced": rank not in RANKS, "rank_raised": False,
                     "evidence": item.get("evidence")}
            if found["rank_replaced"]:
                found["rank"] = "serious"
            if (found["kind"] == "test-tampering" and found["rank"] == "mild"
                    and not self.options["allow_test_changes"]):
                found["rank"], found["rank_raised"] = "serious", True
            confidence = item.get("confidence")
            found["confidence"] = (float(confidence) if type(confidence) in (int, float) else None)
            found["evidence_valid"], found["evidence_reason"] = evidence_valid(
                self.project, self.tree, commands, item.get("evidence"))
            repro = item.get("repro")
            found["repro"] = (repro if isinstance(repro, dict) and isinstance(repro.get("command"), str)
                              and repro["command"].strip() and isinstance(repro.get("patch"), str) else None)
            not_runnable = item.get("not_runnable")
            found["not_runnable"] = (not_runnable if isinstance(not_runnable, str) and not_runnable.strip()
                                     and not found["repro"] else None)
            found["receipts"], found["reproduced"] = {}, False
            found["from_dropout"] = launch["status"] != "complete"
            # A finding the script raised to serious (R13) was not asked for a repro, so it stays
            # unverified and blocking rather than making the review incomplete (R12).
            found["missing_repro"] = (found["rank"] != "mild" and not found["repro"]
                                      and not found["not_runnable"] and not found["rank_raised"])
            findings.append(found)
        if launch["status"] == "complete":  # a dropout's findings are kept but not run
            with ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(lambda f: self.experiment(f, preflight),
                              [f for f in findings if f["rank"] != "mild" and f["repro"]]))
        not_checked = [dict(item, launch=launch["name"]) if isinstance(item, dict)
                       else {"launch": launch["name"], "category": None, "text": item}
                       for item in output["not_checked"]]
        return findings, not_checked

    def experiment(self, found, preflight):
        """R10: receipt 1, git apply, receipt 2, each under the Codex sandbox in a fresh copy."""
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
        for key, value in found["receipts"].items():
            write_json(directory / f"receipt-{key}.json", value)
        first, second = found["receipts"]["1"], found["receipts"]["2"]
        found["reproduced"] = bool(first.get("ran") and not first.get("timed_out")
                                   and first.get("exit_code") not in (0, None)
                                   and second.get("ran") and second.get("exit_code") == 0)

    # Step 7
    def refuter_prompt(self, preflight, state, findings):
        judged = [f for f in findings if f["status"] != "note"]
        shown = [{key: f[key] for key in ("id", "seat", "provider", "file", "line", "rank", "kind",
                                          "confidence", "claim", "evidence", "repro", "not_runnable",
                                          "reproduced", "receipts", "status")} for f in judged]
        return "\n".join([
            "Brief: refuter", "", (REFERENCES / "refuter.md").read_text(),
            "## The specification", "", preflight["spec"], "",
            "## Harm ranking", "", preflight["harm_ranking"], "",
            "## The findings, with the receipts of each fix experiment", "",
            "Judge these ids: " + ", ".join(f["id"] for f in judged if f["rank"] != "mild"), "",
            "```json", json.dumps(shown, indent=2), "```", "",
            f"Your working directory is a copy of the repository with the change. "
            f"`git diff {state['base']}` shows it.", ""])

    def check_refuter(self):
        """Record whether each refuter verdict's evidence is valid under R9 (R15, R16)."""
        output = read_json(self.run_dir / "launches/refuter/output.json", {})
        checked = []
        for raw in output.get("verdicts", []) if isinstance(output, dict) else []:
            item = raw if isinstance(raw, dict) else {}
            evidence = item.get("evidence") if isinstance(item.get("evidence"), dict) else {}
            valid, why = False, "no evidence"
            if evidence.get("type") == "file-line":
                valid, why = file_line_valid(self.project, self.tree, evidence)
                explanation = evidence.get("explanation")
                if valid and not (isinstance(explanation, str) and explanation.strip()):
                    valid, why = False, "a quote without an explanation"
            elif evidence.get("type") == "receipt-1":
                valid, why = True, "cites receipt 1"
            checked.append({"raw": raw, "id": item.get("id"), "verdict": item.get("verdict"),
                            "rank": item.get("rank"), "evidence": evidence,
                            "evidence_valid": valid, "evidence_reason": why})
        write_json(self.run_dir / "refuter.json", checked)

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
        state, parts = self.start_state(preflight)
        self.tree = state["tree"]
        if not parts or state["submodules"]:
            # Copies hold no submodule contents; filling them would need the network or the real
            # module store, so a change with submodules is not reviewed (decide() says why).
            return
        self.manager = resources.Manager()
        self.task = self.manager.start(self.project, f"review {self.run_dir.name}")
        self.token = self.manager.acquire(self.task["id"], "orch-review")["token"]
        schema = (REFERENCES / "seat-schema.json").read_text()
        jobs = [(f"{brief}-{part['number']}", provider, brief, part)
                for brief, provider in self.options["seats"] for part in parts]
        with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
            launches = list(pool.map(lambda job: (job, self.launch(
                job[0], job[1], job[2], self.seat_prompt(preflight, state, parts, job[3], job[2]),
                schema, preflight)), jobs))
        findings, not_checked = [], []
        for (_, _, _, part), launch in launches:
            answer = read_json(self.run_dir / "launches" / launch["name"] / "output.json")
            if launch["status"] == "complete" or answer_shape_valid(answer, "seat"):
                found, missed = self.validate(launch, part["number"], preflight)
                findings += found
                not_checked += missed
        for found in findings:
            found["status"] = initial_status(found)
        write_json(self.run_dir / "findings.json", {"findings": findings, "not_checked": not_checked})
        complete = all(launch["status"] == "complete" for _, launch in launches)
        if (self.options["path"] == "full" and not self.options["no_refuter"] and complete
                and any(f["rank"] != "mild" for f in findings)):
            refuter = self.launch("refuter", "claude", "refuter",
                                  self.refuter_prompt(preflight, state, findings),
                                  (REFERENCES / "refuter-schema.json").read_text(), preflight)
            if refuter["status"] == "complete":
                self.check_refuter()

    def finish_state(self):
        start = read_json(self.run_dir / "fingerprint-start.json")
        if start is None:
            return
        write_json(self.run_dir / "fingerprint-end.json",
                   {"tree": resources.fingerprint(self.project), "submodules": self.submodules_dirty()})

    def cleanup(self):
        if not self.task:
            return
        try:
            self.manager.release(self.task["id"], self.token, stopped=True)
            result = self.manager.finish(self.task["id"])
            write_json(self.run_dir / "cleanup.json", {"status": result["status"],
                                                      "kept": result.get("reasons", [])})
        except (resources.Unsafe, OSError) as error:
            write_json(self.run_dir / "cleanup.json", {"status": "blocked", "kept": [str(error)]})


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")


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
}


def reduced_env(provider=None, **extra):
    """The environment for a seat or an experiment: the basics, plus only the variables the
    provider's CLI uses to reach its model. Cloud credentials and tokens (AWS_*, GITHUB_TOKEN and
    the like) are left out, so a seat cannot use the person's other accounts."""
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
              "timed_out": False}
    # Output goes to an unnamed file, not a pipe, so a child left in the background cannot hold
    # the receipt open. The whole process group is killed when the command ends or times out.
    with tempfile.TemporaryFile() as output:
        try:
            # Python checks a cached .pyc by source mtime in whole seconds and size, so a patch applied
            # within a second of receipt 1 could run the unpatched code; no bytecode is written instead.
            process = subprocess.Popen(record["argv"], cwd=copy, stdin=subprocess.PIPE, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True,
                                       env=reduced_env(PYTHONDONTWRITEBYTECODE="1"))
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
    with open(stream_path, "wb") as stream, open(launch_dir / "stderr.log", "wb") as errors:
        process = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=stream, stderr=errors,
                                   start_new_session=True, env=env)
        try:
            process.communicate(prompt.encode(), timeout=SEAT_TIMEOUT)
        except subprocess.TimeoutExpired:
            kill_group(process)
            return None
        kill_group(process)
    return process.returncode


def stream_events(path):
    events = []
    for line in Path(path).read_text().splitlines():
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
    """Claude Code's Bash sandbox for a seat: writes only in its copy, no network, no reading the
    run directory or credential folders, and no fallback to running a command outside the sandbox."""
    return json.dumps({"sandbox": {
        "enabled": True, "failIfUnavailable": True, "allowUnsandboxedCommands": False,
        "autoAllowBashIfSandboxed": True, "excludedCommands": [],
        "filesystem": {"allowWrite": [str(copy)], "denyRead": [str(run_dir), *CREDENTIAL_DIRS]},
        "network": {"allowedDomains": [], "strictAllowlist": True}}})


def finish_launch(fields, output, launch_dir):
    """Keep whatever answer the launch gave, even from a dropout (R19); complete only without a reason."""
    if isinstance(output, dict):
        write_json(launch_dir / "output.json", output)
    if not fields["reason"]:
        fields["status"] = "complete"
    return fields


def run_claude(copy, prompt, schema, launch_dir, run_dir, role):
    """R5. Returns the launch fields; a dropout (R7) keeps status "dropout" with a reason."""
    argv = ["claude", "-p", "--settings", claude_sandbox(copy, run_dir),
            "--output-format", "stream-json", "--verbose", "--model", CLAUDE_ALIAS,
            "--effort", EFFORT, "--json-schema", schema, "--safe-mode", "--restricted",
            "--tools", "Read,Grep,Glob,Bash", "--allowedTools", "Read,Grep,Glob,Bash",
            "--permission-mode", "dontAsk", "--permission-prompts", "none", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--no-session-persistence"]
    stream = launch_dir / "stream.jsonl"
    code = run_process(argv, copy, prompt, stream, launch_dir, reduced_env("claude"))
    events = stream_events(stream)
    served, uses, results, commands, mcp, unsandboxed, initialized = [], {}, [], [], [], False, False
    for event in events:
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            initialized = True
            mcp = event.get("mcp_servers") or []
        message = event.get("message") if isinstance(event.get("message"), dict) else {}
        content = message.get("content") if isinstance(message.get("content"), list) else []
        if kind == "assistant":
            if isinstance(message.get("model"), str) and message["model"] not in served:
                served.append(message["model"])
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("name") == "Bash":
                    request = block.get("input") if isinstance(block.get("input"), dict) else {}
                    unsandboxed |= request.get("dangerouslyDisableSandbox") is True
                    uses[block.get("id")] = (request.get("command"),
                                             request.get("run_in_background") is True)
        if kind == "user":
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result" and block.get("tool_use_id") in uses:
                    text = block.get("content")
                    if isinstance(text, list):
                        text = "\n".join(part.get("text", "") for part in text if isinstance(part, dict))
                    command, background = uses[block["tool_use_id"]]
                    if isinstance(command, str) and isinstance(text, str):
                        commands.append({"command": command, "output": text, "background": background,
                                         "failed": block.get("is_error") is True})
        if kind == "result":
            results.append(event)
    write_json(launch_dir / "commands.json", commands)
    fields = {"served_model": served, "served_effort": [], "exit_code": code,
              "cost_usd": results[-1].get("total_cost_usd") if results else None}
    output = None
    if results and results[-1].get("subtype") == "success" and results[-1].get("is_error") is False:
        output = results[-1].get("structured_output")
        if output is None and isinstance(results[-1].get("result"), str):
            output = parse_json_text(results[-1]["result"])
    fields["reason"] = dropout_reason(code, output, served, mcp,
                                      [model for model in served if not claude_family(model)], role)
    if not fields["reason"] and not initialized:
        fields["reason"] = "the stream has no system init event, so its MCP servers are unknown"
    if not fields["reason"] and unsandboxed:
        fields["reason"] = "a Bash call asked to run outside the sandbox"
    return finish_launch(fields, output, launch_dir)


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
    """R6. Served model and effort come from the session rollout named by the thread id."""
    schema_path = launch_dir / "schema.json"
    schema_path.write_text(schema)
    result_path = launch_dir / "last-message.json"
    argv = ["codex", "exec", "--json", "-s", "workspace-write", "-C", str(copy),
            "-c", f'model_reasoning_effort="{EFFORT}"', *codex_mcp_off(servers),
            "--output-schema", str(schema_path), "-o", str(result_path), "-"]
    stream = launch_dir / "stream.jsonl"
    # At codex_otel=info, codex logs the MCP servers it started; R6 reads that line.
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
    fields = {"served_model": served, "served_effort": efforts, "exit_code": code, "tokens": usage,
              "thread_id": thread, "model_compared": requested is not None}
    mcp = codex_mcp_servers(launch_dir / "stderr.log")
    fields["mcp_servers"] = mcp
    fields["reason"] = dropout_reason(code, output, served, mcp or [], mismatched, role)
    if not fields["reason"] and mcp is None:
        fields["reason"] = "no MCP server list in the codex log, so an MCP server may have loaded"
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
    if role == "refuter":
        return isinstance(output.get("verdicts"), list)
    return isinstance(output.get("findings"), list) and isinstance(output.get("not_checked"), list)


def dropout_reason(code, output, served, mcp, mismatched, role):
    """R7, plus the R5 and R6 rule that a launch with MCP servers is a dropout."""
    if code is None:
        return f"timed out after {SEAT_TIMEOUT} seconds"
    if code != 0:
        return f"exits nonzero ({code})"
    if mcp:
        return "loaded MCP servers"
    if not answer_shape_valid(output, role):
        return "no final result"
    if not served:
        return "no served model"
    if mismatched:
        return "the served model differs from the requested one: " + ", ".join(mismatched)
    return None


def initial_status(found):
    """R11 and R18 before the refuter."""
    if found["rank"] == "mild":
        floor = found["confidence"] is not None and found["confidence"] >= CONFIDENCE_FLOOR
        return "mild" if found["evidence_valid"] and floor else "note"
    if found["evidence_valid"] and (found["reproduced"] or found["not_runnable"]):
        return "verified"
    return "unverified"


def drop_allowed(found, verdict):
    """R15: which evidence may drop a finding, or lower its rank (R16).

    A passing receipt 1 may drop a finding whose experiment ran. A quoted line may drop only a
    finding whose experiment did not run, and only a line in the file and at the line the
    finding names."""
    if found["reproduced"] or found["not_runnable"] or not verdict["evidence_valid"]:
        return False
    evidence = verdict["evidence"]
    if evidence.get("type") == "receipt-1":
        first = found["receipts"].get("1", {})
        return bool(found["repro"] and first.get("ran") and not first.get("timed_out")
                    and first.get("exit_code") == 0)
    if evidence.get("type") != "file-line" or any(r.get("ran") for r in found["receipts"].values()):
        return False
    named = found["evidence"] if isinstance(found["evidence"], dict) else {}
    lines = {found["line"], named.get("line") if named.get("type") == "file-line" else None} - {None}
    same_file = str(evidence.get("file", "")).removeprefix("./") == str(found["file"] or "").removeprefix("./")
    return same_file and evidence.get("line") in lines


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
    start = parts = end = None
    findings, not_checked = [], []
    if preflight and not preflight.get("ok"):
        reasons += preflight.get("reasons") or ["the preflight failed"]
    elif preflight:
        start = required("fingerprint-start.json", dict)
        parts = required("parts.json", list)
        end = required("fingerprint-end.json", dict)
        if parts == []:
            reasons.append("the change is empty: nothing was reviewed")
        if start and start.get("submodules"):
            reasons.append("the change has submodules (" + ", ".join(start["submodules"])
                           + "); review copies cannot hold them, so nothing was reviewed")
        elif parts:
            recorded = required("findings.json", dict)
            if recorded is not None:
                findings, not_checked = recorded.get("findings"), recorded.get("not_checked")
                if not isinstance(findings, list) or not isinstance(not_checked, list):
                    reasons.append("findings.json is missing or unreadable")
                    findings, not_checked = [], []
    parts = parts or []
    counts = {"raw_findings": len(findings), "notes": 0, "invalid_evidence": 0, "below_floor": 0,
              "raised_ranks": 0, "replaced_ranks": 0, "patches_not_applied": 0}
    tree = start["tree"] if start else None
    launches = []
    for brief, provider in run.get("seats", []):
        for part in parts:
            name = f"{brief}-{part['number']}"
            launch = read_json(run_dir / "launches" / name / "launch.json")
            if launch is None:
                reasons.append(f"{name}: the seat did not run")
                launch = {"name": name, "provider": provider, "brief": brief, "status": "missing"}
            elif launch["status"] != "complete":
                reasons.append(f"{name}: dropout, {launch.get('reason')}")
            launches.append(launch)
    for found in findings:
        counts["raised_ranks"] += found["rank_raised"]
        counts["replaced_ranks"] += found["rank_replaced"]
        counts["invalid_evidence"] += not found["evidence_valid"]
        if found["rank"] == "mild" and found["evidence_valid"] and not (
                found["confidence"] is not None and found["confidence"] >= CONFIDENCE_FLOOR):
            counts["below_floor"] += 1
        if found["missing_repro"]:
            reasons.append(f"{found['id']}: a {found['rank']} finding has neither repro nor not_runnable (R12)")
        if found["receipts"].get("apply", {}).get("exit_code") not in (None, 0):
            counts["patches_not_applied"] += 1
        first = found["receipts"].get("1", {})
        if first.get("ran") and first.get("fingerprint") != tree:
            reasons.append(f"{found['id']}: the repro copy fingerprint differs from the reviewed state")
    for item in not_checked:
        reasons.append(f"{item['launch']}: not checked ({item.get('category')})")
    needs_refuter = (run.get("path") == "full" and not run.get("no_refuter") and not any(
        launch["status"] != "complete" for launch in launches) and any(f["rank"] != "mild" for f in findings))
    if needs_refuter:
        refuter = read_json(run_dir / "launches/refuter/launch.json")
        if refuter is None or refuter["status"] != "complete":
            reasons.append(f"refuter: dropout, {(refuter or {}).get('reason', 'it did not run')}")
            refuter = refuter or {"name": "refuter", "provider": "claude", "brief": "refuter",
                                  "status": "missing"}
        launches.append(refuter)
        verdicts = read_json(run_dir / "refuter.json", []) if refuter["status"] != "complete" else \
            required("refuter.json", list) or []
        adjudicate(findings, verdicts)
        unjudged = [f["id"] for f in findings if f["status"] == "unjudged"]
        if unjudged:
            reasons.append("unjudged by the refuter: " + ", ".join(unjudged))
    if end is not None:
        if end.get("tree") != tree:
            reasons.append("the real checkout changed during the review")
        if end.get("submodules"):
            reasons.append(f"at the end of the review, {end['submodules']}")
    counts["notes"] = sum(f["status"] == "note" for f in findings)
    if reasons:
        verdict = "INCOMPLETE"
    elif any(f["status"] in BLOCKING for f in findings):
        verdict = "NOT-READY"
    elif any(f["status"] == "mild" for f in findings):
        verdict = "READY-WITH-FIXES"
    else:
        verdict = "READY"
    return {"verdict": verdict, "incomplete_reasons": reasons, "run_id": run.get("run_id"),
            "path": run.get("path"), "writer": run.get("writer"), "experimental": bool(run.get("no_refuter")),
            "tree": tree, "base": start["base"] if start else None, "parts": len(parts),
            "diff_lines": start["diff_lines"] if start else 0,
            "launches": [{key: launch.get(key) for key in (
                "name", "provider", "brief", "status", "reason", "requested_model", "served_model",
                "requested_effort", "served_effort", "cost_usd", "tokens")} for launch in launches],
            "findings": findings, "not_checked": not_checked, "counts": counts,
            "cleanup": read_json(run_dir / "cleanup.json")}


def adjudicate(findings, verdicts):
    """R14 to R16: apply the refuter's verdicts to the serious and catastrophic findings."""
    by_id = {}
    for verdict in verdicts:
        if isinstance(verdict.get("id"), str):
            by_id.setdefault(verdict["id"], verdict)
    for found in findings:
        verdict = by_id.get(found["id"])
        if verdict and verdict.get("verdict") not in {"PROMOTED", "DROPPED", "UNRESOLVED"}:
            verdict = dict(verdict, rank=None, invalid=True)  # no rank change without a valid verdict
        if verdict and verdict.get("rank") in RANKS and verdict["rank"] != found["rank"]:
            lower = RANKS.index(verdict["rank"]) < RANKS.index(found["rank"])
            if lower and found["rank"] != "mild" and drop_allowed(found, verdict):
                found["rank_before_refuter"], found["rank"] = found["rank"], verdict["rank"]
        if found["status"] not in {"verified", "unverified"}:
            continue
        if found.get("rank_before_refuter") and found["rank"] == "mild":
            found["status"] = initial_status(found)
        elif not verdict or verdict.get("invalid"):
            found["status"] = "unjudged"
        elif verdict["verdict"] == "DROPPED":
            found["status"] = "dropped" if drop_allowed(found, verdict) else "unresolved"
        else:
            found["status"] = verdict["verdict"].lower()
        if verdict:
            found["refuter"] = {"verdict": verdict.get("verdict"), "rank": verdict.get("rank"),
                                "evidence": verdict.get("evidence"),
                                "evidence_valid": verdict.get("evidence_valid"),
                                "evidence_reason": verdict.get("evidence_reason")}


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
    """R20: one row per run, with no claim text or code."""
    run = read_json(run_dir / "run.json", {})
    costs = [launch["cost_usd"] for launch in review["launches"] if type(launch.get("cost_usd")) in (int, float)]
    tokens = {}
    for launch in review["launches"]:
        for key, value in (launch.get("tokens") or {}).items():
            tokens[key] = tokens.get(key, 0) + value
    return {"row": "review", "run_id": review["run_id"], "date": now(),
            "repository": Path(run.get("project", "")).name, "path": review["path"],
            "writer": review["writer"], "parts": review["parts"], "diff_lines": review["diff_lines"],
            "launches": [{key: launch.get(key) for key in (
                "name", "provider", "brief", "status", "requested_model", "served_model",
                "requested_effort", "served_effort")} for launch in review["launches"]],
            "verdict": review["verdict"], "incomplete_reasons": review["incomplete_reasons"],
            "experimental": review["experimental"], "counts": review["counts"],
            "duration_s": review.get("duration_s"), "cost_usd": round(sum(costs), 4) if costs else None,
            "tokens": tokens or None}


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
                  "sandboxes let seats and fix experiments write there", file=sys.stderr)
            return 2
        run_dir.mkdir(parents=True, mode=0o700)
        other = {"claude": "codex", "codex": "claude"}
        adversarial = args.adversarial_provider or other[args.writer]
        seats = ([[args.brief or "contract", args.writer]] if args.path == "standard"
                 else [["contract", other[adversarial]], ["adversarial", adversarial]])
        options = {"run_id": uuid.uuid4().hex, "project": str(project), "path": args.path,
                   "writer": args.writer, "base": args.base, "spec": str(Path(args.spec).absolute()),
                   "brief": args.brief, "adversarial_provider": args.adversarial_provider,
                   "split": args.split, "no_refuter": args.no_refuter,
                   "allow_test_changes": args.allow_test_changes, "seats": seats, "started": now()}
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
    return {"status": "finished", "verdict": review["verdict"], "review": str(run_dir / "review.json"),
            "incomplete_reasons": review["incomplete_reasons"],
            "blocking": [f["id"] for f in review["findings"] if f["status"] in BLOCKING],
            "mild": [f["id"] for f in review["findings"] if f["status"] == "mild"]}


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
                      "seat": f["seat"], "provider": f["provider"], "rank": f["rank"], "kind": f["kind"],
                      "status": f["status"], "disposition": dispositions[f["id"]]["disposition"]}
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
                     help="the task may change tests; test-tampering findings keep their rank")
    run.add_argument("--brief", choices=["contract", "adversarial"], help="Standard seat brief (T10)")
    run.add_argument("--adversarial-provider", choices=["claude", "codex"], help="(T10)")
    run.add_argument("--split", action="store_true", help="review in parts of at most 150 lines (T10)")
    run.add_argument("--no-refuter", action="store_true", help="skip the refuter; experimental (T10)")
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
