# Research Brief: openssl version in LLM-Orchestrator

- Date: 2026-05-24
- Task: "What version of openssl is installed in this project?"
- Libraries: openssl
- Stakes: low
- Trigger: sniffer (installed-version lookup) — compelled
- Authoritative source: project filesystem (lockfiles, manifests) via built-in Read/Bash

## Status

Status: NOT_APPLICABLE
Premise: The question assumes openssl is a declared dependency of this project, such that an "installed version" is a meaningful property to look up.
Reality: The repository at /Users/felipemelendez/LLM-Orchestrator is a Claude Code plugin/skills repo. It contains **no dependency manifests of any kind** — no `package.json`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `requirements.txt`, `Pipfile`, `poetry.lock`, `pyproject.toml`, `Gemfile`, `go.mod`, `go.sum`, `Cargo.toml`, `composer.json`, `pubspec.yaml`, or `Podfile`. The only string matches for "openssl" in the tree are (1) a sniffer test fixture in `tests/test-research-gate.sh` and (2) the researcher agent's own documentation in `agents/orch-researcher.md` which cites this exact question as the canonical NOT_APPLICABLE example. openssl is not consumed, vendored, pinned, or otherwise present as a project dependency. There is nothing to version.

## What was checked (filesystem ground truth)

Commands run:

```
ls -la /Users/felipemelendez/LLM-Orchestrator/
find /Users/felipemelendez/LLM-Orchestrator -type f \( -name "package.json" -o -name "package-lock.json" \
  -o -name "yarn.lock" -o -name "pnpm-lock.yaml" -o -name "requirements.txt" -o -name "Pipfile*" \
  -o -name "poetry.lock" -o -name "pyproject.toml" -o -name "Gemfile*" -o -name "go.mod" -o -name "go.sum" \
  -o -name "Cargo.*" -o -name "composer.*" -o -name "pubspec.*" -o -name "Podfile*" \) \
  | grep -v node_modules
grep -ril "openssl" /Users/felipemelendez/LLM-Orchestrator | grep -v node_modules
```

Results:

- Zero dependency manifests anywhere in the tree.
- `openssl` appears only in:
  - `/Users/felipemelendez/LLM-Orchestrator/tests/test-research-gate.sh` (sniffer test fixture for this exact question shape).
  - `/Users/felipemelendez/LLM-Orchestrator/agents/orch-researcher.md` line 92 (worked example for NOT_APPLICABLE).
- No vendored sources, no native module bindings, no Brewfile/Podfile pinning a system openssl.

## Why NOT_APPLICABLE and not the other outcomes

- Not VERIFIED — there is no claim or approach being verified; the question presupposes a fact (openssl is installed) that is false.
- Not COULDN'T_VERIFY — the lookup did not fail for lack of sources. The authoritative source (the filesystem) was reached, exhaustively scanned, and returned a definitive negative answer. Calling this "couldn't verify" would conflate a successful negative lookup with an inability to look.
- Not CONTRADICTED — no documentation was consulted, and nothing in the docs says "you should not use openssl." The verdict is about the premise of the question, not about an approach being wrong.

This is exactly the case Fix 2 introduced NOT_APPLICABLE for.

## Authority note

For installed-version lookups, filesystem ground truth (built-in `Read`/`Bash`) is more authoritative than any MCP server. No MCP nudge was warranted and none fired. This is the correct behavior under Fix 3, which updated the worked-example nudge list to treat filesystem-as-source as "no nudge."
