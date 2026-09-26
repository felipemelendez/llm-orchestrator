#!/usr/bin/env python3
"""No-cost checks for tests/evals/review-compare: the templates, the build, and a dry run.

The dry run puts fake `claude`, `codex` and `orch-review.py` programs in front of
the real ones, runs three arms through `review_compare.py run`, and checks that
`score` counts exactly the defects and false findings the fakes reported.
"""
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = ROOT / "tests" / "evals" / "review-compare" / "review_compare.py"
TEMPLATE = "invoice-discounts"
WORK = ROOT / "tests" / "evals" / "review-compare" / "work"

sys.dont_write_bytecode = True
sys.path.insert(0, str(TOOL.parent))
import review_compare  # noqa: E402

TREE_HASH = textwrap.dedent("""\
    def tree_hash():
        import hashlib, pathlib
        h = hashlib.sha256()
        for p in sorted(pathlib.Path('.').rglob('*')):
            if p.is_file() and '.git' not in p.parts and '__pycache__' not in p.parts:
                h.update(str(p).encode() + b'\\0' + p.read_bytes() + b'\\0')
        return h.hexdigest()
    """)

FAKE_ORCH = TREE_HASH + textwrap.dedent("""\
    import json, os, pathlib, subprocess, sys, tempfile
    args = sys.argv[1:]
    run_dir = pathlib.Path(args[args.index('--run-dir') + 1])
    # The real script refuses a run directory that exists, sits in the repository, or sits in a temp dir.
    roots = [os.environ.get('TMPDIR'), tempfile.gettempdir(), '/tmp', '/var/tmp']
    if sys.platform == 'darwin':
        roots.append(subprocess.run(['getconf', 'DARWIN_USER_TEMP_DIR'], capture_output=True, text=True).stdout.strip())
    resolved = run_dir.resolve()
    inside = lambda root: resolved == root or root in resolved.parents
    if run_dir.exists() or inside(pathlib.Path.cwd().resolve()) or any(
            inside(pathlib.Path(r).resolve()) for r in roots if r):
        sys.exit('orch-review: the run directory must be new, outside the repository and outside every temp dir')
    run_dir.mkdir(parents=True)
    plan = json.loads(pathlib.Path(os.environ['FAKE_PLAN']).read_text())[tree_hash()]['full']
    findings = [dict(f, status='verified', evidence_valid=True, reproduced=n % 2 == 0,
                     not_runnable=None, provider='codex' if n % 2 else 'claude')
                for n, f in enumerate(plan)]
    findings.append({'file': 'billing/invoice.py', 'line': 1, 'rank': 'mild', 'status': 'note', 'claim': 'x'})
    review = {'verdict': 'NOT-READY' if plan else 'READY', 'findings': findings,
              'launches': [{'cost_usd': 1.25, 'tokens': {'input_tokens': 100, 'output_tokens': 20}},
                           {'cost_usd': None, 'tokens': {'input_tokens': 50, 'cached_input_tokens': 40,
                                                         'reasoning_output_tokens': 7}}]}
    (run_dir / 'review.json').write_text(json.dumps(review))
    print(json.dumps({'status': 'finished', 'verdict': review['verdict']}))
    """)

FAKE_CLAUDE = "#!/usr/bin/env python3\n" + TREE_HASH + textwrap.dedent("""\
    import json, os, pathlib, sys
    here = pathlib.Path(__file__).resolve().parent
    with open(here / 'calls.jsonl', 'a') as log:
        log.write(json.dumps({'tool': 'claude', 'argv': sys.argv[1:], 'env': sorted(os.environ)}) + '\\n')
    plan = json.loads((here / 'plan.json').read_text())[tree_hash()]['code-review']
    # /code-review answers with a sentence or two, then its findings as a JSON array in a fenced block.
    items = [{'file': f['file'], 'line': f.get('line'), 'summary': f['claim'],
              'failure_scenario': 'More detail on what goes wrong.'} for f in plan]
    reply = (f'I found {len(items)} issues in the change to billing/invoice.py.\\n\\n'
             '```json\\n' + json.dumps(items, indent=2) + '\\n```\\n')
    print(json.dumps({'result': reply, 'total_cost_usd': 0.5,
                      'usage': {'input_tokens': 300, 'cache_read_input_tokens': 1000, 'output_tokens': 40}}))
    """)

