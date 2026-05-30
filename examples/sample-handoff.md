---
revision: 2
last_regenerated_at: 2026-05-30T18:42:00Z
trigger: tier-boundary
context_estimate_pct: 56
slug: ble-test-infra
plan: docs/llm-orchestrator/plans/2026-05-30-ble-test-infra-plan.md
spec: docs/llm-orchestrator/specs/2026-05-30-ble-test-infra-spec.md
---

# Handoff: BLE test infrastructure

**Status:** Mid-flight. The previous agent landed substantial work but ran low on context. Read this document top to bottom before touching any code or running any command.

## Mission carried over

> "Make this the best app in the fucking planet. Do not cut corners, deploy many agents to help you do research to ensure that we are doing things following best current practices and that every decision is backed by research. Built the best infrastructure on the world and make sure that this BLE feature and its test suites for both ios and android are solid and world class. When you're done, deploy several review agents, address any issues found, and continue reviewing and addressing issues until the system is perfect."

Quality bar: World-class — every BLE-touching code path tested or documented as untestable, mutation testing verifies the tests catch real bugs, coverage thresholds enforce ratchet-up-only in CI, and three independent specialist review agents return PASS before anything ships.

## Memory index

**CLAUDE.md sections in scope:**
- `## Working rules` (lines 9-18) — defines the plan-before-implement, verify-before-done, and /dispatch routing rules that govern all agent work
- `## Skills` (lines 20-24) — two-key frontmatter constraint; skill bodies under 200 lines; triggers must start with "Use when"

**Project memory files (read in this order before writing any code):**
- `~/.claude/projects/-<user>-project/memory/feedback_never_run_pod_install.md` — never run `expo prebuild`, `pod install`, `xcodebuild` (app build), or `eas build`; tests ARE allowed; user runs prebuild when asked
- `~/.claude/projects/-<user>-project/memory/reference_ble_module_tests.md` — exact commands for `swift test`, standalone kotlinc, and `npx jest`; contains 10 documented pitfalls in the Pitfalls section; read before any Kotlin invocation
- `~/.claude/projects/-<user>-project/memory/feedback_world_class_code.md` — DRY non-negotiable; single owner for every derivation; no copy-paste logic
- `~/.claude/projects/-<user>-project/memory/feedback_no_shortcuts.md` — no `@ts-ignore`, no ambient stubs, no `any` shortcuts; install proper types
- `~/.claude/projects/-<user>-project/memory/feedback_never_commit.md` — never `git commit` without explicit user instruction
- `~/.claude/projects/-<user>-project/memory/feedback_native_code_care.md` — native rebuilds cost hours; verify Swift/Kotlin by running pure-logic tests + careful diff review before handing off

