#!/usr/bin/env python3
"""Compare review arms on the same small changes with planted defects.

  build  write the case repositories and the answer key (free)
  check  prove every template and planted defect is real (free)
  run    run the chosen arms on the built cases (PAID: each run is a real review)
  score  score the runs against the answer key and compare arms (free)

A case is one template's change, clean or with one or two planted defects,
left uncommitted on top of the template's base commit. The answer key names
each defect's file and changed lines. See tests/evals/README.md.
"""
from __future__ import annotations

import argparse
import difflib
import fnmatch
import json
import math
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
TEMPLATES = HERE / "templates"
ARMS_FILE = HERE / "arms.json"
PLUGIN_ROOT = HERE.parents[2]
RANKS = ("serious", "mild")
KINDS = ("defect", "test-tampering")
LINE_SLACK = 3
# A git identity and date so every build of a case has the same commit.
GIT_ENV = {"GIT_AUTHOR_NAME": "Dev", "GIT_AUTHOR_EMAIL": "dev@example.com",
           "GIT_COMMITTER_NAME": "Dev", "GIT_COMMITTER_EMAIL": "dev@example.com",
           "GIT_AUTHOR_DATE": "2026-01-05T10:00:00Z", "GIT_COMMITTER_DATE": "2026-01-05T10:00:00Z",
           "GIT_CONFIG_NOSYSTEM": "1"}


# ---------------------------------------------------------------- templates


def load_templates(only=None):
    out = []
    for path in sorted(p for p in TEMPLATES.iterdir() if (p / "template.json").is_file()):
        if only and not any(fnmatch.fnmatch(path.name, g) for g in only):
            continue
        meta = json.loads((path / "template.json").read_text())
        meta["name"], meta["dir"] = path.name, path
        out.append(meta)
    return out


def tree(root):
    return {str(p.relative_to(root)): p.read_text() for p in sorted(root.rglob("*"))
            if p.is_file() and "__pycache__" not in p.parts}


def clean_files(template):
    files = tree(template["dir"] / "base")
    files.update(tree(template["dir"] / "after"))
    return files


def apply_edits(files, defect):
    """Apply one defect's edits; return the new files and the 1-based line ranges it touched."""
    files = dict(files)
    spans = []
    for edit in defect["edits"]:
        text = files[edit["file"]]
        if text.count(edit["find"]) != 1:
            raise ValueError(f"{defect['id']}: find text occurs {text.count(edit['find'])} times "
                             f"in {edit['file']}, not once")
        start = text.index(edit["find"])
        first = text.count("\n", 0, start) + 1
        last = first + max(edit["replace"].count("\n"), 0)
        files[edit["file"]] = text[:start] + edit["replace"] + text[start + len(edit["find"]):]
        spans.append({"file": edit["file"], "start": first, "end": last})
    return files, spans


def plan_cases(template):
    """Group the template's defects into cases of at most two, in listed order."""
    groups, pending = [], []
    for defect in template["defects"]:
        if defect.get("alone"):
            groups.append([defect])
            continue
        pending.append(defect)
        if len(pending) == 2:
            groups.append(pending)
            pending = []
    if pending:
        groups.append(pending)
    cases = [{"id": f"{template['name']}--clean", "defects": []}]
    for n, group in enumerate(groups, 1):
        cases.append({"id": f"{template['name']}--{n:02d}", "defects": group})
    return cases


def case_files(template, case):
    files = clean_files(template)
    located = []
    for defect in case["defects"]:
        before = files
        files, spans = apply_edits(files, defect)
        # A later edit above an earlier defect's lines moves those lines by its change in line count.
        for edit, span in zip(defect["edits"], spans):
            delta = files[edit["file"]].count("\n") - before[edit["file"]].count("\n")
            for d in located:
                for old in d["spans"]:
                    if old["file"] == edit["file"] and old["start"] > span["start"]:
                        old["start"] += delta
                        old["end"] += delta
        located.append({"id": f"{template['name']}/{defect['id']}", "rank": defect["rank"],
                        "kind": defect["kind"], "symbol": defect["symbol"], "what": defect["what"],
                        "spans": spans})
    return files, located


