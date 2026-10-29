#!/usr/bin/env python3
"""Tests for scripts/hooks/guard-disk-writes.sh: the closed list it refuses and the work it lets run.

Every case runs the real hook with a PreToolUse event, as Claude Code does, except the grammar property
test, which calls the helper's decision directly to try every character. Nothing is run and nothing is
written to a temporary folder: the guard only reads the command text, and the paths in it are fixtures.
Spec: docs/specs/disk-guard.md, G1.
"""
import importlib.util
import json
import os
from pathlib import Path
import random
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/hooks/guard-disk-writes.sh"
HELPER = ROOT / "scripts/lib/orch-disk-guard.py"
UID = os.getuid()
T = f"/tmp/claude-{UID}"
SESSION = "5f0c8a4e-0000-4000-8000-000000000001"
PROJECT = "-Users-someone-project"
OWN = f"{T}/{PROJECT}/{SESSION}"  # the session's own folder
BASH = shutil.which("bash")
INCIDENT = 'cd $TMPDIR && rm -rf pr && mkdir pr && cp -R "$OLDPWD"/. .'

# What each kind of refusal says, and the rule it belongs to.
KINDS = {"shared": ("1", "names the shared temporary area"), "escape": ("0", "names the shared temporary area"),
         "nested": ("2", "a folder inside it"), "spelled": ("2", "not spelled out"),
         "cd": ("2", "in a command that changes folder"), "no-source": ("2", "not on the line"),
         "tar": ("2", "a tar pipeline"), "unreadable": ("2", "cannot read")}

