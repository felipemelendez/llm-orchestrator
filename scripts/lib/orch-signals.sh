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

# Structural library/dependency shapes — name-agnostic complement to the curated
# allowlist above. Matches import/require statements followed by a MODULE-PATH-
# SHAPED token (contains /  .  @  a quote or opening brace), any package-manager
# install invocation, or an IaC CLI tool name with a subcommand.
#
# Design decisions:
#   - "from" and "use" alone are NOT included: they fire on ordinary English
#     ("from the old module", "use the API key"). Only "import" and "require"
#     are listed, and they must be followed by a token with a module-path shape.
#   - Module-path shape for "import": token must start with @, {, *, ' or ",
#     OR start with a letter/digit and contain at least one of [./@:] to
#     distinguish module paths ("pandas.DataFrame", "@scope/pkg", "'redis'")
#     from plain English nouns ("contacts", "data", "records"). Bare single
#     words like "import contacts" are excluded by this requirement.
#   - "require" uses a separate branch that already enforces module-path shape
#     (scoped @, quoted, or dotted/slashed bare token).
#   - "from" is only matched when immediately followed by a quote character,
#     which means it only fires on `from 'module'` / `from "module"` forms —
#     not on prose "from the old module" or "from a manager".
#   - "sam" alone (person's name) is excluded; require "aws sam" prefix or
#     "sam (build|deploy|init|local|package|publish|validate)" to match IaC use.
#   - \x27 dead-byte sequences removed; literal ' used where needed.
#
# Pattern 1 — import + module-path-shaped token (@ { * quote, OR word with ./@/:)
# Pattern 2 — require + module-path-shaped token
# Pattern 3 — from + immediate quote (from 'x' / from "x")
# Pattern 4 — package-manager install verbs (npm, pnpm, yarn, pip, poetry,
#              cargo, go, gem, bundler, composer, apt, brew)
# Pattern 5 — IaC CLI tools (terraform, kubectl, helm, ansible, pulumi, cdk,
#              serverless) + any subcommand; sam only with aws prefix or known
#              subcommands
ORCH_SIG_LIBRARY_STRUCTURAL='\bimport\s+(@[a-z0-9_-]|[{*'"'"'"][[:space:]a-z*]|[a-z][a-z0-9_-]*[./@:][a-z0-9_./@:-]*)|\brequire\s+(@[a-z0-9_-]|['"'"'"][a-z]|[a-z][a-z0-9_-]*[/.@][a-z0-9_./\\@-]*)|\brequire\s*\(\s*\\?['"'"'"]|\bfrom\s+['"'"'"]|\b(npm(\s+(i|install))?|pnpm\s+add|yarn\s+add|pip3?\s+install|poetry\s+add|cargo\s+add|go\s+get|gem\s+install|bundle\s+add|composer\s+require|apt(-get)?\s+install|brew\s+install)\b|\b(terraform|kubectl|helm|ansible|pulumi|cdk|serverless)\s+\w+|\baws\s+sam\s+\w+|\bsam\s+(build|deploy|init|local|package|publish|validate)\b'

# Dotted CapitalizedName pattern — must run against ORIGINAL-case prompt.
# Matches patterns like Foo.Bar, Pandas.DataFrame, TensorFlow.keras, etc.
ORCH_SIG_LIBRARY_STRUCTURAL_DOTTED='\b[A-Z][a-zA-Z0-9]+\.[a-zA-Z]'

# Vendor SaaS platforms — subset of LIBRARY but maintained separately so the
# classifier can prefer "vendor MCP" over "doc aggregator" for their APIs.
ORCH_SIG_VENDOR='\b(stripe|cloudflare|vercel|auth0|supabase|firebase|netlify)\b'

# Version-shaped tokens.
# Matches: v-prefixed numbers (v4, v1.2.3), dotted semantic versions (3.12, 1.0.0),
# comparator-prefixed specifiers (>=1.55, ^7, ~2, ==1.0, <=5.0),
# and the literal word "version" followed by a number (version 2.0).
# The loose \b[a-z]+[[:space:]]+v?[0-9]+\b alternative has been removed to
# eliminate false positives on "step 2", "phase 3", "top 5", "task 4".
ORCH_SIG_VERSION='(\bv[0-9]+(\.[0-9]+)*\b|\b[0-9]+\.[0-9]+(\.[0-9]+)*\b|(>=|<=|==|~|\^)[[:space:]]*[0-9]|\bversion[[:space:]]+[0-9])'

# Security-sensitive verbs and nouns.
# Used by the research gate (design-shape compel branch) — whole-word boundary
# required here so that bare prose doesn't fire.
ORCH_SIG_SECURITY='\b(auth|crypto|payment|secret|jwt|oauth|password|encryption|tls|ssl|webhook)\b'

# Looser security pattern for diff-scanning in review Stage 3.
# Stage 3 is advisory and should fail toward running; substring matching on
# compound identifiers (checkAuth, hashPassword, bcrypt, encryptData, JWTToken)
# is intentional. Short tokens that create false positives at substring level
# (tls, ssl) remain word-bounded.
ORCH_SIG_SECURITY_DIFF='(auth|crypt|payment|secret|jwt|oauth|password|encrypt|webhook)|\b(tls|ssl)\b'

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

# Self-referential / local-state suppressor. A version question about the
# orchestrator plugin itself (or "this plugin") is answerable by reading
# on-disk files — it needs no upstream-docs research pass. When this matches,
# the installed-version question branch does NOT compel the gate. It is a
# suppressor, not a compel signal: it never appears in the signal-class map.
# It is intentionally narrow so library lookups ("what version of openssl is
# installed") still compel.
ORCH_SIG_LOCAL_SELF_LOOKUP='\b(llm-orchestrator|llm[[:space:]]+orchestrator|this[[:space:]]+plugin|the[[:space:]]+orchestrator[[:space:]]+plugin)\b'

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
