#!/usr/bin/env bash
# Shared signal patterns for the research gate — single source of truth.
#
# This file defines every regex pattern that counts as a research-relevant
# signal. Both the sniffer (deterministic, shell) and the classifier (model
# reasoning, documented in markdown) reference the SAME class names defined
# here. Drift between them is a structural failure mode (silent dead branches
# in the gate), so the test suite explicitly checks consistency between this
# file and skills/research-classifier/SKILL.md.
#
# Sourced by:
#   - scripts/hooks/orch-research-gate.sh (sniffer compel logic)
#   - tests/test-research-classifier.sh (classifier heuristic test)
#   - tests/test-research-gate.sh (drift detection across files)
#
# Adding a new signal class:
#   1. Define ORCH_SIG_<NAME>='<extended regex>' here.
#   2. Add a row to the YES signals table in skills/research-classifier/SKILL.md
#      with a class label that contains the keyword named in SIGNAL_CLASSES_MAP
#      below.
#   3. Add a compose branch in scripts/hooks/orch-research-gate.sh that uses
#      the new variable.
#   4. Run ./tests/test-research-gate.sh — drift detection will fail if any
#      of the three are out of sync.
#
# Bash 3.2 compatible. Patterns are extended regex (for grep -E).
# Match against the LOWERCASED input — patterns assume lowercase.

# === Design-intent signals ===
# These signals compel only when combined with a design verb (the sniffer's
# compose logic). They represent "the user is committing to use X".

# Library / framework / SDK proper nouns.
# Includes both pure libraries (react, prisma) and vendor names (stripe, supabase)
# because the sniffer's design-verb-required branch treats them uniformly.
# The classifier separates them for nudge routing via ORCH_SIG_VENDOR.
ORCH_SIG_LIBRARY='\b(next\.?js|react|vue|svelte|angular|nuxt|astro|remix|prisma|drizzle|sequelize|mongoose|typeorm|tailwindcss|tailwind|django|fastapi|flask|spring|rails|laravel|express|hono|nest\.?js|nestjs|trpc|graphql|apollo|axios|boto3|aws-sdk|stripe|auth0|nextauth|clerk|supabase|firebase|cloudflare|vercel|netlify|openai|anthropic|langchain|llamaindex|pydantic|sqlalchemy|mocha|vitest|jest|playwright|cypress|webpack|vite|rollup|esbuild|turbopack|biome|eslint|prettier|ruff|mypy|openssl|claude[[:space:]]?code|claude-code|mcp[[:space:]]+server|jsonl[[:space:]]+transcript)\b'

# Vendor SaaS platforms — subset of LIBRARY but maintained separately so the
# classifier can prefer "vendor MCP" over "doc aggregator" for their APIs.
ORCH_SIG_VENDOR='\b(stripe|cloudflare|vercel|auth0|supabase|firebase|netlify)\b'

# Version-shaped tokens.
ORCH_SIG_VERSION='(\bv[0-9]+(\.[0-9]+)?\b|[a-z]\.?js[[:space:]]+[0-9]+|>=[[:space:]]*[0-9]+|\^[0-9]+|~[0-9]+|\b[a-z]+[[:space:]]+v?[0-9]+\b)'

# Security-sensitive verbs and nouns.
ORCH_SIG_SECURITY='\b(auth|crypto|payment|secret|jwt|oauth|password|encryption|tls|ssl|webhook)\b'

# Architectural signals (verb-or-noun shape).
ORCH_SIG_ARCH='\b(migrate|migrating|migration|set[[:space:]]+up|wire|wiring|integrate|integrating|replace[[:space:]]+.+[[:space:]]+with|switch[[:space:]]+from|schema|config[[:space:]]+syntax)\b'

# Design intent verbs — required alongside one of the above for the sniffer's
# design-shape compel branch.
ORCH_SIG_DESIGN_VERB='\b(add|implement|build|set[[:space:]]+up|wire|wiring|integrate|integrating|migrate|migrating|migration|upgrade|upgrading|refactor|create|introduce|switch[[:space:]]+from|replace)\b'

# Explicit user invocation.
ORCH_SIG_INVOCATION='/llm-orchestrator:research'

# === Question-shape signals ===
# These signals compel WITHOUT a design verb. They're queries against project
# state or upstream sources, not design commitments. The sniffer's
# question-shape compel branch uses these directly.

# Installed-version lookups.
ORCH_SIG_QUESTION_VERSION='\b(what[[:space:]]+version[[:space:]]+of|which[[:space:]]+version[[:space:]]+of|current[[:space:]]+version[[:space:]]+of|version[[:space:]]+is[[:space:]]+installed|version[[:space:]]+do[[:space:]]+we[[:space:]]+have|version[[:space:]]+are[[:space:]]+we[[:space:]]+on)\b'

# Security-advisory queries.
ORCH_SIG_QUESTION_ADVISORY='\b(cve|vulnerability|security[[:space:]]+advisory|advisory[[:space:]]+for|deprecation[[:space:]]+notice|known[[:space:]]+cve|any[[:space:]]+cve|eol[[:space:]]+date)\b'

# Deprecation-status queries.
ORCH_SIG_QUESTION_DEPRECATION='\b(is[[:space:]]+[^[:space:]]{1,30}[[:space:]]+deprecated|are[[:space:]]+[^[:space:]]{1,30}[[:space:]]+deprecated|is[[:space:]]+[^[:space:]]{1,30}[[:space:]]+still[[:space:]]+supported|is[[:space:]]+[^[:space:]]{1,30}[[:space:]]+eol)\b'

# === Signal class map ===
# Maps each ORCH_SIG_* variable to a keyword that MUST appear in the YES
# signals table in skills/research-classifier/SKILL.md. The drift test reads
# this map and verifies: every YES-signal-class variable has a class label
# in the skill body.
#
# NOTE: ORCH_SIG_DESIGN_VERB is intentionally absent from this map. Design
# verbs are a *compose modifier* used only by the sniffer to combine with
# library/version/security signals — they aren't a YES signal class in their
# own right and don't appear as a row in the classifier's table. They're
# internal to sniffer routing.
#
# Format: one entry per line, "VARIABLE_NAME=KEYWORD".
# The keyword is matched case-insensitively against the skill body.
ORCH_SIGNAL_CLASSES_MAP='
ORCH_SIG_LIBRARY=library/SDK
ORCH_SIG_VENDOR=Vendor API
ORCH_SIG_VERSION=Version-shaped
ORCH_SIG_SECURITY=Security-sensitive
ORCH_SIG_ARCH=Architectural signal
ORCH_SIG_INVOCATION=Explicit user invocation
ORCH_SIG_QUESTION_VERSION=Installed-version lookup
ORCH_SIG_QUESTION_ADVISORY=Security advisory query
ORCH_SIG_QUESTION_DEPRECATION=deprecation
'