def changed_lines(before, after):
    """1-based line numbers of `after` that differ from `before`."""
    lines = set()
    matcher = difflib.SequenceMatcher(None, before.splitlines(), after.splitlines(), autojunk=False)
    for op, _, _, j1, j2 in matcher.get_opcodes():
        if op in ("replace", "insert"):
            lines.update(range(j1 + 1, j2 + 1))
    return lines


def diff_size(template):
    base = tree(template["dir"] / "base")
    total = 0
    for name, text in clean_files(template).items():
        old = base.get(name, "")
        matcher = difflib.SequenceMatcher(None, old.splitlines(), text.splitlines(), autojunk=False)
        total += sum(max(i2 - i1, j2 - j1) for op, i1, i2, j1, j2 in matcher.get_opcodes() if op != "equal")
    return total


def git(cwd, *args):
    env = dict(os.environ, **GIT_ENV)
    return subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True, text=True).stdout


def write_files(root, files):
    for name, text in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def make_repo(root, template, files):
    """Commit the template's base, then leave `files` as the uncommitted change."""
    root.mkdir(parents=True)
    git(root, "init", "-q", "-b", "main")
    write_files(root, tree(template["dir"] / "base"))
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "Initial version")
    write_files(root, files)


def command_build(args):
    out = pathlib.Path(args.out).resolve()
    if out.exists():
        print(f"review_compare: {out} already exists", file=sys.stderr)
        return 2
    key = {"cases": []}
    for template in load_templates(args.template):
        for case in plan_cases(template):
            files, located = case_files(template, case)
            make_repo(out / "cases" / case["id"], template, files)
            key["cases"].append({"id": case["id"], "template": template["name"],
                                 "spec": template["spec"], "test_command": template["test_command"],
                                 "diff_lines": diff_size(template), "defects": located})
    (out / "answer-key.json").write_text(json.dumps(key, indent=2) + "\n")
    defects = sum(len(c["defects"]) for c in key["cases"])
    print(f"built {len(key['cases'])} cases with {defects} planted defects in {out}")
    return 0


# ---------------------------------------------------------------- check


