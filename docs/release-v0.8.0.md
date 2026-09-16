# v0.8.0 — cadence and Codex verification

Publication status: prepared for the open cadence pull request. The latest
published release remains v0.7.0 until this change is merged and released.

## Release notes

This release adds a project-enabled review cadence and Codex verification support.
Changes receive two independent reviews. When those reviewers agree, the refuter
is skipped; disagreement and one-sided catastrophic or serious findings receive
adjudication. Missing reviews never count as agreement.

Codex hooks record actual test execution through a dedicated runner, associate
the result with the tested source and check that completion claims have current
evidence. Native review events are recorded separately. Optional read-only Claude
reviews use the existing login and default to Opus at maximum effort. Grok is not
required. These provider and application-verification ideas were informed by
pstack while keeping cadence as the controller.

The release also includes the cadence initializer, project rule locks, commit
checks, independent gate procedures, installer improvements and regression tests
described in CHANGELOG.md. Project-specific app/device journeys remain in each
application repository.

### Installation and limits

Install the updated shared framework, then enable cadence separately in each
project. Existing projects retain their explicit rules; an update does not
silently rewrite locked project policies. Codex users must review and trust new
or changed hook definitions through `/hooks`.

The verification layer checks evidence, not complete application correctness.
Unperformed device checks remain pending. A fresh live Codex CLI session verified
the successful execution/reviewer/completion flow; live failure/refusal paths
remain distinguished from automated fixture coverage.

## Publish after merge

1. Merge PR #13 into `main` after its checks pass.
2. Verify the merged `main` commit passed CI and contains the intended changes.
3. Confirm the plugin and marketplace versions are both `0.8.0`, and that no
   published `v0.8.0` tag/release exists already.
4. Create `v0.8.0` at that verified merged commit and publish a GitHub release
   titled **v0.8.0 — cadence and Codex verification**, using the release notes
   above. Mark it as the latest stable release.
5. Preserve the v0.7.0 release history. Refresh local installations from a durable
   checkout before deleting any worktree referenced by installed hooks.

Do not publish or tag the unmerged feature branch as the stable release. This
file prepares the release; committing it does not publish a GitHub release.