# Every refused form: the incident, every form the five review rounds of PR #55 reproduced against the hook
# (~/.local/state/llm-orchestrator/reviews/20261029-plugin55-{full,fix1,fix2,fix3,fix4}/review.json), the
# over-refusals the spec names, and the forms the brief adds. (kind, command, folder it runs from or None).
REFUSED = [
    ("shared", INCIDENT, None),
    ("shared", 'bash "$TMPDIR/c1.sh"', None),  # round 4 of the incident's review
    # full
    ("nested", "cp -f -R . ./sub", None), ("nested", "cp -r -T . sub", None),
    ("shared", f"rm -r {T}/pr", None), ("shared", f"rm -d {T}/pr", None),
    ("shared", f"curl -sSLo {T}/x https://e.invalid", None), ("shared", f"cd {T} && curl -LO https://e.invalid/f", None),
    ("shared", f"wget -qO {T}/x https://e.invalid", None), ("shared", "cd $TMPDIR && true $(mkdir pr)", None),
    ("nested", "timeout 600 cp -R . ./sub", None), ("spelled", "find . -exec cp -R {} ./sub \\;", None),
    ("shared", f"xargs mkdir {T}/pr", None), ("shared", f"echo $((1<<2))\nmkdir {T}/pr", None),
    ("shared", f'echo "a<<b"\nmkdir {T}/pr', None), ("nested", "cp -R -f . ./sub", None),
    ("shared", f"cd {T} && echo $(mkdir pr)", None), ("shared", f'D={T}/pr; echo $(mkdir "$D")', None),
    ("shared", f"cd {T}; (cd /); mkdir pr", None), ("shared", f"curl -o{T}/out https://example.invalid", None),
    ("shared", f"wget -O{T}/out https://example.invalid", None),
    ("shared", f"printf %s '$(mkdir {T}/pr)'", None),  # reproduced as wrongly refused; a named over-refusal now
    ("shared", f"git -C {T} -C pr clone https://example.invalid/y.git", None),
    # fix1
    ("shared", f"cat <<'EOF' | bash\nmkdir {T}/pr\nEOF", None),
    ("shared", "mkdir -p /tmp/claude/pr && cp -R . /tmp/claude/pr", None),
    ("shared", f"cp -R ~/repo {T}/x", "/tmp"), ("spelled", "mkdir pr && cp -R ~/x pr", T),
    ("shared", f"(( y = x << 2 ))\nmkdir {T}/pr", None), ("shared", f"echo $(( $(mkdir {T}/pr) + 1 ))", None),
    ("shared", f"mkdir /tmp/./claude-{UID}/pr", None), ("spelled", 'D=sub; cp -R . "$D"; D=/outside', None),
    # fix2
    ("nested", "rsync -a -t ./ ./backup/", None), ("shared", 'cp -R . "${TMPDIR-/tmp}/pr"', None),
    ("shared", f'cd /tmp && mkdir -p "$PWD/claude-{UID}/pr"', None),
    ("shared", " && ".join(f"cd d{i} && echo a b c" for i in range(150)) + f" && mkdir {T}/pr", None),
    ("unreadable", "cat > notes.md <<'EOF'  # notes for the bash step\ndon't cp -R . sub\nEOF", None),  # over-refusal
    ("shared", 'mkdir -p "$TMPDIR/review-$$"', None), ("nested", "rsync -a -t . ./backup/", None),
    ("shared", f"size=$(du -sk {T} | cut -f1); echo $((size >> 10))", None),  # reproduced as wrongly refused
    # fix3
    ("shared", "mkdir -p /tmp/claude-$UID/pr", None), ("spelled", "cp -R . backup-$$", None),
    ("spelled", " && ".join(f'cd d{i} && cp -R "$OLDPWD"/x{i} y{i}' for i in range(150)), None),
    ("nested", "cat <<EOF | $(command -v bash)\ncp -R . sub\nEOF", None), ("spelled", 'D=$PWD/sub; cp -R . "$D"', None),
    ("tar", 'tar cf - . | tar xf - -C "./copy-$$"', None), ("spelled", 'cp -R . "$(pwd)/sub"', None),
    ("spelled", 'D=sub; echo $(cp -R . "$D"); D=/x', None), ("spelled", 'D=./snapshot-$(date +%s); cp -R . "$D"', None),
    # fix4
    ("spelled", "cd sub && cp -R ~-/. .", None), ("spelled", "cp -R ~+ ./sub", None),
    ("spelled", "find . -maxdepth 1 | xargs -I{} cp -R {} ./sub", None), ("spelled", "ls | xargs -I{} cp -R {} sub/", None),
    ("spelled", "/usr/bin/find . -exec cp -R {} ./sub \\;", None), ("no-source", "ls | xargs cp -R -t sub", None),
    ("spelled", "cp -R . backup-12:30", None), ("spelled", 'cp -R . "snap 12:30"', None),
    ("tar", "tar cf - . | tar xf - -C a:b", None), ("spelled", 'cd -- "$D" && cp -R ~/repo .', None),
    ("spelled", 'cd -P -- "$D" && cp -R ~/repo .', None), ("spelled", "cp -R {src,.} sub", None),
    ("shared", "mkdir -p /tmp/{claude-$(id -u),x}/pr", None), ("shared", f". /dev/stdin <<'EOF'\nmkdir {T}/pr\nEOF", None),
    ("shared", f"cat <<EOF | . /dev/stdin\nmkdir {T}/pr\nEOF", None), ("spelled", 'HOME=./sub; cp -R . "$HOME"', None),
    ("shared", f'D=/tmp; cd "$D" && mkdir claude-{UID}/pr', None),
    # the brief's additions, and other spellings of the same rules
    ("shared", "rm -rf /tmp/claude*/pr", None), ("shared", "mkdir /tmp/claude/pr", None),
    ("shared", f"cd /tmp && mkdir claude-{UID}/pr", None), ("shared", f"cd /; cd tmp; mkdir claude-{UID}/pr", None),
    ("shared", 'T=$(mktemp -d) && cp -R src "$T/x"', None), ("shared", f"mkdir //tmp/claude-{UID}/pr", None),
    ("shared", f"touch /private/tmp/claude-{UID}/x", None), ("shared", "echo ${#TMPDIR}", None),
    ("shared", f"ORCH_ALLOW_TEMP_WRITES=1 mkdir {T}/x", None), ("shared", f"TMPDIR=/Users/x/t mkdir -p {T}/x", None),
    ("nested", "cp -R . ./sub", None), ("nested", "cp -a src src/inner", None), ("nested", "cp -r .. sub", None),
    ("nested", "rsync -a ./ ./backup/", None), ("nested", "ditto . sub", None), ("spelled", "cp -R * sub/", None),
    ("nested", "cp -R -t sub .", None), ("nested", "cp -Rt sub .", None), ("nested", "cp -R -tsub .", None),
    ("nested", "cp -R --target-directory=sub .", None), ("nested", "cp -R src src/sub 2>/dev/null", None),
    ("nested", "echo `cp -R . ./sub`", None), ("nested", "cat <<'EOF' | sh\ncp -R . ./sub\nEOF", None),
    ("nested", "CP -R . sub", None), ("tar", "tar -cf - . | tar -xf - -C sub", None),
    ("tar", "tar cf - src | (cd /dest && tar xf -)", None), ("cd", "cd src && cp -R .. here", None),
    # the over-refusals the spec names
    ("shared", "cat /tmp/x.log", None), ("shared", "ls $TMPDIR", None), ("shared", "mktemp -d", None),
    ("spelled", 'cp -R "$SRC" dest', None), ("cd", "cd sub && cp -R ../x y", None),
    # rule 0: only the session's own folder is set aside
    ("escape", f"mkdir -p {T}/{PROJECT}/another-session/x", None), ("escape", f"mkdir {OWN}/../../pr", None),
    ("escape", f'mkdir "{OWN}"/../pr', None),
    # the closed-list re-review (20261029-plugin55-closed): rule 0 reads the whole word, is anchored, and
    # takes neither . nor .. as the project folder; what follows the folder's plain path stays visible
    ("escape", f'mkdir "{OWN}/a b/../../../pr"', None), ("escape", f'mkdir {OWN}/"a b/../../../pr"', None),
    ("escape", f"mkdir -p {T}/../{SESSION}/pr", None),
    ("escape", f"mkdir -p {T}/./{SESSION}/pr", None), ("escape", f"mkdir -p /var{OWN}/pr", None),
    ("escape", f'echo "{OWN}/x $(mkdir {T}/pr)"', None),
    # rule 2: a copy missing its source or destination, a redirection's target, fd digits, case and /private
    ("no-source", "echo . sub | xargs cp -R", None), ("no-source", "rsync -a", None),
    ("nested", "cp -R 2>/dev/null . ./sub", None), ("nested", "cp -R src . 9 >log", None),
    ("nested", "cp -R . sub >&2", None), ("nested", "cp -R src SRC/x", None),
    ("nested", "cp -R /var/folders/q/repo sub", "/private/var/folders/q/repo"),
]