def run_in(root, command, timeout=120):
    return subprocess.run(command, cwd=root, shell=True, capture_output=True, text=True, timeout=timeout,
                          env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"))


def template_problems(template, tmp):
    out = []
    for key in ("title", "spec", "test_command", "defects"):
        if key not in template:
            out.append(f"template.json has no {key!r}")
    if out:
        return out
    base = tree(template["dir"] / "base")
    clean = clean_files(template)
    if template["spec"] not in base:
        out.append(f"spec {template['spec']} is not in base/")
    if not (template["dir"] / "heldout.py").is_file():
        return out + ["no heldout.py"]
    heldout = f"{sys.executable} {template['dir'] / 'heldout.py'}"

    def verdicts(files, label):
        root = tmp / f"{template['name']}-{label}"
        write_files(root, files)
        return (run_in(root, template["test_command"]).returncode == 0,
                run_in(root, heldout).returncode == 0)

    if verdicts(base, "base")[0] is not True:
        out.append("the visible tests fail on base")
    tests_ok, heldout_ok = verdicts(clean, "clean")
    if not tests_ok:
        out.append("the visible tests fail on the clean change")
    if not heldout_ok:
        out.append("the held-out check fails on the clean change")
    ids = [d.get("id") for d in template["defects"]]
    if len(set(ids)) != len(ids):
        out.append("defect ids are not unique")
    for defect in template["defects"]:
        label = defect.get("id", "?")
        missing = {"id", "rank", "kind", "symbol", "what", "edits"} - set(defect)
        if missing:
            out.append(f"{label}: missing {sorted(missing)}")
            continue
        if defect["rank"] not in RANKS or defect["kind"] not in KINDS:
            out.append(f"{label}: rank must be one of {RANKS} and kind one of {KINDS}")
        try:
            files, spans = apply_edits(clean, defect)
        except (KeyError, ValueError) as e:
            out.append(f"{label}: {e}")
            continue
        for edit, span in zip(defect["edits"], spans):
            if edit["replace"] and files[edit["file"]].count(edit["replace"]) != 1:
                out.append(f"{label}: the replacement text must occur once in {edit['file']}, "
                           "so the answer key can find its lines")
            touched = changed_lines(base.get(edit["file"], ""), clean[edit["file"]])
            first = clean[edit["file"]].count("\n", 0, clean[edit["file"]].index(edit["find"])) + 1
            last = first + edit["find"].count("\n")
            if not set(range(first, last + 1)) & touched:
                out.append(f"{label}: the edit in {edit['file']} is outside the lines the change touches")
        tests_ok, heldout_ok = verdicts(files, label)
        if not tests_ok:
            out.append(f"{label}: the visible tests catch it; a planted defect must pass the committed tests")
        if heldout_ok:
            out.append(f"{label}: the held-out check still passes, so it is not a defect")
    for case in plan_cases(template):
        if len(case["defects"]) < 2:
            continue
        try:
            files, _ = case_files(template, case)
        except (KeyError, ValueError) as e:
            out.append(f"{case['id']}: the two defects do not apply together ({e})")
            continue
        if not verdicts(files, case["id"])[0]:
            out.append(f"{case['id']}: the visible tests fail with both defects")
    return out


def command_check(args):
    templates = load_templates(args.template)
    fails = 0
    with tempfile.TemporaryDirectory() as tmp_name:
        for template in templates:
            problems = template_problems(template, pathlib.Path(tmp_name))
            fails += bool(problems)
            print(("  FAIL " if problems else "  ok   ") + template["name"])
            for p in problems:
                print(f"       - {p}")
    defects = [d for t in templates for d in t["defects"]]
    large = [t["name"] for t in templates if diff_size(t) > 150]
    print(f"{len(templates)} templates, {len(defects)} planted defects, "
          f"{len(templates)} clean cases, {len(large)} changes over 150 lines")
    for name, minimum in (("defects", args.min_defects), ("large", args.min_large)):
        count = len(defects) if name == "defects" else len(large)
        if count < minimum:
            print(f"  FAIL {count} {name}; at least {minimum} are needed")
            fails += 1
    return 1 if fails else 0


# ---------------------------------------------------------------- run


# Every arm gets this sentence, or (for orch-review.py) the same spec file through --spec.
SPEC_NOTE = ("The change must implement the spec in {spec}. Read it, and report every place where the "
             "change does not meet it, as well as any other defect.")
BASE_ENV = ("PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ",
            "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME")
PROVIDER_ENV = {
    "claude": ("CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
               "CLAUDE_CODE_OAUTH_TOKEN"),
    "codex": ("CODEX_HOME", "OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL"),
}


def load_arms():
    return json.loads(ARMS_FILE.read_text())["arms"]


def codex_home():
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex")


def codex_mcp_off():
    """Arguments that turn off every MCP server in config.toml, and the apps and plugins features,
    as orch-review.py does for its Codex seat."""
    import tomllib
    try:
        servers = tomllib.loads((codex_home() / "config.toml").read_text()).get("mcp_servers") or {}
    except (OSError, tomllib.TOMLDecodeError):
        servers = {}
    argv = []
    for name in sorted(servers):
        key = name if re.fullmatch(r"[A-Za-z0-9_-]+", name) else json.dumps(name)
        argv += ["-c", f"mcp_servers.{key}.enabled=false"]
    return argv + ["--disable", "apps", "--disable", "plugins"]


def expand(argv, values):
    out = []
    for part in argv:
        if part == "{codex_mcp_off}":
            out += codex_mcp_off()
        else:
            out.append(part.format(**values))
    return out


def arm_env(arm, out_dir):
    """orch-review.py narrows each seat's environment itself; the native arms get the same narrowing."""
    if arm["provider"] == "orch-review":
        env = dict(os.environ)
    else:
        keep = BASE_ENV + PROVIDER_ENV[arm["provider"]]
        env = {k: os.environ[k] for k in keep if k in os.environ}
    if arm["provider"] == "codex":
        # At codex_otel=info, codex logs the MCP servers it started.
        env["RUST_LOG"] = "warn,codex_otel=info"
    # orch-review.py appends its outcome rows under XDG_STATE_HOME; keep them out of the real log.
    env["XDG_STATE_HOME"] = str(out_dir / "state")
    return env


def codex_mcp_started(stderr):
    """The MCP servers codex started, from its conversation_starts log line, or None when absent."""
    for line in stderr.splitlines():
        if 'event.name="codex.conversation_starts"' in line:
            match = re.search(r'mcp_servers="([^"]*)"', line)
            if match:
                return [n.strip() for n in match[1].split(",") if n.strip()]
    return None


def run_one(arm, case, repo_src, out_dir, plugin_root, timeout):
    """Run one arm on a fresh copy of one case; write meta.json and the arm's output."""
    work = pathlib.Path(tempfile.mkdtemp(prefix="review-compare-"))
    repo = work / "repo"
    shutil.copytree(repo_src, repo, symlinks=True)
    review_dir = work / "review"
    values = {"plugin": str(plugin_root), "spec": case["spec"], "run_dir": str(review_dir),
              "python": sys.executable, "spec_note": SPEC_NOTE.format(spec=case["spec"])}
    # A TOML string for `codex -c`; codex 0.157.0 refuses a PROMPT together with --uncommitted.
    values["spec_note_toml"] = json.dumps(values["spec_note"])
    started = time.time()
    try:
        proc = subprocess.run(expand(arm["command"], values), cwd=repo, env=arm_env(arm, out_dir),
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        code, stdout, stderr = proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired as e:
        code, stdout, stderr = "timeout", e.stdout or "", e.stderr or ""
        stdout = stdout.decode() if isinstance(stdout, bytes) else stdout
        stderr = stderr.decode() if isinstance(stderr, bytes) else stderr
    seconds = round(time.time() - started, 1)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "stdout.txt").write_text(stdout)
    (out_dir / "stderr.txt").write_text(stderr[-20000:])
    if (review_dir / "review.json").is_file():
        shutil.copy(review_dir / "review.json", out_dir / "review.json")
    meta = {"arm": arm["name"], "case": case["id"], "exit": code, "seconds": seconds}
    if arm["provider"] == "codex":
        meta["mcp_servers"] = codex_mcp_started(stderr)
    (out_dir / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
    shutil.rmtree(work, ignore_errors=True)
    return meta


def command_run(args):
    built = pathlib.Path(args.cases).resolve()
    key = json.loads((built / "answer-key.json").read_text())
    arms = {a["name"]: a for a in load_arms()}
    chosen = args.arms.split(",")
    for name in chosen:
        if name not in arms:
            print(f"review_compare: unknown arm {name!r}; see arms.json", file=sys.stderr)
            return 2
        if arms[name].get("unavailable"):
            print(f"review_compare: arm {name!r} cannot run: {arms[name]['unavailable']}", file=sys.stderr)
            return 2
    plugin_root = pathlib.Path(args.plugin_root).resolve()
    if any(arms[n]["provider"] == "orch-review" for n in chosen) \
            and not (plugin_root / "scripts" / "lib" / "orch-review.py").is_file():
        print(f"review_compare: {plugin_root}/scripts/lib/orch-review.py does not exist; "
              "the orch-review arms need the review script (ticket T5) merged", file=sys.stderr)
        return 2
    cases = [c for c in key["cases"] if not args.case or any(fnmatch.fnmatch(c["id"], g) for g in args.case)]
    if args.large_only:
        cases = [c for c in cases if c["diff_lines"] > 150]
    results = pathlib.Path(args.out).resolve()
    spent = 0.0
    for case in cases:
        for name in chosen:
            for attempt in range(1, args.tries + 1):
                out_dir = results / "runs" / case["id"] / name / str(attempt)
                if (out_dir / "meta.json").is_file():
                    spent += cost_of(read_run(out_dir, arms[name]))
                    continue
                if args.max_cost_usd is not None and spent >= args.max_cost_usd:
                    print(f"stopped: reported cost ${spent:.2f} reached --max-cost-usd; "
                          "run the same command again later to continue")
                    return 3
                meta = run_one(arms[name], case, built / "cases" / case["id"], out_dir, plugin_root, args.timeout)
                run = read_run(out_dir, arms[name])
                spent += cost_of(run)
                print(f"  {case['id']:<34} {name:<22} try {attempt}  exit {meta['exit']}  "
                      f"{meta['seconds']:>6.0f}s  findings {len(run['findings'])}  "
                      f"cost {fmt_cost(run['cost_usd'])}")
    print(f"done; reported cost ${spent:.2f}")
    return 0


# ---------------------------------------------------------------- parse arm output


FILE = re.compile(r"(?P<file>[\w./-]*[\w-]+\.(?:py|md|json|toml|ya?ml|txt|csv|cfg|ini))\b"
                  r"(?:(?::|,? lines? |#L)(?P<line>\d+))?")


def text_findings(text):
    """Split free-text review output into findings: one per list item or heading that names a file."""
    blocks, current = [], []
    starts = re.compile(r"^\s*(?:[-*•]|\d+[.)]|#{1,6}\s|\[P\d\]|\*\*\d)")
    for line in text.splitlines():
        if starts.match(line) and current:
            blocks.append("\n".join(current))
            current = []
        current.append(line)
    if current:
        blocks.append("\n".join(current))
    out = []
    for block in blocks:
        located = [m for m in FILE.finditer(block)]
        if not located:
            continue
        match = next((m for m in located if m["line"]), located[0])
        out.append({"file": match["file"], "line": int(match["line"]) if match["line"] else None,
                    "text": block.strip()[:1000]})
    return out


def token_total(usage):
    """Tokens not read from a cache. Cached input and reasoning output are parts of the input and
    output counts in Codex usage, so adding them would count those tokens twice."""
    skip = ("cached", "cache_read", "reasoning")
    values = [v for k, v in (usage or {}).items() if isinstance(v, int) and not any(s in k for s in skip)]
    return sum(values) or None


def parse_claude_json(stdout):
    try:
        result = json.loads(stdout)
    except json.JSONDecodeError:
        return "", None, None
    if result.get("is_error"):
        return "", result.get("total_cost_usd"), None
    usage = {k: v for k, v in (result.get("usage") or {}).items() if k.endswith("_tokens")}
    return str(result.get("result") or ""), result.get("total_cost_usd"), token_total(usage)


def parse_codex_text(stdout):
    match = re.search(r"tokens used\s*[:\n]\s*([\d,]+)", stdout, re.I)
    return stdout, None, int(match[1].replace(",", "")) if match else None


def unverified(finding):
    """Serious or worse, and the script could not back it: bad evidence, or not reproduced."""
    if finding.get("rank") == "mild":
        return False
    backed = finding.get("reproduced") or finding.get("not_runnable")
    return not (finding.get("evidence_valid") and backed)


def read_run(out_dir, arm):
    meta = json.loads((out_dir / "meta.json").read_text())
    stdout = (out_dir / "stdout.txt").read_text() if (out_dir / "stdout.txt").is_file() else ""
    run = {"meta": meta, "complete": meta["exit"] == 0, "findings": [], "cost_usd": None,
           "tokens": None, "verdict": None}
    if meta.get("mcp_servers"):
        run["complete"] = False
    if arm["output"] == "review-json":
        path = out_dir / "review.json"
        if not path.is_file():
            run["complete"] = False
            return run
        review = json.loads(path.read_text())
        run["verdict"] = review.get("verdict")
        run["complete"] = run["complete"] and review.get("verdict") != "INCOMPLETE"
        launches = review.get("launches", [])
        costs = [l.get("cost_usd") for l in launches if isinstance(l.get("cost_usd"), (int, float))]
        run["cost_usd"] = round(sum(costs), 4) if costs else None
        run["tokens"] = sum(token_total(l.get("tokens")) or 0 for l in launches) or None
        for f in review.get("findings", []):
            if f.get("status") in ("note", "dropped"):
                continue
            line = f.get("line")
            run["findings"].append({"file": f.get("file") or "", "line": line if isinstance(line, int) else None,
                                    "text": str(f.get("claim") or "")[:1000], "rank": f.get("rank"),
                                    "provider": f.get("provider"), "unverified": unverified(f)})
        return run
    if arm["output"] == "claude-json":
        text, run["cost_usd"], run["tokens"] = parse_claude_json(stdout)
    else:
        text, run["cost_usd"], run["tokens"] = parse_codex_text(stdout)
    run["findings"] = text_findings(text)
    if not text.strip():
        run["complete"] = False
    return run


def cost_of(run):
    return run["cost_usd"] or 0.0


def fmt_cost(value):
    return "n/a" if value is None else f"${value:.2f}"


# ---------------------------------------------------------------- score


STOP = set("""a an and are as at be by for from in into is it its not of on or the this that to was
with when which while without than then there their them they one two its does do can cannot never
only instead same other""".split())


def stems(text):
    return {w[:5] for w in re.findall(r"[a-z]+", text.lower()) if len(w) >= 4 and w not in STOP}


def same_file(reported, planted):
    reported = reported.lstrip("./")
    return reported == planted or reported.endswith("/" + planted) or planted.endswith("/" + reported)


def distance(finding, defect):
    """How far `finding` is from `defect` in lines, or None when it does not point at it. A finding
    with no line points at a defect in its file when it names the defect's symbol, in every arm."""
    best = None
    for span in defect["spans"]:
        if not same_file(finding["file"], span["file"]):
            continue
        if finding["line"] is None:
            gap = LINE_SLACK if re.search(rf"\b{re.escape(defect['symbol'])}\b", finding["text"]) else None
        else:
            gap = max(span["start"] - finding["line"], finding["line"] - span["end"], 0)
            gap = gap if gap <= LINE_SLACK else None
        if gap is not None:
            best = gap if best is None else min(best, gap)
    return best


def claim_matches(finding, defect):
    """The finding says what the defect is: it names the symbol, or shares two content words with the
    defect's description."""
    if re.search(rf"\b{re.escape(defect['symbol'])}\b", finding["text"]):
        return True
    return len(stems(finding["text"]) & stems(defect["what"])) >= 2


def score_run(run, case):
    """Credit each finding to the nearest defect it points at and describes. A finding that points at a
    defect but describes something else is location-only; one that points at none is false."""
    found = {d["id"]: False for d in case["defects"]}
    false, location_only, credited = [], [], []
    for finding in run["findings"]:
        near = sorted((distance(finding, d), n, d) for n, d in enumerate(case["defects"])
                      if distance(finding, d) is not None)
        described = [d for _, _, d in near if claim_matches(finding, d)]
        if described:
            found[described[0]["id"]] = True
            credited.append((finding, described[0]))
        elif near:
            location_only.append(finding)
        else:
            false.append(finding)
    return found, false, location_only, credited


def mcnemar(b, c):
    """Exact two-sided McNemar p-value from the discordant counts b and c."""
    n = b + c
    if n == 0:
        return 1.0
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def share(found, planted):
    return {"found": found, "planted": planted}


def command_score(args):
    built = pathlib.Path(args.cases).resolve()
    key = {c["id"]: c for c in json.loads((built / "answer-key.json").read_text())["cases"]}
    arms = {a["name"]: a for a in load_arms()}
    results = pathlib.Path(args.results).resolve()
    per_arm = {}
    for run_dir in sorted(results.glob("runs/*/*/*")):
        case_id, arm_name, attempt = run_dir.parts[-3:]
        if case_id not in key or arm_name not in arms or not (run_dir / "meta.json").is_file():
            continue
        run = read_run(run_dir, arms[arm_name])
        entry = per_arm.setdefault(arm_name, {"runs": [], "found": {}, "false": {}, "incomplete": 0})
        if not run["complete"]:
            entry["incomplete"] += 1
        found, false, location_only, credited = score_run(run, key[case_id])
        entry["runs"].append({"case": case_id, "attempt": int(attempt), "complete": run["complete"],
                              "found": found, "false": false, "location_only": location_only,
                              "credited": credited, "findings": run["findings"], "cost_usd": run["cost_usd"],
                              "tokens": run["tokens"], "seconds": run["meta"]["seconds"],
                              "clean": not key[case_id]["defects"]})
        if int(attempt) == 1 and run["complete"]:
            entry["found"].update(found)
            entry["false"][case_id] = len(false)
    defects = {d["id"]: d for c in key.values() for d in c["defects"]}
    report = {"arms": {}, "pairs": []}
    for name, entry in sorted(per_arm.items()):
        complete = [r for r in entry["runs"] if r["complete"]]
        planted = [(d, r["found"][d]) for r in complete for d in r["found"]]
        costs = [r["cost_usd"] for r in complete if r["cost_usd"] is not None]
        tokens = [r["tokens"] for r in complete if r["tokens"] is not None]
        clean = [r for r in complete if r["clean"]]
        real = {id(f) for r in complete for f, _ in r["credited"]}
        unverified_by = {}
        for r in complete:
            for f in r["findings"]:
                if f.get("unverified"):
                    row = unverified_by.setdefault(f.get("provider") or "unknown", {"unverified": 0, "real": 0})
                    row["unverified"] += 1
                    row["real"] += id(f) in real
        false_count = sum(len(r["false"]) for r in complete)
        report["arms"][name] = {
            "runs": len(entry["runs"]), "incomplete": entry["incomplete"],
            "defects_found": sum(hit for _, hit in planted), "defects_planted": len(planted),
            "by_rank": {rank: share(sum(h for d, h in planted if defects[d]["rank"] == rank),
                                    sum(defects[d]["rank"] == rank for d, _ in planted)) for rank in RANKS},
            "by_kind": {kind: share(sum(h for d, h in planted if defects[d]["kind"] == kind),
                                    sum(defects[d]["kind"] == kind for d, _ in planted)) for kind in KINDS},
            "false_findings": false_count,
            "false_per_run": round(false_count / len(complete), 2) if complete else None,
            "location_only_findings": sum(len(r["location_only"]) for r in complete),
            "clean_runs_with_no_finding": sum(not r["false"] for r in clean), "clean_runs": len(clean),
            "unverified_serious_by_provider": unverified_by,
            "cost_usd_total": round(sum(costs), 2) if costs else None,
            "cost_usd_per_run": round(sum(costs) / len(costs), 2) if costs else None,
            "tokens_per_run": round(sum(tokens) / len(tokens)) if tokens else None,
            "minutes_per_run": round(sum(r["seconds"] for r in complete) / len(complete) / 60, 1) if complete else None,
        }
    names = sorted(per_arm)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            fa, fb = per_arm[a]["found"], per_arm[b]["found"]
            shared = fa.keys() & fb.keys()
            only_a = sum(fa[d] and not fb[d] for d in shared)
            only_b = sum(fb[d] and not fa[d] for d in shared)
            xa, xb = per_arm[a]["false"], per_arm[b]["false"]
            cases = xa.keys() & xb.keys()
            more_a = sum(xa[c] > xb[c] for c in cases)
            more_b = sum(xb[c] > xa[c] for c in cases)
            report["pairs"].append({
                "a": a, "b": b, "shared_defects": len(shared), "a_only": only_a, "b_only": only_b,
                "p": round(mcnemar(only_a, only_b), 4),
                "shared_cases": len(cases), "a_more_false": more_a, "b_more_false": more_b,
                "p_false": round(mcnemar(more_a, more_b), 4)})
    if args.json:
        pathlib.Path(args.json).write_text(json.dumps(report, indent=2) + "\n")
    print_report(report)
    return 0


def print_report(report):
    def cell(value):
        return "-" if value is None else value

    print(f"{'ARM':<22} {'FOUND':>9} {'SERIOUS':>9} {'MILD':>9} {'TAMPER':>7} {'FALSE':>6} {'FALSE/RUN':>9} "
          f"{'LOC-ONLY':>8} {'CLEAN OK':>9} {'$/RUN':>7} {'TOKENS':>8} {'MIN':>5} {'INCOMPLETE':>10}")
    for name, a in report["arms"].items():
        ser, mild, tamper = a["by_rank"]["serious"], a["by_rank"]["mild"], a["by_kind"]["test-tampering"]
        print(f"{name:<22} {a['defects_found']:>4}/{a['defects_planted']:<4} "
              f"{ser['found']:>4}/{ser['planted']:<4} {mild['found']:>4}/{mild['planted']:<4} "
              f"{tamper['found']:>3}/{tamper['planted']:<3} "
              f"{a['false_findings']:>6} {cell(a['false_per_run']):>9} {a['location_only_findings']:>8} "
              f"{a['clean_runs_with_no_finding']:>4}/{a['clean_runs']:<4} "
              f"{cell(a['cost_usd_per_run']):>7} {cell(a['tokens_per_run']):>8} "
              f"{cell(a['minutes_per_run']):>5} {a['incomplete']:>10}")
        for provider, row in sorted(a["unverified_serious_by_provider"].items()):
            print(f"    unverified serious findings from {provider}: {row['unverified']}, "
                  f"of which {row['real']} matched a planted defect")
    for p in report["pairs"]:
        print(f"McNemar {p['a']} vs {p['b']}: {p['shared_defects']} shared defects, "
              f"{p['a_only']} found only by {p['a']}, {p['b_only']} only by {p['b']}, p = {p['p']}")
        print(f"  false findings on {p['shared_cases']} shared cases: {p['a']} more on {p['a_more_false']}, "
              f"{p['b']} more on {p['b_more_false']}, p = {p['p_false']}")


# ---------------------------------------------------------------- main


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="write the case repositories and answer key")
    build.add_argument("--out", required=True, help="a new directory")
    build.add_argument("--template", action="append", help="template name glob (repeatable)")
    check = sub.add_parser("check", help="check every template and planted defect")
    check.add_argument("--template", action="append", help="template name glob (repeatable)")
    check.add_argument("--min-defects", type=int, default=100)
    check.add_argument("--min-large", type=int, default=3)
    run = sub.add_parser("run", help="PAID: run arms on built cases")
    run.add_argument("--cases", required=True, help="the directory build wrote")
    run.add_argument("--arms", required=True, help="comma-separated arm names from arms.json")
    run.add_argument("--out", required=True, help="results directory; finished runs are skipped")
    run.add_argument("--case", action="append", help="case id glob (repeatable)")
    run.add_argument("--large-only", action="store_true", help="only changes over 150 lines")
    run.add_argument("--tries", type=int, default=1)
    run.add_argument("--timeout", type=int, default=3600, help="seconds per run")
    run.add_argument("--max-cost-usd", type=float, help="stop starting runs once reported cost reaches this")
    run.add_argument("--plugin-root", default=str(PLUGIN_ROOT))
    score = sub.add_parser("score", help="score runs against the answer key")
    score.add_argument("--cases", required=True)
    score.add_argument("--results", required=True)
    score.add_argument("--json", help="also write the report here")
    args = parser.parse_args(argv)
    return {"build": command_build, "check": command_check, "run": command_run,
            "score": command_score}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