FAKE_CODEX = "#!/usr/bin/env python3\n" + TREE_HASH + textwrap.dedent("""\
    import json, os, pathlib, sys
    here = pathlib.Path(__file__).resolve().parent
    with open(here / 'calls.jsonl', 'a') as log:
        log.write(json.dumps({'tool': 'codex', 'argv': sys.argv[1:], 'env': sorted(os.environ)}) + '\\n')
    # Refuse what codex 0.157.0 refuses: a PROMPT with --uncommitted, --base or --commit.
    args, positional, n = sys.argv[1:], [], 1
    with_value = {'-c', '--config', '--base', '--commit', '--title', '--enable', '--disable'}
    while n < len(args):
        if args[n] in with_value:
            n += 2
            continue
        if not args[n].startswith('-'):
            positional.append(args[n])
        n += 1
    target = [a for a in ('--uncommitted', '--base', '--commit') if a in args]
    if args[:1] != ['review'] or (positional and target):
        print(f"error: the argument '{target[0] if target else args[:1]}' cannot be used with '[PROMPT]'",
              file=sys.stderr)
        sys.exit(2)
    plan = json.loads((here / 'plan.json').read_text())[tree_hash()]['codex-review']
    for f in plan:
        print(f"- [P1] {f['claim']} — {f['file']}:{f['line']}-{f['line'] + 2}")
        print('  Explanation.')
    print('tokens used')
    print('12,345')
    """)


def tree_hash(root):
    h = hashlib.sha256()
    for p in sorted(root.rglob("*")):
        if p.is_file() and ".git" not in p.parts and "__pycache__" not in p.parts:
            h.update(str(p.relative_to(root)).encode() + b"\0" + p.read_bytes() + b"\0")
    return h.hexdigest()


def run(*args, env=None):
    return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True,
                          env=env, timeout=900)


class Templates(unittest.TestCase):
    def test_every_template_and_defect_is_real(self):
        result = run("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_arms_cover_the_comparison(self):
        names = {a["name"] for a in review_compare.load_arms()}
        self.assertLessEqual({"full", "code-review", "codex-review", "full-swap", "full-no-refuter",
                              "full-split", "standard-contract", "standard-adversarial"}, names)


class Build(unittest.TestCase):
    def test_build_is_deterministic_and_leaves_the_change_uncommitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = pathlib.Path(tmp, "a"), pathlib.Path(tmp, "b")
            for out in (a, b):
                result = run("build", "--out", str(out), "--template", TEMPLATE)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((a / "answer-key.json").read_text(), (b / "answer-key.json").read_text())
            key = json.loads((a / "answer-key.json").read_text())
            ids = [c["id"] for c in key["cases"]]
            self.assertIn(f"{TEMPLATE}--clean", ids)
            for case in ids:
                repo_a, repo_b = a / "cases" / case, b / "cases" / case
                head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo_a, capture_output=True, text=True)
                again = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo_b, capture_output=True, text=True)
                self.assertEqual(head.stdout, again.stdout)
                status = subprocess.run(["git", "status", "--porcelain"], cwd=repo_a, capture_output=True, text=True)
                self.assertTrue(status.stdout.strip(), f"{case} has no uncommitted change")
            planted = [d for c in key["cases"] for d in c["defects"]]
            for d in planted:
                for span in d["spans"]:
                    case = next(c for c in key["cases"] if d in c["defects"])
                    text = (a / "cases" / case["id"] / span["file"]).read_text().splitlines()
                    self.assertLessEqual(span["end"], len(text))

    def test_existing_output_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(run("build", "--out", tmp).returncode, 2)


