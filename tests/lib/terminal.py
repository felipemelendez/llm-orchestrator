#!/usr/bin/env python3
"""Run a command with or without a terminal, for tests of terminal-only commands.

  terminal.py none <cmd...>         run it in a new session with no terminal
  terminal.py type <text> <cmd...>  run it in a pseudo-terminal and type <text> into it

Prints the command's output and exits with its exit code.
"""
import os
import pty
import sys


def main() -> int:
    mode = sys.argv[1]
    if mode == "none":
        argv = sys.argv[2:]
        pid = os.fork()
        if pid == 0:
            os.setsid()
            os.execvp(argv[0], argv)
        return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
    text, argv = sys.argv[2], sys.argv[3:]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    os.write(fd, text.encode())
    out = b""
    while True:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    sys.stdout.write(out.decode(errors="replace").replace("\r\n", "\n"))
    return os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])


sys.exit(main())
