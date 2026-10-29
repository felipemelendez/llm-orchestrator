#!/usr/bin/env python3
"""Tests for scripts/hooks/guard-disk-writes.sh: the commands it refuses and the work it allows.

Every case runs the real hook with a PreToolUse event, as Claude Code does. Nothing is written
to a temporary folder: the guard only reads the command, and the paths it names are fixtures.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "scripts/hooks/guard-disk-writes.sh"
UID = os.getuid()
TEMP = f"/tmp/claude-{UID}"
SESSION = "5f0c8a4e-0000-4000-8000-000000000001"
PROJECT_FOLDER = "-Users-someone-project"
BASH = shutil.which("bash")
INCIDENT = 'cd $TMPDIR && rm -rf pr && mkdir pr && cp -R "$OLDPWD"/. .'


class DiskGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="orch-disk-guard-test-", dir=ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.clone = self.root / "clone"
        (self.clone / "src").mkdir(parents=True)
        self.run_dir = self.root / "runs/run-1"
        self.run_dir.mkdir(parents=True)
        # The hook's own $TMPDIR, as a user's session on macOS has one (a per-user folder).
        self.own_tmp = self.root / "user-tmp"
        self.own_tmp.mkdir()

    def hook(self, command, env=None, cwd=None, event=None, hook=HOOK):
        payload = {"tool_name": "Bash", "tool_input": {"command": command}, "cwd": str(cwd or self.clone),
                   "session_id": SESSION, "transcript_path": f"/Users/someone/.claude/projects/{PROJECT_FOLDER}/"
                                                             f"{SESSION}.jsonl"}
        payload.update(event or {})
        environment = {"PATH": os.environ["PATH"], "HOME": str(self.root / "home"), "TMPDIR": str(self.own_tmp),
                       **(env or {})}
        return subprocess.run([BASH, str(hook)], input=json.dumps(payload) if isinstance(payload, dict) else payload,
                              capture_output=True, text=True, env=environment, cwd=str(self.clone), timeout=20)

    def refuses(self, command, words=None, **kwargs):
        result = self.hook(command, **kwargs)
        self.assertEqual(result.returncode, 2, f"{command!r} was allowed: {result.stderr}")
        self.assertIn("disk guard: refused", result.stderr)
        for word in words or []:
            self.assertIn(word, result.stderr)
        return result

    def allows(self, command, **kwargs):
        result = self.hook(command, **kwargs)
        self.assertEqual(result.returncode, 0, f"{command!r} was refused: {result.stderr}")
        return result

    def test_the_incident_command_is_refused_and_told_where_to_work(self):
        result = self.refuses(INCIDENT)
        self.assertIn(f"Work in the clone or folder you were given at {self.clone}", result.stderr)
        self.assertIn(f"claude-{UID}", result.stderr)

    def test_a_copy_into_a_folder_inside_its_source_is_refused(self):
        for command in ("cp -R . ./sub", 'cp -R "$PWD"/. "$PWD/copy"', "cp -a src src/inner", "cp -r .. sub",
                        "rsync -a ./ ./backup/", "ditto . sub", "tar -cf - . | tar -xf - -C sub",
                        "tar cf - src | (cd src/x && tar xf -)", "cp -R * sub/", "cd src && cp -R .. here"):
            with self.subTest(command=command):
                self.refuses(command, ["inside it"])

    def test_writes_into_the_shared_temporary_folder_are_refused(self):
        for command in (f"mkdir {TEMP}/pr", 'mkdir -p "$TMPDIR/x"', "mkdir -p ${TMPDIR}/x",
                        "cat > \"$TMPDIR/c1.sh\" <<'X'\nset -e\necho hi\nX", f"echo x > /private/tmp/claude-{UID}/f",
                        f"git clone . {TEMP}/pr", f"bash -c 'cp -R . {TEMP}/pr'", f"D={TEMP}/pr; cp -R . \"$D\"",
                        f"cd {TEMP} && tar -xzf ~/a.tgz", f"touch {TEMP}/a", 'rm -rf "$TMPDIR/pr"',
                        f"cp notes.txt {TEMP}/", f"echo $(mkdir {TEMP}/sub)", f"git worktree add {TEMP}/wt",
                        'mktemp -d "$TMPDIR/x.XXXXXX"', f"curl -o {TEMP}/f https://example.invalid",
                        "printf x | tee $TMPDIR/log", f"export D={TEMP}/x && mkdir $D", f"ln -s . {TEMP}/link"):
            with self.subTest(command=command):
                self.refuses(command, ["shared temporary folder"])

    def test_the_hooks_own_tmpdir_is_a_shared_folder_too(self):
        self.refuses(f"mkdir {self.own_tmp}/x")
        self.refuses('cp -R . "$TMPDIR/copy"', env={"TMPDIR": str(self.own_tmp)})

    def test_an_inline_override_or_own_scratch_prefix_does_not_disarm_it(self):
        self.refuses(f"ORCH_ALLOW_TEMP_WRITES=1 mkdir {TEMP}/x")
        self.refuses(f"TMPDIR={self.clone} mkdir -p {TEMP}/x")

    def test_the_persons_own_override_in_the_hook_environment_allows(self):
        self.allows(INCIDENT, env={"ORCH_ALLOW_TEMP_WRITES": "1"})

    def test_ordinary_work_is_allowed(self):
        for command in ("cp -R src dst", "cp -R src/. ../sibling", "rsync -a src/ build/", "mktemp -d",
                        f"ls {TEMP}", 'du -sh "$TMPDIR"', 'grep -rn "cp -R" .', "git status && git diff HEAD | head",
                        f"echo done > {self.run_dir}/notes.txt", f"mkdir -p {self.run_dir}/sub",
                        "python3 -m pytest -q", 'T=$(mktemp -d) && echo "$T"', "cp file.txt .",
                        f"cat {TEMP}/x.log", "tar -czf build/out.tgz .", "echo 'it'\"'\"'s' > out.txt",
                        "mkdir -p .git/orch-tmp && echo x > .git/orch-tmp/a", "cd .. && ls"):
            with self.subTest(command=command):
                self.allows(command)

    def test_the_sessions_own_folder_is_allowed(self):
        folder = f"{TEMP}/{PROJECT_FOLDER}/{SESSION}/scratchpad"
        self.allows(f"mkdir -p {folder}/x && cp -R src {folder}/copy")
        self.refuses(f"mkdir -p {TEMP}/{PROJECT_FOLDER}/another-session/x")
        result = self.refuses(f"mkdir {TEMP}/x")
        self.assertIn(f"/tmp/claude-{UID}/{PROJECT_FOLDER}/{SESSION}/", result.stderr)

    def test_a_command_that_cannot_be_parsed_falls_back_to_refusing_temp_writes(self):
        self.refuses(f"echo 'unclosed > {TEMP}/x")
        self.allows("echo 'unclosed quote in ordinary text")

    def test_without_python_the_text_check_still_refuses_the_incident(self):
        tools = self.root / "no-python"
        tools.mkdir()
        for name in ("cat", "tr", "grep", "dirname"):
            os.symlink(shutil.which(name), tools / name)
        bare = {"PATH": str(tools)}
        result = self.hook(INCIDENT, env=bare)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.hook("cp -R src dst", env=bare).returncode, 0)

    def test_a_broken_helper_falls_back_instead_of_allowing(self):
        copy = self.root / "installed/scripts"
        (copy / "hooks").mkdir(parents=True)
        (copy / "lib").mkdir()
        shutil.copy2(HOOK, copy / "hooks/guard-disk-writes.sh")
        (copy / "lib/orch-disk-guard.py").write_text("raise SystemExit(1)\n")
        result = self.hook(INCIDENT, hook=copy / "hooks/guard-disk-writes.sh")
        self.assertEqual(result.returncode, 2, result.stderr)

    def test_hooks_json_wires_the_guard_for_every_bash_call(self):
        hooks = json.loads((ROOT / "hooks/hooks.json").read_text())["hooks"]["PreToolUse"]
        commands = [hook["command"] for entry in hooks if entry.get("matcher") == "Bash" for hook in entry["hooks"]]
        self.assertIn("bash ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/guard-disk-writes.sh", commands)


if __name__ == "__main__":
    unittest.main()