class Parsing(unittest.TestCase):
    def test_text_findings_split_items_and_read_locations(self):
        text = ("Summary line with no location.\n"
                "1. Bug at pkg/a.py:12 when empty\n   detail\n"
                "2. Another at pkg/b.py, line 7\n"
                "- [P2] Style — pkg/c.py#L3\n"
                "- In pkg/d.py the loader skips the check\n"
                "- A remark without a file\n")
        found = review_compare.text_findings(text)
        self.assertEqual([(f["file"], f["line"]) for f in found],
                         [("pkg/a.py", 12), ("pkg/b.py", 7), ("pkg/c.py", 3), ("pkg/d.py", None)])

    def test_a_fenced_json_array_gives_one_finding_per_item(self):
        items = [{"file": "api/listing.py", "line": 40, "summary": "clamp_limit accepts limit=0",
                  "failure_scenario": "paginate(range(5), limit=0) loops forever"},
                 {"file": "api/listing.py", "line": "42", "summary": "MAX_LIMIT is never applied",
                  "failure_scenario": "limit=1000 returns every item"},
                 {"file": "tests/test_listing.py", "summary": "no test covers the cursor",
                  "failure_scenario": ""}]
        text = ("I found 3 issues in `api/listing.py` and `tests/test_listing.py`.\n\n"
                "```json\n" + json.dumps(items, indent=2) + "\n```\n")
        found = review_compare.text_findings(text)
        self.assertEqual([(f["file"], f["line"]) for f in found],
                         [("api/listing.py", 40), ("api/listing.py", 42), ("tests/test_listing.py", None)])
        self.assertIn("clamp_limit accepts limit=0", found[0]["text"])
        self.assertIn("loops forever", found[0]["text"])
        # An empty array is a review with no findings; the files named in the prose are not findings.
        self.assertEqual(review_compare.text_findings("No issues in `api/listing.py`.\n```json\n[]\n```"), [])
        # A fenced array that is not a list of findings leaves the text rule in charge.
        self.assertEqual([f["file"] for f in review_compare.text_findings("- bug in pkg/a.py:3\n```json\n[1, 2]\n```")],
                         ["pkg/a.py"])

    def test_matching_uses_file_and_nearby_lines(self):
        defect = {"symbol": "tax", "what": "Tax is charged before the discount.",
                  "spans": [{"file": "billing/invoice.py", "start": 90, "end": 91}]}
        near = lambda f, line, text="": review_compare.distance({"file": f, "line": line, "text": text}, defect)
        self.assertIsNotNone(near("billing/invoice.py", 94))
        self.assertIsNotNone(near("./billing/invoice.py", 87))
        self.assertIsNone(near("billing/invoice.py", 95))
        self.assertIsNone(near("billing/other.py", 90))
        self.assertIsNotNone(near("billing/invoice.py", None, "tax() uses the wrong base"))
        self.assertIsNone(near("billing/invoice.py", None, "taxes are fine"))

    def test_a_detection_needs_the_claim_to_describe_the_defect(self):
        defect = {"id": "d", "symbol": "discount_on", "what": "A fixed coupon larger than the subtotal makes the total negative.",
                  "spans": [{"file": "billing/invoice.py", "start": 62, "end": 62}]}
        case = {"defects": [defect]}
        def score(text, line=62):
            return review_compare.score_run({"findings": [{"file": "billing/invoice.py", "line": line, "text": text}]}, case)
        found, false, loc, _ = score("discount_on returns the full coupon value")
        self.assertTrue(found["d"])
        found, false, loc, _ = score("the coupon can exceed the subtotal, so the total goes negative")
        self.assertTrue(found["d"])
        found, false, loc, _ = score("rename this variable for clarity")
        self.assertEqual((found["d"], len(false), len(loc)), (False, 0, 1))
        found, false, loc, _ = score("rename this variable for clarity", line=30)
        self.assertEqual((found["d"], len(false), len(loc)), (False, 1, 0))

    def test_token_total_skips_cached_and_reasoning_parts(self):
        self.assertEqual(review_compare.token_total({"input_tokens": 100, "cached_input_tokens": 60,
                                                     "output_tokens": 20, "reasoning_output_tokens": 5}), 120)
        self.assertEqual(review_compare.token_total({"input_tokens": 3, "cache_read_input_tokens": 900,
                                                     "cache_creation_input_tokens": 10, "output_tokens": 2}), 15)

    def test_codex_mcp_off_names_every_configured_server(self):
        with tempfile.TemporaryDirectory() as home:
            pathlib.Path(home, "config.toml").write_text(
                'model = "x"\n[mcp_servers.slack]\ncommand = "a"\n[mcp_servers."odd name"]\ncommand = "b"\n')
            old = os.environ.get("CODEX_HOME")
            os.environ["CODEX_HOME"] = home
            try:
                argv = review_compare.codex_mcp_off()
            finally:
                if old is None:
                    del os.environ["CODEX_HOME"]
                else:
                    os.environ["CODEX_HOME"] = old
        self.assertEqual(argv, ["-c", 'mcp_servers."odd name".enabled=false', "-c", "mcp_servers.slack.enabled=false",
                                "--disable", "apps", "--disable", "plugins"])

    def test_mcnemar(self):
        self.assertEqual(review_compare.mcnemar(0, 0), 1.0)
        self.assertAlmostEqual(review_compare.mcnemar(4, 0), 0.125)
        self.assertAlmostEqual(review_compare.mcnemar(10, 2), 0.0386, places=4)