**Architecture decisions:**
- `ios-pure-logic-symlink` — every new iOS pure-logic file needs a symlink in `Tests/Sources/ExpoBlProximityPureLogic/`; omitting it silently hides the file from the SwiftPM target
- `zod-mini-not-full` — use `zod/mini` import (1.9KB gz, Hermes #5070 fix in ≥4.0.17) not full zod; hot-path `onDiscoverPeripheral` deliberately left unwrapped
- `ast-grep-cli-not-napi` — use `@ast-grep/cli` invoked by absolute `require.resolve` path; `@ast-grep/napi` lang-swift/kotlin packs are immature 0.0.x

## Plan state

**Plan file:** `docs/llm-orchestrator/plans/2026-05-30-ble-test-infra-plan.md`

**Current tier / task:** Tier 5, Task 1 — Android port injection (blocked on `expo prebuild`)

**Checkpoint counts (reconciled at regeneration):**
- Completed: 4 of 8 task-heading checkboxes ticked in the plan file (Tiers 1–4)
- In-flight: 0 tasks active (Tier 5 is blocked pending user-run prebuild)
- Pending: 4 task-heading checkboxes unticked (Tiers 5–8)

**Next action:** User runs `expo prebuild` once, then a fresh agent opens Tier 5 (Android port injection), verifies via `./gradlew :expo-ble-proximity:testDebugUnitTest`, then continues to Tier 6 (iOS protocol layer).

## Active task context

**Files in play for the next action** (touch these first to execute Tier 5 Android port injection):

| Path | Lines | Why |
|------|-------|-----|
| `modules/expo-ble-proximity/android/src/main/java/expo/modules/bleproximity/BleProximityModule.kt` | L112–L158 | Port-injection entry point: add the `portOverride` parameter handling and delegate to `BlePortDecision` |
| `modules/expo-ble-proximity/android/src/main/java/expo/modules/bleproximity/BlePortDecision.kt` | — | New file: pure-logic decision struct mirroring the Swift `BlePortDecision.swift` pattern |
| `modules/expo-ble-proximity/android/src/test/java/expo/modules/bleproximity/BlePortDecisionTest.kt` | — | New file: unit tests for `BlePortDecision`; run via standalone `kotlinc` (not `./gradlew`) |
| `modules/expo-ble-proximity/ios/Tests/Sources/ExpoBlProximityPureLogic/` | — | Symlink directory — check that `BlePortDecision.swift` has a symlink here before running `swift test` |

**Key technical concepts in play:**

- `ios-pure-logic-symlink` — every new iOS pure-logic file needs a symlink in `Tests/Sources/ExpoBlProximityPureLogic/`; omitting it silently hides the file from the SwiftPM target and produces a misleading "type not found" error at the test site, not the source site. See architecture decisions in Memory index.
- `Swift pure-logic decision structs + symlink test pattern` — the iOS tier uses value-type `struct` decision objects with no UIKit/CoreBluetooth imports so they can be tested under SwiftPM without a simulator. The Android port mirrors this: `BlePortDecision.kt` must be a pure Kotlin class with no Android framework imports so it can be compiled standalone via `kotlinc`. See CLAUDE.md `## Working rules` for the verify-before-done rule that applies here.
- `standalone kotlinc, not ./gradlew` — Gradle requires a prebuild-generated tree that does not exist yet. All Android pure-logic tests for Tier 5 must be compiled and run via the `kotlinc -cp ...` invocation documented in `reference_ble_module_tests.md` (Memory index, item 2). Do not invoke `./gradlew` until the user confirms `expo prebuild` is complete.

**Re-hydration pointer:**

If this artifact proves insufficient, the full prior context lives in: (1) `git log -p <path-to-this-artifact>` — every prior version of this artifact is in git history; (2) the prior session transcript linked from the plan file's `## Session log` section.

## Recent agent reports

**Report 1 (iOS Swift reviewer, 2026-05-30):**

```
Status: DONE
Summary: Reviewed Tier 2 useBleProximitySession extraction — no BLOCKING findings.
Changed:
- modules/expo-ble-proximity/ios/WillRestoreStateDecision.swift:47 — typo fix:
  testNoRestoredUUID_butJsHasOne_doesNothing (was `bu` → `but`)
- modules/expo-ble-proximity/ios/ExpoBlProximityModule.swift:312 — replaced
  unsafe iBeaconDict! force-unwrap with defensive `if let iBeaconDict = ...`
  in peripheralManagerHandleCurrentState .advertiseAsIBeacon branch
Verify:
- cd /path/to/project/modules/expo-ble-proximity/ios/Tests && swift test →
  "Test Suite 'All tests' passed ... 68 tests passed"
```

**Report 2 (Android Kotlin implementer, 2026-05-30):**

```
Status: DONE_WITH_CONCERNS
Summary: Tier 3 Layer 1 ast-grep contract test landed; 3 tests pass.
Concerns:
- @ast-grep/cli resolves via require.resolve at runtime — if node_modules is
  pruned in CI the absolute path breaks. Mitigated by referencing
  node_modules/.bin/sg as a fallback in the test helper.
Changed:
- front/utils/__tests__/proximityErrorCodes.contract.test.ts:1 — new file,
  3 bidirectional contract tests using @ast-grep/cli sg scan
- tools/contract/sg-config.yml:1 — new ast-grep config root
- tools/contract/sg-rules/swift-reject-codes.yml:1 — Swift rule: reject() call
  second-arg must be a key present in BLE_PROXIMITY_ERROR_CODES
- tools/contract/sg-rules/kotlin-reject-codes.yml:1 — same for Kotlin throw
Verify:
- cd /path/to/project && npx jest --testPathPattern="proximityErrorCodes.contract" →
  "3 passed, 3 total"
```

**Report 3 (JS contract reviewer, 2026-05-30):**

```
Status: DONE
Summary: Tier 4 coverage tooling reviewed — jest.config.js thresholds verified
  honest (ratchet floors just below measured, not aspirational).
Found:
- jest.config.js:34 — coverageThreshold for useBleProximitySession.ts sets
  branches: 78 (measured 81.9%); correct ratchet floor, not the 85 target.
  This is intentional: Android PermissionsAndroid branch (lines ~182-197) is
  unreachable under jest ios default and is covered by the Kotlin suite + Tier 5.
  No action needed; add an inline comment documenting the exclusion reason.
- front/hooks/__tests__/useBleProximitySession.test.tsx:1 — 12 tests (7 spec +
  5 review-driven). All pass. Counts match the continuation-status block.
Verify:
- cd /path/to/project && npm run test:coverage -- --testPathPattern="useBleProximitySession" →
  "12 passed | Statements: 87.4% | Branches: 81.9% | Functions: 70.7% | Lines: 89.8%"
```

## In-flight observations

- `front/hooks/__tests__/useBleProximitySession.test.tsx:89` — the Android `PermissionsAndroid` branch (lines ~182-197 of `useBleProximitySession.ts`) is unreachable under jest's `ios` platform default; the coverage ratchet floor for branches is set to 78 to reflect this; a comment was added to the threshold block in `jest.config.js` citing this file and line. Will be resolved when Tier 5 lands Kotlin integration tests.
- `jest.config.js:34` — inline jest block fully migrated out of `package.json`; the old `"jest":{...}` key was removed from `package.json` in the same commit. If you see jest ignoring `collectCoverageFrom`, confirm there is no residual `"jest"` key in `package.json` (use `jq '.jest' package.json` — should return `null`).
- `modules/expo-ble-proximity/index.ts:201` — `withEventValidation` wrapper breadcrumbs on `safeParse` failure but never drops the event; hot-path `onDiscoverPeripheral` is deliberately unwrapped (documented in the `zod-mini-not-full` architecture decision above). Do not add zod validation to `onDiscoverPeripheral` without a performance budget from the research agent.

## Verification baseline

Run these in order before doing anything else. If any command diverges from the expected output, stop and debug before proceeding.

```bash
cd /path/to/project && npm run typecheck
```
Expected: `Found 0 errors. Watching for file changes.` (or process exits 0 with no error lines)

```bash
cd /path/to/project && npm run typecheck:unused
```
Expected: exit 0 with no output (zero unused exports detected)

```bash
cd /path/to/project && npx jest --testPathPattern="ble|proximity|analytics|firebase"
```
Expected: `Test Suites: N passed | Tests: 262 passed, 262 total`

```bash
cd /path/to/project/modules/expo-ble-proximity/ios/Tests && swift test
```
Expected: `Test Suite 'All tests' passed ... 68 tests passed`

```bash
# Standalone Kotlin pure-logic — see reference_ble_module_tests.md for the full invocation block
# (do NOT run ./gradlew without prebuild; do NOT run brew install kotlin)
kotlinc -cp ~/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-stdlib/*/kotlin-stdlib-*.jar \
  android/src/main/java/expo/modules/bleproximity/*.kt \
  android/src/test/java/expo/modules/bleproximity/*Test.kt \
  -include-runtime -d /tmp/ble-tests.jar && \
  java -jar /tmp/ble-tests.jar
```
Expected: `66 tests, 66 passed`

**Aggregate baseline at revision 2:** iOS Swift 68 / Android Kotlin 66 / JS 262 = **396 total tests**.

## Known gotchas

- **Symlink step on iOS pure-logic files** (`Tests/Sources/ExpoBlProximityPureLogic/`): the SwiftPM package manifest references this directory as a sources path, not the real `ios/` path. A new `.swift` file placed only in `ios/` will compile in the app but the SwiftPM test target will not see it and `swift test` will fail with "cannot find type in scope". Fix: always create the symlink immediately after creating the source file (`ln -s ../../ios/NewFile.swift Tests/Sources/ExpoBlProximityPureLogic/NewFile.swift`).
- **jest.mock hoisting** (`front/hooks/__tests__/useBleProximitySession.test.tsx:12`): jest hoists `jest.mock(...)` calls above `const`/`let` declarations. A mock factory that closes over an outer-scope variable will capture `undefined`. Fix: define the mock value inside the factory closure and retrieve the stable instance via `jest.requireMock('module').__exposedName` after the import block. Canonical examples in `front/components/__tests__/ProximityBanner.test.tsx` and `front/screens/__tests__/ProximityAcceptScreen.test.tsx`.
- **Do not run `brew install kotlin`** — the sandbox auto-denies it. The compiler is already cached at `~/.gradle/caches/modules-2/files-2.1/org.jetbrains.kotlin/kotlin-compiler-embeddable/`. Reference `reference_ble_module_tests.md` Pitfall #3 for the exact `-cp` classpath invocation.
- **`./gradlew` requires prebuild** (`modules/expo-ble-proximity/android/build.gradle`): the Gradle settings plugin resolves the React Native plugin from the prebuild-generated `android/` tree. Running `./gradlew :expo-ble-proximity:testDebugUnitTest` before prebuild fails with "Plugin [id: 'com.facebook.react'] was not found". Fix: user must run `expo prebuild` first; do not attempt this command until they confirm prebuild has completed.
- **zod import must be `zod/mini`** (`modules/expo-ble-proximity/index.ts:3`): full zod import adds ~14KB gz; `zod/mini` is 1.9KB and includes the Hermes engine fix from ≥4.0.17. If you see a type error importing from `zod/mini`, check that `zod@^4.4.3` is installed (not an older `zod@3.x` which has no `/mini` subpath).
- **Coverage threshold is a ratchet floor, not a target** (`jest.config.js:29-45`): thresholds are set just below the measured values at time of creation. Do not lower a threshold. When new tests raise coverage, update the floor upward to match. The `branches: 78` floor for `useBleProximitySession.ts` is intentional (see In-flight observations).

## What NOT to do

- Do not regress any of the existing 396 tests — every change must keep typecheck + typecheck:unused clean and all three suites green.
- Do not skip the symlink step when adding iOS pure-logic files — the SwiftPM target will silently miss the file and `swift test` will produce a misleading "type not found" error pointing at the test, not the missing source.
- Do not call `jest.mock` factories with outer-scope variable references — jest hoists `jest.mock` above `const`/`let`; the variable is `undefined` inside the factory.
- Do not change the `BLE_PROXIMITY_ERROR_CODES` catalog without updating the inline snapshot in `front/utils/__tests__/proximitySurface.snapshot.test.ts` — that snapshot IS the Layer 4 contract and the diff is the review surface.
- Do not run `brew install kotlin` — auto-denied by the sandbox; the compiler is already cached under `~/.gradle/`.
- Do not run `./gradlew` commands before the user confirms `expo prebuild` has completed — the Gradle settings plugin cannot resolve without the prebuild-generated tree.
- Do not add zod validation to the `onDiscoverPeripheral` hot path — it fires at 5-20 Hz × N peers; validation overhead would degrade scanning latency. Cold-path events only.
- Do not begin native refactors (Tiers 5-6) and hand off mid-tier — native code must be verified by running the new tests in the same session per the "native code = extreme care, never leave half-tested" rule.
- Do not assume the previous agent tested everything — run the verification baseline first and report the exact test count before proceeding.

## Resume prompt

```
Read these files in order before doing anything else:

1. /path/to/project/docs/llm-orchestrator/examples/sample-handoff.md  ← this artifact
2. docs/llm-orchestrator/plans/2026-05-30-ble-test-infra-plan.md
3. ~/.claude/projects/-<user>-project/memory/feedback_never_run_pod_install.md
4. ~/.claude/projects/-<user>-project/memory/reference_ble_module_tests.md
5. ~/.claude/projects/-<user>-project/memory/feedback_native_code_care.md

Context: Tiers 1-4 (all no-prebuild JS/TS work) are complete and verified at 396
total tests (iOS 68 / Android 66 / JS 262). Tier 5 (Android port injection) is
blocked pending expo prebuild, which the user is running now.

Resume from: Tier 5, Task 1 — Android port injection.

First action: run the Verification baseline section commands and confirm green (396 tests, typecheck clean). Only proceed after green. If any baseline command diverges from the expected output, invoke systematic-debugging before touching any code.

Go.
```

## Revision history (v1 → v2)

```diff
--- revision 1  (2026-05-30T14:15:00Z, trigger: user)
+++ revision 2  (2026-05-30T18:42:00Z, trigger: tier-boundary)

 ## Plan state
-**Current tier / task:** Tier 1, Task 1 — Write useBleAdvertisingDegradedListener.test.tsx
-Completed: 0 of 8  |  In-flight: 1  |  Pending: 7
+**Current tier / task:** Tier 5, Task 1 — Android port injection (blocked on expo prebuild)
+Completed: 4 of 8  |  In-flight: 0  |  Pending: 4

 ## Recent agent reports
-(only 1 report present — iOS Swift reviewer post-Tier 1)
+(3 reports: iOS Swift reviewer, Android Kotlin implementer, JS contract reviewer)

+**Report 2 (Android Kotlin implementer, 2026-05-30):** [new]
+**Report 3 (JS contract reviewer, 2026-05-30):** [new]

 ## Verification baseline
-Expected: iOS 68 / Android 66 / JS 221 = 355 total
+Expected: iOS 68 / Android 66 / JS 262 = 396 total

 ## Known gotchas
-(5 gotchas documented)
+(6 gotchas — added: "zod import must be zod/mini" resolved during Tier 3)
+- zod import must be `zod/mini` (modules/expo-ble-proximity/index.ts:3): [new]

 ## In-flight observations
-none
+- useBleProximitySession.ts:182 Android PermissionsAndroid branch unreachable under jest ios [new]
+- jest.config.js:34 inline block migrated from package.json; jq check added [new]
+- index.ts:201 withEventValidation hot-path exclusion documented [new]
```
