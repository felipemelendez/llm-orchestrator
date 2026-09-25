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
    import json, os, pathlib, sys
    args = sys.argv[1:]
    run_dir = pathlib.Path(args[args.index('--run-dir') + 1])
    run_dir.mkdir(parents=True)
    plan = json.loads(pathlib.Path(os.environ['FAKE_PLAN']).read_text())[tree_hash()]['full']
    findings = [dict(f, rank='serious', status='verified', claim='wrong result') for f in plan]
    findings.append({'file': 'billing/invoice.py', 'line': 1, 'rank': 'mild', 'status': 'note', 'claim': 'x'})
    review = {'verdict': 'NOT-READY' if plan else 'READY', 'findings': findings,
              'launches': [{'cost_usd': 1.25, 'tokens': {'input': 100, 'output': 20}},
                           {'cost_usd': None, 'tokens': {'input': 50}}]}
    (run_dir / 'review.json').write_text(json.dumps(review))
    print(json.dumps({'status': 'finished', 'verdict': review['verdict']}))
    """)

FAKE_CLAUDE = "#!/usr/bin/env python3\n" + TREE_HASH + textwrap.dedent("""\
    import json, os, pathlib
    plan = json.loads(pathlib.Path(os.environ['FAKE_PLAN']).read_text())[tree_hash()]['code-review']
    shapes = ['{file}:{line}', '{file}, line {line}', '{file}#L{line}']
    lines = ['## Code review', '']
    for n, f in enumerate(plan):
        lines.append(f'{n + 1}. **Bug** in ' + shapes[n % 3].format(**f) + ': wrong result')
        lines.append('   More detail on a second line.')
    print(json.dumps({'result': '\\n'.join(lines) or 'No issues found.', 'total_cost_usd': 0.5,
                      'usage': {'input_tokens': 300, 'output_tokens': 40}}))
    """)

FAKE_CODEX = "#!/usr/bin/env python3\n" + TREE_HASH + textwrap.dedent("""\
    import json, os, pathlib
    plan = json.loads(pathlib.Path(os.environ['FAKE_PLAN']).read_text())[tree_hash()]['codex-review']
    for f in plan:
        print(f"- [P1] Possible issue — {f['file']}:{f['line']}-{f['line'] + 2}")
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
                "- A remark without a file\n")
        found = review_compare.text_findings(text)
        self.assertEqual([(f["file"], f["line"]) for f in found], [("pkg/a.py", 12), ("pkg/b.py", 7), ("pkg/c.py", 3)])

    def test_matching_uses_file_and_nearby_lines(self):
        defect = {"symbol": "tax", "spans": [{"file": "billing/invoice.py", "start": 90, "end": 91}]}
        hit = lambda f, line, text="": review_compare.matches({"file": f, "line": line, "text": text}, defect)
        self.assertTrue(hit("billing/invoice.py", 94))
        self.assertTrue(hit("./billing/invoice.py", 87))
        self.assertFalse(hit("billing/invoice.py", 95))
        self.assertFalse(hit("billing/other.py", 90))
        self.assertTrue(hit("billing/invoice.py", None, "tax() uses the wrong base"))
        self.assertFalse(hit("billing/invoice.py", None, "taxes are fine"))

    def test_mcnemar(self):
        self.assertEqual(review_compare.mcnemar(0, 0), 1.0)
        self.assertAlmostEqual(review_compare.mcnemar(4, 0), 0.125)
        self.assertAlmostEqual(review_compare.mcnemar(10, 2), 0.0386, places=4)


class DryRun(unittest.TestCase):
    """Three arms through `run` and `score` with fake programs; no model is called."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = pathlib.Path(self.tmp.name)
        self.cases, self.results = tmp / "cases", tmp / "results"
        self.assertEqual(run("build", "--out", str(self.cases), "--template", TEMPLATE).returncode, 0)
        self.key = json.loads((self.cases / "answer-key.json").read_text())["cases"]
        plan = {}
        for case in self.key:
            spots = [{"file": d["spans"][0]["file"], "line": d["spans"][0]["start"]} for d in case["defects"]]
            stray = {"file": "billing/invoice.py", "line": 2}
            plan[tree_hash(self.cases / "cases" / case["id"])] = {
                "full": spots + ([stray] if not case["defects"] else []),
                "code-review": spots[:1],
                "codex-review": [stray]}
        (tmp / "plan.json").write_text(json.dumps(plan))
        bin_dir, plugin = tmp / "bin", tmp / "plugin"
        (plugin / "scripts" / "lib").mkdir(parents=True)
        (plugin / "scripts" / "lib" / "orch-review.py").write_text(FAKE_ORCH)
        bin_dir.mkdir()
        for name, body in (("claude", FAKE_CLAUDE), ("codex", FAKE_CODEX)):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                        FAKE_PLAN=str(tmp / "plan.json"))
        self.plugin = plugin

    def tearDown(self):
        self.tmp.cleanup()

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
        full, native, codex = (report["arms"][n] for n in ("full", "code-review", "codex-review"))
        self.assertEqual((full["defects_found"], full["defects_planted"]), (planted, planted))
        self.assertEqual(full["false_findings"], 1)
        self.assertEqual((full["clean_runs_with_no_finding"], full["clean_runs"]), (0, 1))
        self.assertEqual(full["cost_usd_per_run"], 1.25)
        self.assertEqual(full["tokens_per_run"], 170)
        self.assertEqual(native["defects_found"], with_defects)
        self.assertEqual(native["false_findings"], 0)
        self.assertEqual(native["cost_usd_per_run"], 0.5)
        self.assertEqual(codex["defects_found"], 0)
        self.assertEqual(codex["false_findings"], len(self.key))
        self.assertEqual(codex["tokens_per_run"], 12345)
        pair = next(p for p in report["pairs"] if {p["a"], p["b"]} == {"full", "code-review"})
        only_full = pair["a_only"] if pair["a"] == "full" else pair["b_only"]
        self.assertEqual(only_full, planted - with_defects)
        self.assertEqual(pair["p"], round(review_compare.mcnemar(planted - with_defects, 0), 4))
        by_rank = full["by_rank"]
        self.assertEqual(by_rank["serious"]["found"] + by_rank["mild"]["found"], planted)

    def test_finished_runs_are_skipped_and_the_cost_cap_stops_new_ones(self):
        first = self.run_arms("--case", f"{TEMPLATE}--01", "--max-cost-usd", "1")
        self.assertEqual(first.returncode, 3, first.stdout + first.stderr)
        self.assertIn("reached --max-cost-usd", first.stdout)
        again = self.run_arms("--case", f"{TEMPLATE}--01")
        self.assertEqual(again.returncode, 0, again.stdout + again.stderr)
        self.assertEqual(again.stdout.count("try 1"), 2, again.stdout)

    def test_unavailable_and_unknown_arms_are_refused(self):
        for arm in ("full-effort-unset", "no-such-arm"):
            result = run("run", "--cases", str(self.cases), "--arms", arm, "--out", str(self.results))
            self.assertEqual(result.returncode, 2, arm)


if __name__ == "__main__":
    unittest.main(verbosity=1)