class DryRun(unittest.TestCase):
    """Three arms through `run` and `score` with fake programs; no model is called."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = pathlib.Path(self.tmp.name)
        # orch-review.py refuses a run directory in a temp dir, so results live in the ignored work folder.
        WORK.mkdir(exist_ok=True)
        self.work = tempfile.TemporaryDirectory(dir=WORK)
        self.cases, self.results = tmp / "cases", pathlib.Path(self.work.name) / "results"
        self.assertEqual(run("build", "--out", str(self.cases), "--template", TEMPLATE).returncode, 0)
        self.key = json.loads((self.cases / "answer-key.json").read_text())["cases"]
        plan = {}
        stray = {"file": "billing/invoice.py", "line": 2, "claim": "the import order is unusual", "rank": "mild"}
        for case in self.key:
            spots = [{"file": d["spans"][0]["file"], "line": d["spans"][0]["start"], "claim": d["what"],
                      "rank": "serious"} for d in case["defects"]]
            first = [dict(spots[0], line=None, claim=f"{case['defects'][0]['symbol']} is wrong")] if spots else []
            nearby = [dict(spots[0], claim="consider renaming this variable")] if spots else []
            plan[tree_hash(self.cases / "cases" / case["id"])] = {
                "full": spots + ([stray] if not case["defects"] else []),
                "code-review": first + nearby,
                "codex-review": [stray]}
        bin_dir, plugin = tmp / "bin", tmp / "plugin"
        bin_dir.mkdir()
        for place in (tmp, bin_dir):
            (place / "plan.json").write_text(json.dumps(plan))
        (plugin / "scripts" / "lib").mkdir(parents=True)
        (plugin / "scripts" / "lib" / "orch-review.py").write_text(FAKE_ORCH)
        for name, body in (("claude", FAKE_CLAUDE), ("codex", FAKE_CODEX)):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        codex_home = tmp / "codex-home"
        codex_home.mkdir()
        (codex_home / "config.toml").write_text('[mcp_servers.gmail]\ncommand = "x"\n')
        self.log = bin_dir / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}", CODEX_HOME=str(codex_home),
                        FAKE_PLAN=str(tmp / "plan.json"), AWS_SECRET_ACCESS_KEY="x")
        self.plugin = plugin

    def tearDown(self):
        self.tmp.cleanup()
        self.work.cleanup()

    def run_arms(self, *extra):
        return run("run", "--cases", str(self.cases), "--arms", "full,code-review,codex-review",
                   "--out", str(self.results), "--plugin-root", str(self.plugin), *extra, env=self.env)

    def test_scores_match_what_the_fakes_reported(self):
        result = self.run_arms()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report_path = self.results / "report.json"
        scored = run("score", "--cases", str(self.cases), "--results", str(self.results),
                     "--json", str(report_path))
        self.assertEqual(scored.returncode, 0, scored.stderr)
        report = json.loads(report_path.read_text())
        planted = sum(len(c["defects"]) for c in self.key)
        with_defects = sum(bool(c["defects"]) for c in self.key)
        tampering = sum(d["kind"] == "test-tampering" for c in self.key for d in c["defects"])
        full, native, codex = (report["arms"][n] for n in ("full", "code-review", "codex-review"))
        self.assertEqual((full["defects_found"], full["defects_planted"]), (planted, planted))
        self.assertEqual(full["by_kind"]["test-tampering"], {"found": tampering, "planted": tampering})
        self.assertEqual(full["false_findings"], 1)
        self.assertEqual((full["clean_runs_with_no_finding"], full["clean_runs"]), (0, 1))
        self.assertEqual(full["cost_usd_per_run"], 1.25)
        self.assertEqual(full["tokens_per_run"], 170)
        codex_rows = full["unverified_serious_by_provider"]["codex"]
        self.assertEqual(codex_rows["unverified"], codex_rows["real"])
        self.assertGreater(codex_rows["unverified"], 0)
        self.assertNotIn("claude", full["unverified_serious_by_provider"])
        # code-review names each case's first defect with no line, and adds an unrelated remark on its line.
        self.assertEqual(native["defects_found"], with_defects)
        self.assertEqual(native["location_only_findings"], with_defects)
        self.assertEqual(native["false_findings"], 0)
        self.assertEqual(native["cost_usd_per_run"], 0.5)
        self.assertEqual(native["tokens_per_run"], 340)
        self.assertEqual(codex["defects_found"], 0)
        self.assertEqual(codex["false_findings"], len(self.key))
        self.assertEqual(codex["tokens_per_run"], 12345)
        pair = next(p for p in report["pairs"] if {p["a"], p["b"]} == {"full", "code-review"})
        only_full = pair["a_only"] if pair["a"] == "full" else pair["b_only"]
        self.assertEqual(only_full, planted - with_defects)
        self.assertEqual(pair["p"], round(review_compare.mcnemar(planted - with_defects, 0), 4))
        pair = next(p for p in report["pairs"] if {p["a"], p["b"]} == {"code-review", "codex-review"})
        codex_more = pair["a_more_false"] if pair["a"] == "codex-review" else pair["b_more_false"]
        self.assertEqual((pair["shared_cases"], codex_more), (len(self.key), len(self.key)))
        self.assertIn("unverified serious findings from codex", scored.stdout)

    def test_every_arm_gets_the_spec_and_a_narrow_environment(self):
        self.assertEqual(self.run_arms("--case", f"{TEMPLATE}--01").returncode, 0)
        calls = {c["tool"]: c for c in map(json.loads, self.log.read_text().splitlines())}
        spec = self.key[0]["spec"]
        claude_argv = calls["claude"]["argv"]
        self.assertIn(spec, claude_argv[claude_argv.index("--append-system-prompt") + 1])
        codex_argv = calls["codex"]["argv"]
        notes = [v for v in codex_argv if v.startswith("developer_instructions=")]
        self.assertEqual(len(notes), 1)
        self.assertIn(spec, json.loads(notes[0].split("=", 1)[1]))
        self.assertIn("mcp_servers.gmail.enabled=false", codex_argv)
        self.assertIn("--uncommitted", codex_argv)
        for tool in ("claude", "codex"):
            self.assertNotIn("AWS_SECRET_ACCESS_KEY", calls[tool]["env"])
            self.assertNotIn("FAKE_PLAN", calls[tool]["env"])

    def test_finished_runs_are_skipped_and_the_cost_cap_stops_new_ones(self):
        first = self.run_arms("--case", f"{TEMPLATE}--01", "--max-cost-usd", "1")
        self.assertEqual(first.returncode, 3, first.stdout + first.stderr)
        self.assertIn("reached --max-cost-usd", first.stdout)
        again = self.run_arms("--case", f"{TEMPLATE}--01")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(again.stdout.count("try 1"), 2, again.stdout)

    def test_unavailable_unknown_and_unbuilt_arms_are_refused(self):
        for arm in ("full-effort-unset", "no-such-arm"):
            result = run("run", "--cases", str(self.cases), "--arms", arm, "--out", str(self.results))
            self.assertEqual(result.returncode, 2, arm)
        missing = run("run", "--cases", str(self.cases), "--arms", "full", "--out", str(self.results),
                      "--plugin-root", self.tmp.name, env=self.env)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("T5", missing.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=1)