# Ordinary work, and the session's own folder. (kind, command): "own" rows test rule 0.
ALLOWED = [
    ("work", "cp -R src dist"), ("work", "cp -R /Users/someone/repo/scripts /Users/someone/repo/build/scripts"),
    ("work", "mkdir -p build && cp -r scripts build/"), ("work", "tar -czf out.tgz src"),
    ("work", "cat README.md > notes.md"), ("work", "rm -rf build"),
    ("work", "claude --model claude-opus-4-1 -p hi"), ("work", "TMPDIR=/Users/someone/runs/run-1/t codex exec hi"),
    ("work", "cat > notes.md <<'EOF'\nRun mkdir build, then cp the notes into it.\nEOF"),
    ("work", "git commit -q -F - <<'EOF'\nDon't copy into itself\nEOF"), ("work", "npm test"), ("work", "git status"),
    ("work", "ls -la"), ("work", "grep -rn 'mkdir' scripts/"), ("work", "cp notes.txt backup.txt"), ("work", "mv a b"),
    ("work", "cp -R -t /out src"), ("work", "rsync -a src/ build/"), ("work", "cp -R src dist 2>/dev/null"),
    ("work", "cd sub && cp -R /abs/a /abs/b"), ("work", "eval eval eval eval eval eval 'mkdir x'"),
    ("work", "python3 tests/test-disk-guard.py"),
    ("own", f"ls {OWN}/scratchpad"), ("own", f"echo hi > {OWN}/scratchpad/a.txt"),
    ("own", f"mkdir -p {OWN}/x && cp -R src {OWN}/copy"), ("own", f"cp -R . /private{OWN}/copy"),
    ("own", f"TMPDIR={OWN}/t codex exec 'review the diff'"), ("own", f'mkdir -p "{OWN}/x-$$"'),
    ("own", f"mkdir -p {OWN}/build/tmp"), ("own", f"ls {OWN}/claude-{UID}"),
    ("own", f"mkdir /TMP/CLAUDE-{UID}/{PROJECT}/{SESSION}/x"), ("own", f'cp notes.txt "{OWN}/a b/c.txt"'),
    ("work", "tar -czf a.tgz src\nls | grep tar"), ("work", "tar cf a.tar src\nprintf done | cat\ntar xf a.tar -C dest"),
    ("work", "cp -R src dist 2>&1 | tail -1"),
]


