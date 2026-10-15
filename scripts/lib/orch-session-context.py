#!/usr/bin/env python3
"""Fit freshly read opt-in policy into Claude SessionStart's context budget."""
import argparse
import json
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys

CONTROL = Path(__file__).resolve().with_name("orch-control.py")
HARD_LIMIT = 10000


def session(project):
    # The existing explicit API remains the single policy loader. This startup
    # adapter does not validate provider availability or activate Cadence.
    process = subprocess.Popen([sys.executable, str(CONTROL), "session", "--project", project],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, start_new_session=True)
    try:
        output, errors = process.communicate(timeout=3)
    except subprocess.TimeoutExpired:
        try:
            import os
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise ValueError("policy loading exceeded 3 seconds; run the explicit session API to diagnose")
    if process.returncode:
        raise ValueError(errors.strip()[:800] or "policy session API failed without a diagnostic")
    data = json.loads(output)
    context = data.get("policy_context")
    if data.get("enabled") is not True or not isinstance(context, dict):
        raise ValueError("the session API did not load an enabled policy at the canonical Git root")
    if not isinstance(context.get("config_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", context["config_sha256"]):
        raise ValueError("the session API did not return a configuration hash")
    if not isinstance(context.get("files"), list) or any(
        not isinstance(item, dict) or not all(isinstance(item.get(key), str) for key in ("path", "sha256", "text"))
        or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]) for item in context["files"]):
        raise ValueError("the session API returned a malformed canonical-file manifest")
    return data


def fit(body, policy, limit):
    # Keep the cadence verdict first when present; its report has always been
    # protected from tail truncation. Ordinary bootstrap text may be shortened.
    header = ""
    if body.startswith("cadence:"):
        header, _, body = body.partition("\n")
        header += "\n\n"
    if len(header) + len(policy) > limit:
        policy = ("POLICY LOAD PENDING: policy manifest exceeds the context budget. "
                  "Run orch-control.py session and read every returned canonical file before work.")
        if len(header) + len(policy) > limit:
            marker = " [cadence report shortened]\n\n"
            room = limit - len(policy)
            header = header[:max(0, room - len(marker))] + marker if room >= len(marker) else ""
    prefix = header + policy
    available = limit - len(prefix) - 2
    if body and available > 0:
        if len(body) > available:
            marker = "\n[bootstrap context shortened to fit SessionStart]"
            body = body[:max(0, available - len(marker))] + marker if available >= len(marker) else ""
        if body:
            prefix += "\n\n" + body
    return prefix


def render(body, project, source, limit):
    limit = max(256, min(limit, HARD_LIMIT))
    command = shlex.join([sys.executable, str(CONTROL), "session", "--project", project])
    action = f"Run {command}; read the returned canonical files before dispatch or editing."
    try:
        data = session(project)
        context = data["policy_context"]
        heading = (f"Shared project policy: freshly read on SessionStart ({source}).\n"
                   f"Configuration SHA256: {context['config_sha256']}\n"
                   "Session loading does not validate model availability or prove live execution.\n")
        full = heading + "Full canonical policy text supplied below.\n\n" + "\n\n".join(
            f"File: {item['path']}\nSHA256: {item['sha256']}\n{item['text']}" for item in context["files"])
        obligations = data.get("coordinator_obligations")
        if obligations:
            full += "\n\nConfigured coordinator obligations: " + json.dumps(obligations, sort_keys=True)
        budget = limit - 256
        if len(full) <= budget:
            policy = full
        else:
            # The hook actually read the files through the canonical API. Hashes
            # establish freshness; they do not substitute for the agent reading
            # text omitted from its context.
            manifest = "\n".join(f"- {item['path']} | SHA256 {item['sha256']}" for item in context["files"])
            policy = (heading + "POLICY TEXT LOADING PENDING: full text exceeds the SessionStart context budget. "
                      "The hook read it, but it is NOT loaded into the model context. "
                      "Read every canonical file below using the file tools before work; "
                      "if unavailable, report policy loading pending. Hashes are not instructions.\n"
                      + manifest + "\n" + action)
        return fit(body, policy, limit)
    except (OSError, ValueError, TypeError) as error:
        message = f"Shared project policy ERROR: {error}\nPolicy loading is pending. {action}"
        print(message, file=sys.stderr)
        return fit(body, message, limit)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--source", default="unknown")
    parser.add_argument("--max-chars", type=int, default=8000)
    args = parser.parse_args()
    print(render(sys.stdin.read(), args.project, args.source, args.max_chars), end="")


if __name__ == "__main__":
    main()
