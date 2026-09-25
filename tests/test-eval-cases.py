#!/usr/bin/env python3
"""Check every `claude plugin eval` case under tests/evals/cases without a model call.

For each case: case.yaml matches the schema Claude Code 2.1.282 enforces, the
regexes compile, the scaffold runs, at least one grader fails on the bare
scaffold (red before), and every file and reply grader passes on the case's
reference solution (green after). Graders that read the trace (`tool_used`,
`tool_order`, `trace` targets) cannot be evaluated here and are only
schema-checked.
"""
from __future__ import annotations

import fnmatch
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
EVAL_DIR = ROOT / "tests" / "evals"
CASE_DIR = EVAL_DIR / "cases"
MIN_RUNS = 8

TOP_KEYS = {"schema_version", "name", "description", "tags", "plugins", "context",
            "execution", "runs", "graders", "expected_outcome"}
CONTEXT_KEYS = {"scaffold_script", "history_file", "add_dirs"}
EXECUTION_KEYS = {"prompt", "max_turns", "timeout_seconds", "model", "allowed_tools",
                  "artifact_publish", "growthbook_overrides", "append_system_prompt", "env"}
COMMON = {"type", "name", "weight", "arm"}
GRADER_KEYS = {
    "regex": COMMON | {"target", "pattern", "flags", "match"},
    "tool_used": COMMON | {"tool", "input_match", "min", "max"},
    "tool_order": COMMON | {"before", "after"},
    "file_exists": COMMON | {"path", "exists"},
    "llm": COMMON | {"criteria", "focus"},
    "baseline": COMMON | {"baseline_file", "criteria"},
}
TARGETS = {"trace", "last_message", "files", "mock_calls"}
# Tools a case may list; anything beyond the read-only set also needs --allow-tools.
KNOWN_TOOLS = {"Read", "Glob", "Grep", "NotebookRead", "Skill", "AskUserQuestion", "Agent",
               "TodoWrite", "TaskCreate", "TaskGet", "TaskList", "TaskUpdate", "TaskStop",
               "Bash", "Write", "Edit", "WebFetch", "WebSearch"}
# The grant the documented command passes (tests/evals/README.md).
GRANTED = {"Bash", "Write", "Edit"}


def js_regex(pattern: str, flags: str) -> re.Pattern[str]:
    """Compile a JavaScript regex with Python, refusing syntax the two read differently."""
    if re.search(r"\(\?[aiLmsux]+\)|\(\?P[<=]|\\[AZz]", pattern):
        raise ValueError("uses Python-only syntax (inline flags, (?P, \\A, \\Z)")
    bad = set(flags) - set("dgimsuvy")
    if bad:
        raise ValueError(f"flags {''.join(sorted(bad))!r} are not JavaScript flags")
    value = 0
    value |= re.IGNORECASE if "i" in flags else 0
    value |= re.MULTILINE if "m" in flags else 0
    value |= re.DOTALL if "s" in flags else 0
    return re.compile(pattern, value)