def load_helper():
    spec = importlib.util.spec_from_file_location("orch_disk_guard", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class DiskGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="orch-disk-guard-test-", dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.clone = self.root / "clone"
        self.clone.mkdir()

    def hook(self, command, env=None, cwd=None, hook=HOOK, event=None):
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(cwd or self.clone),
                   "session_id": SESSION, "transcript_path": f"/Users/someone/.claude/projects/{PROJECT}/{SESSION}.jsonl",
                   **(event or {})}
        environment = {"PATH": os.environ["PATH"], "HOME": str(self.root / "home"), **(env or {})}
        return subprocess.run([BASH, str(hook)], input=json.dumps(payload), capture_output=True, text=True,
                              env=environment, cwd=str(self.clone), timeout=20)

    def check_refused(self, rule):
        for kind, command, cwd in REFUSED:
            if KINDS[kind][0] != rule:
                continue
            with self.subTest(command=command[:120]):
                result = self.hook(command, cwd=cwd)
                self.assertEqual(result.returncode, 2, f"{command[:200]!r} ran: {result.stderr}")
                self.assertIn("disk guard: refused", result.stderr)
                self.assertIn(KINDS[kind][1], result.stderr)

    def check_allowed(self, kinds):
        for kind, command in ALLOWED:
            if kind in kinds:
                with self.subTest(command=command):
                    result = self.hook(command)
                    self.assertEqual(result.returncode, 0, f"{command!r} was refused: {result.stderr}")

    def test_rule_0_only_the_sessions_own_folder_is_set_aside(self):
        self.check_allowed({"own"})
        self.check_refused("0")

    def test_rule_1_any_mention_of_the_shared_temporary_area_is_refused(self):
        self.check_refused("1")

    def test_rule_2_a_recursive_copy_into_itself_or_not_spelled_out_is_refused(self):
        self.check_refused("2")

    def test_rule_2_any_character_outside_the_grammar_refuses(self):
        decide = load_helper().decide
        outside = [chr(c) for c in range(32, 127) if not (chr(c).isalnum() or chr(c) in "._/+-")] + ["\t", "é", " "]
        for char in outside:
            for command in (f"cp -R src {shlex.quote('out' + char + 'x')}", f"cp -R {shlex.quote('in' + char + 'x')} out",
                            f"rsync -a src/ {shlex.quote('b' + char)}"):
                with self.subTest(command=command):
                    self.assertIn("not spelled out", decide(command, "/w", None, None) or "")
        # The same copies with only grammar characters run, so the refusal comes from the character alone.
        draw = random.Random(55)
        for _ in range(300):
            name = "out" + "".join(draw.choice("abcXYZ019._+-") for _ in range(draw.randint(1, 12)))
            for command in (f"cp -R src {name}", f"cp -R {name} /elsewhere/x", f"rsync -a src/ build/{name}"):
                with self.subTest(command=command):
                    self.assertIsNone(decide(command, "/w", None, None))

    def test_rule_3_a_long_command_is_decided_fast(self):
        for command, code in (("printf %s " + "a" * 1_500_000 + f"; mkdir {T}/pr", 2),
                              ("printf %s " + "a" * 1_500_000 + "; cp -R . ./sub", 2),
                              ("printf %s " + "a" * 1_500_000, 0)):
            with self.subTest(length=len(command), code=code):
                started = time.monotonic()
                result = self.hook(command)
                self.assertLess(time.monotonic() - started, 3, "the harness's 10 s timeout would run it unchecked")
                self.assertEqual(result.returncode, code, result.stderr)
                if code:
                    self.assertIn("over 100,000 characters", result.stderr)

    def test_allowed_forms_run(self):
        self.check_allowed({"work", "own"})

    def test_each_refusal_says_what_to_do_instead(self):
        result = self.hook(INCIDENT)
        self.assertIn("Read tool", result.stderr)
        self.assertIn(f"work in the clone or folder you were given, {self.clone}", result.stderr)
        self.assertIn(f"/tmp/claude-{UID}/{PROJECT}/{SESSION}/", result.stderr)
        self.assertIn("write each path with letters, digits", self.hook('cp -R "$SRC" dest').stderr)
        self.assertIn("as two commands", self.hook("tar cf - . | tar xf - -C sub").stderr)
        self.assertIn(f"{OWN}/a into {OWN}/a/b", self.hook(f"cp -R {OWN}/a {OWN}/a/b").stderr)

    def test_only_the_persons_own_override_disarms_it(self):
        self.assertEqual(self.hook(INCIDENT, env={"ORCH_ALLOW_TEMP_WRITES": "1"}).returncode, 0)
        self.assertEqual(self.hook(f"ORCH_ALLOW_TEMP_WRITES=1 mkdir {T}/x").returncode, 2)

    def installed_copy(self, helper=None):
        copy = self.root / "installed/scripts"
        (copy / "hooks").mkdir(parents=True)
        (copy / "lib").mkdir()
        shutil.copy2(HOOK, copy / "hooks/guard-disk-writes.sh")
        if helper is not None:
            (copy / "lib/orch-disk-guard.py").write_text(helper)
        return copy / "hooks/guard-disk-writes.sh"

    def test_the_plain_fallback_runs_when_the_helper_is_missing(self):
        hook = self.installed_copy()
        for command in (INCIDENT, f"echo $(( $(mkdir {T}/pr) + 1 ))", "ls\ncp -R src dist", "mktemp -d", "rsync -a a b"):
            with self.subTest(command=command):
                result = self.hook(command, hook=hook)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("helper could not run", result.stderr)
        for command in ("git status", "npm test", "claude --model claude-opus-4-1 -p hi"):
            with self.subTest(command=command):
                self.assertEqual(self.hook(command, hook=hook).returncode, 0)

    def test_the_plain_fallback_reads_only_the_command(self):
        hook = self.installed_copy()
        around = {"cwd": "/Users/someone/src/tar", "tool_input": {"command": "ls", "description": "List the tar files"},
                  "transcript_path": f"/tmp/claude-{UID}/x/{SESSION}.jsonl"}
        self.assertEqual(self.hook("", hook=hook, event=around).returncode, 0)
        inside = {"tool_input": {"command": 'echo "\\"command\\": \\"ls\\"" && cp -R a b', "description": "d"}}
        self.assertEqual(self.hook("", hook=hook, event=inside).returncode, 2)

    def test_the_plain_fallback_runs_when_the_helper_fails_or_python_is_missing(self):
        broken = self.installed_copy("raise RuntimeError(\"broken\")\n")
        result = self.hook(INCIDENT, hook=broken)
        self.assertEqual((result.returncode, "Traceback" in result.stderr), (2, False), result.stderr)
        tools = self.root / "no-python"
        tools.mkdir()
        for name in ("cat", "tr", "grep", "sed", "dirname"):
            os.symlink(shutil.which(name), tools / name)
        self.assertEqual(self.hook(INCIDENT, env={"PATH": str(tools)}).returncode, 2)
        self.assertEqual(self.hook("git status", env={"PATH": str(tools)}).returncode, 0)

    def test_every_command_the_plugin_tells_a_model_to_run_passes_the_guard(self):
        decide = load_helper().decide
        pages = [*ROOT.glob("commands/*.md"), *ROOT.glob("agents/*.md"), *ROOT.glob("skills/**/*.md"),
                 *ROOT.glob("templates/**/*.md"), *ROOT.glob("output-styles/*.md")]
        blocks = [(page, block) for page in pages
                  for block in re.findall(r"```(?:bash|sh|shell)\n(.*?)```", page.read_text(), re.S)]
        self.assertGreater(len(blocks), 20)
        for page, block in blocks:
            with self.subTest(page=str(page.relative_to(ROOT)), block=block[:80]):
                self.assertIsNone(decide(block, "/w", SESSION, None))

    def test_the_message_names_the_session_folder_from_the_transcripts_own_folder(self):
        transcript = f"/Users/projects/.claude/projects/{PROJECT}/{SESSION}.jsonl"  # a home folder called projects
        result = self.hook("mktemp -d", event={"transcript_path": transcript})
        self.assertIn(f"in your session's own folder, /tmp/claude-{UID}/{PROJECT}/{SESSION}/", result.stderr)
        result = self.hook("mktemp -d", event={"transcript_path": f"/Users/x/.claude/projects/{PROJECT}/{SESSION}/subagents/a.jsonl"})
        self.assertIn("put temporary files inside that folder", result.stderr)

    def test_hooks_json_wires_the_guard_for_every_bash_call(self):
        hooks = json.loads((ROOT / "hooks/hooks.json").read_text())["hooks"]["PreToolUse"]
        commands = [hook["command"] for entry in hooks if entry.get("matcher") == "Bash" for hook in entry["hooks"]]
        self.assertIn("bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-disk-writes.sh", commands)


if __name__ == "__main__":
    unittest.main()