def schema_problems(case: dict, case_dir: pathlib.Path) -> list[str]:
    out = []
    if case.get("schema_version") != "1.1":
        out.append('schema_version must be "1.1"')
    if case.get("name") != case_dir.name:
        out.append(f"name {case.get('name')!r} does not match the directory")
    out += [f"unknown top-level key {k!r}" for k in sorted(set(case) - TOP_KEYS)]
    if not str(case.get("description", "")).strip():
        out.append("no description: say which rule the case defends")
    runs = case.get("runs")
    if not (isinstance(runs, int) and MIN_RUNS <= runs <= 50):
        out.append(f"runs must be an integer from {MIN_RUNS} to 50")
    if not isinstance(case.get("tags", []), list):
        out.append("tags must be a list")
    context = case.get("context", {})
    out += [f"unknown context key {k!r}" for k in sorted(set(context) - CONTEXT_KEYS)]
    script = context.get("scaffold_script")
    if script is not None and not (case_dir / script).is_file():
        out.append(f"scaffold_script {script!r} does not exist")
    execution = case.get("execution", {})
    out += [f"unknown execution key {k!r}" for k in sorted(set(execution) - EXECUTION_KEYS)]
    if "prompt" in execution:
        out.append("keep the prompt in prompt.md, not execution.prompt")
    for key, top in (("max_turns", 200), ("timeout_seconds", 3600)):
        value = execution.get(key)
        if value is not None and not (isinstance(value, int) and 0 < value <= top):
            out.append(f"execution.{key} must be an integer from 1 to {top}")
    tools = execution.get("allowed_tools", [])
    out += [f"unknown tool {t!r} in allowed_tools" for t in tools if t not in KNOWN_TOOLS]
    out += [f"allowed_tools lists {t!r}, which the documented command does not grant"
            for t in tools if t in {"WebFetch", "WebSearch"}]
    for key in execution.get("env", {}):
        if not re.fullmatch(r"EVAL_[A-Z0-9_]*", key):
            out.append(f"env key {key!r} must match EVAL_[A-Z0-9_]*; the run fails otherwise")
    if "model" in execution:
        out.append("do not pin a model per case; the command pins --model for every case")
    prompt = case_dir / "prompt.md"
    text = prompt.read_text() if prompt.is_file() else ""
    if not text.strip():
        out.append("prompt.md is missing or empty")
    elif text.startswith("---"):
        out.append("prompt.md must hold only the prompt; case fields go in case.yaml")
    graders = case.get("graders")
    if not isinstance(graders, list) or not graders:
        return out + ["graders must be a non-empty list"]
    names = [g.get("name") for g in graders]
    out += [f"duplicate grader name {n!r}" for n in sorted({n for n in names if names.count(n) > 1})]
    for g in graders:
        out += [f"grader {g.get('name')!r}: {p}" for p in grader_problems(g)]
    if not any(scored(g) for g in graders):
        out.append("every grader is with-only; nothing is scored in both arms")
    return out


def grader_problems(g: dict) -> list[str]:
    kind = g.get("type")
    if kind not in GRADER_KEYS:
        return [f"unknown type {kind!r}"]
    out = [f"unknown key {k!r}" for k in sorted(set(g) - GRADER_KEYS[kind])]
    if not isinstance(g.get("name"), str) or not g["name"]:
        out.append("no name")
    if kind in {"llm", "baseline"}:
        out.append("judge graders call a model; this suite uses free graders only")
    if g.get("arm") not in (None, "with-only", "both"):
        out.append("arm must be with-only or both")
    if kind == "regex":
        target = g.get("target", "last_message")
        if isinstance(target, dict):
            if set(target) != {"source", "path"} or target.get("source") != "file":
                out.append("a file target is {source: file, path: <path>}")
        elif target not in TARGETS:
            out.append(f"unknown target {target!r}")
        elif target == "files":
            out.append("use file_exists instead of a regex over the created-file list")
        match = g.get("match", "contains")
        if match not in ("contains", "not_contains") and not re.fullmatch(r"count:\d+", str(match)):
            out.append("match must be contains, not_contains or count:N")
        try:
            js_regex(str(g.get("pattern", "")), str(g.get("flags", "")))
        except (re.error, ValueError) as e:
            out.append(f"pattern does not compile: {e}")
        if not str(g.get("pattern", "")):
            out.append("empty pattern")
    if kind == "tool_used":
        if g.get("tool") not in KNOWN_TOOLS:
            out.append(f"unknown tool {g.get('tool')!r}")
        if "input_match" in g:
            try:
                js_regex(g["input_match"], "")
            except (re.error, ValueError) as e:
                out.append(f"input_match does not compile: {e}")
    if kind == "file_exists" and not str(g.get("path", "")):
        out.append("no path")
    return out


def scored(g: dict) -> bool:
    if g.get("arm") == "both":
        return True
    return g.get("arm") != "with-only" and not (g.get("type") == "tool_used" and g.get("tool") == "Skill")


def offline(g: dict) -> bool:
    """Whether this grader can be evaluated from files and the reply alone."""
    if g["type"] == "file_exists":
        return True
    return g["type"] == "regex" and g.get("target", "last_message") not in ("trace", "mock_calls", "files")


def evaluate(g: dict, work: pathlib.Path, reply: str, created: list[str]) -> bool:
    if g["type"] == "file_exists":
        hit = any(fnmatch.fnmatch(p, g["path"]) for p in created)
        return hit == g.get("exists", True)
    target = g.get("target", "last_message")
    if isinstance(target, dict):
        path = work / target["path"]
        if not path.is_file():
            return False
        text = path.read_text(errors="replace")
    else:
        text = reply
    found = js_regex(g["pattern"], g.get("flags", "")).findall(text)
    match = g.get("match", "contains")
    if match == "contains":
        return bool(found)
    if match == "not_contains":
        return not found
    return len(found) == int(match.split(":", 1)[1])


def listing(work: pathlib.Path) -> set[str]:
    return {str(p.relative_to(work)) for p in work.rglob("*")
            if p.is_file() and ".git" not in p.relative_to(work).parts}


def run_script(script: pathlib.Path, work: pathlib.Path, home: pathlib.Path) -> subprocess.CompletedProcess:
    # The same environment claude plugin eval gives a scaffold script.
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(home),
           "TMPDIR": str(home), "TERM": "dumb", "GIT_CONFIG_NOSYSTEM": "1"}
    return subprocess.run(["bash", str(script)], cwd=work, env=env, capture_output=True,
                          text=True, timeout=120)


def staged(case: dict, case_dir: pathlib.Path, tmp: pathlib.Path, label: str) -> pathlib.Path:
    work, home = tmp / label / "work", tmp / label / "home"
    work.mkdir(parents=True)
    home.mkdir(parents=True)
    script = case.get("context", {}).get("scaffold_script")
    if script:
        r = run_script(case_dir / script, work, home)
        if r.returncode != 0:
            raise RuntimeError(f"scaffold exited {r.returncode}: {r.stderr.strip()[-300:]}")
    return work


def behaviour_problems(case: dict, case_dir: pathlib.Path, tmp: pathlib.Path) -> list[str]:
    graders = [g for g in case["graders"] if offline(g)]
    if not any(scored(g) for g in graders):
        return ["no scored grader reads the reply or the files, so none can be checked here"]
    out = []
    try:
        work = staged(case, case_dir, tmp, case_dir.name + "-red")
    except RuntimeError as e:
        return [str(e)]
    if all(evaluate(g, work, "", []) for g in graders if scored(g)):
        out.append("red before fails: every scored grader already passes on the bare scaffold")
    reference, reply = case_dir / "reference.sh", case_dir / "reference-reply.md"
    if not (reference.is_file() and reply.is_file()):
        return out + ["reference.sh and reference-reply.md are required (green after)"]
    work = staged(case, case_dir, tmp, case_dir.name + "-green")
    before = listing(work)
    r = run_script(reference, work, work.parent / "home")
    if r.returncode != 0:
        return out + [f"reference.sh exited {r.returncode}: {r.stderr.strip()[-300:]}"]
    created = sorted(listing(work) - before)
    text = reply.read_text()
    out += [f"green after fails: grader {g['name']!r} fails on the reference solution"
            for g in graders if not evaluate(g, work, text, created)]
    return out


def stray_cases() -> list[str]:
    """claude plugin eval treats any prompt.md or case.yaml under the eval dir as a case."""
    found = {p.parent for name in ("prompt.md", "case.yaml") for p in EVAL_DIR.rglob(name)}
    return [f"{p.relative_to(ROOT)} is read as an eval case but is not under tests/evals/cases/<case>/"
            for p in sorted(found) if p.parent != CASE_DIR]


def main() -> int:
    for tool in ("git", "bash"):
        if shutil.which(tool) is None:
            if os.environ.get("ORCH_REQUIRE_DEPS") == "1":
                print(f"FAIL: test-eval-cases — {tool} not found (ORCH_REQUIRE_DEPS=1)")
                return 1
            print(f"SKIP: test-eval-cases ({tool} not found)")
            return 0
    fails = 0
    case_dirs = sorted(p for p in CASE_DIR.iterdir() if (p / "case.yaml").is_file())
    for problem in stray_cases():
        print(f"  FAIL {problem}")
        fails += 1
    if not case_dirs:
        print("  FAIL no cases found")
        fails += 1
    with tempfile.TemporaryDirectory() as tmp_name:
        tmp = pathlib.Path(tmp_name)
        for case_dir in case_dirs:
            try:
                case = json.loads((case_dir / "case.yaml").read_text())
            except json.JSONDecodeError as e:
                print(f"  FAIL {case_dir.name}: case.yaml is not JSON-style YAML ({e})")
                fails += 1
                continue
            problems = schema_problems(case, case_dir)
            if not problems:
                problems = behaviour_problems(case, case_dir, tmp)
            if problems:
                fails += 1
                print(f"  FAIL {case_dir.name}")
                for p in problems:
                    print(f"       - {p}")
            else:
                print(f"  ok   {case_dir.name}")
    if fails:
        print(f"FAIL test-eval-cases ({fails})")
        return 1
    print(f"PASS test-eval-cases ({len(case_dirs)} cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
