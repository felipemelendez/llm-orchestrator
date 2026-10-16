# Landing rules

How ticket work is cut, reviewed and landed on a long project with several
agents in one repository. Rules 1, 3, 4, 8 and 10 are guidance, apart from
rule 3's hard stop: the agent decides what the project needs, and
nothing limits the number of branches, blocks a dispatch or nags. Rules 2, 6 and 7 say how a review ends and lands, and the
review script enforces their dispositions. Rules 5 and 9 protect other
agents' work and are always followed.

Words used below: `<main>` is the repository's default branch. `<base>` is
the branch a pull request points at: `<main>`, or the open branch it is
stacked on. `origin/<x>` is that branch's fetched remote ref; in a repository
with no remote, read it as the local `<x>` and skip the fetch. A branch's
owner is the pull request's author, or whoever pushed the branch when there
is no pull request yet.

## The rules

1. **One branch per piece of work, opened when the work starts.** After its
   first commit, open it as a draft pull request (`gh pr create --draft
   --base <base>`, the worktree step does this; a normal pull request
   titled `WIP:` where the plan offers no drafts) so others can see it and
   build on it. A draft stays a draft as long as it needs to. Teams that
   deliver well keep few branches open and land often; they get there by
   landing (rules 2 and 8), never by counting. `gh pr list --json
   number,baseRefName,author,isDraft,reviewDecision` shows every open pull
   request with its base, owner, draft state and review state; the
   board at session start lists the local branches not yet on `<main>` by
   commit, so a squash-merged branch stays listed until its local branch is
   deleted.

2. **A READY verdict is a landing event.** READY, READY-WITH-FIXES with its mild
   findings handled, or NOT-READY with every blocking finding recorded
   `refuted`, `settled` or `follow-up`: land it now, in this session, through
   `finishing-a-branch` (option 1, or a local merge when the person picks
   it). Landing means as far as you can take it: mark the pull request ready
   (`gh pr ready <n>`, unless the person wants it kept a draft) and, when
   merging is authorized and it points at `<main>`, turn on auto-merge
   (`gh pr merge <n> --auto --merge`): GitHub merges it once its checks pass,
   or puts it in the merge queue, and the agent moves on to other work
   instead of waiting. Auto-merge waits only for checks the repository
   requires (branch protection or a ruleset); without that, or without
   auto-merge, merge it when `gh pr checks <n>` is all green. A stacked pull request waits for its base and is merged once it
   points at `<main>`; a READY branch another agent owns is theirs to land.
   When merging is not authorized, opening the pull request is the half of
   the landing the agent owns; it then stops and reports the URL. The
   verdict is bound to the head it reviewed: after it, the only commits
   allowed are the mild-finding fixes and a pushed merge of `origin/<base>` with
   green checks; a merge that needed conflict resolution gets one scoped Standard
   review of the resolution diff. Anything else is new work, which goes to a
   follow-up pull request, and a READY head is never reviewed again unless
   a fix changed behaviour.

3. **Build on `<main>`, or on the open branch the work depends on.** When a
   ticket needs code still on another open branch, branch from it and point
   the pull request at it. Keep stacks shallow and land the bottom first.
   Merge a branch that has others stacked on it with a merge commit. Ask
   the person to turn on the repository setting that deletes merged branches
   (`gh repo edit --delete-branch-on-merge`; `gh repo view --json
   deleteBranchOnMerge` shows it): once a pull request is `MERGED`, GitHub
   then points the pull requests stacked on it at `<main>` by itself. Without that setting, or when a merged branch is kept, each
   dependent's owner retargets their own pull request with
   `gh pr edit <m> --base <main>` (rule 5). A stacked pull request is never merged
   into its base branch, by pull request or locally; this is a hard stop,
   not guidance. If the repository has GitHub's own stacked pull
   requests turned on, use them. Never copy another branch's commits in by
   hand and never redo a sibling's change on your branch; stack on it.
   Editing a file another open branch also touches, for your own change, is
   fine: whoever lands second resolves. When two tickets need the same
   shared change, whoever needs it first opens a small pull request for it
   and the other stacks on that.

4. **Say what a ticket builds on.** A plan's `Requires landed:` line names the
   branch or pull request this ticket depends on, or "none". It is landed
   when, after `git fetch origin`, `git merge-base --is-ancestor <sha>
   origin/<main>` is true (the local `<main>` with no remote) or its pull
   request is `MERGED` in `gh pr view <n> --json state` (a squash or rebase
   merge); then build on `<main>`. Otherwise stack on it as rule 3 says. A
   dependency whose pull request is `CLOSED` without a merge, or that comes
   from a fork (`isCrossRepository`), cannot be stacked on: build on
   `<main>` and say so in the pull request body. If your branch already
   stacked on it, start a new branch from `origin/<main>`, cherry-pick only
   your own commits onto it, open a new pull request, and close your old one;
   never carry the abandoned commits to `<main>`. A change to a shared hub file (the project's laws name them) is easiest to
   land first on its own; that is the usual order, not a gate. A hotfix
   branches from `<main>` and lands ahead of any stack.

5. **Keep your own open branches current, bottom up.** After a landing on
   `<main>`, fetch, then merge `origin/<main>` into each still-open branch
   you own that builds on `<main>`, then each updated parent into its own
   stacked children, and
   run the checks, so no branch is ever more than one landing behind and
   conflicts are resolved while small. Never rebase a pushed branch. A
   branch someone else owns is updated by its owner at the next touch; a
   kept draft is updated when someone next works on it. When your base was
   squash-merged, fetch and merge `origin/<main>` in; at each conflict keep
   your side only where `origin/<main>` holds your base's squashed lines, and
   take `origin/<main>`'s where a later landing changed them; then check that
   `git diff origin/<main>...HEAD` shows only your own change and remove
   anything else, which is the base's old content that `<main>` has since
   changed. When your base was force-pushed, a merge alone would keep
   commits its owner dropped: comment on their pull request asking what
   changed, hold only the merge of that base, and keep working on anything
   else. At session start, for each of your pull requests that merged
   since: pull `<main>`, run the full suite on it (red: fix it in a new pull
   request, or label it `needs-person`), then run this rule's update. And for
   each pull request of yours whose base
   is landed by rule 4's test: make sure it points at `<main>`, fetch and merge
   `origin/<main>` in, run the checks, and finish it if its verdict still stands.

6. **The review loop ends on evidence, not on a count.** Each landing starts
   with one whole-branch review against the merge base with `<base>`
   (`--base origin/<base>`), after `origin/<base>` has been merged in, never on a scoped
   diff of the last fix. Then rounds: in each, one implementer fixes every
   open finding (one fix wave with the whole list, never one fixer per
   finding), and one scoped re-review checks the fix diff (`--base` at the
   head the previous review saw).
   - A round made progress when its review found at least one new reproduced
     finding, or a blocking finding was fixed and its failing check now
     passes. Rounds continue while they make progress.
   - A round with no new reproduced finding and no new green check is a
     stall. Stop there and adjudicate: one written disposition per open
     finding (`fixed`, `refuted`, `settled`, `follow-up`, or `ignored` by the
     person), then land or split. Never run the same review again hoping for
     a different answer.
   - A small fix gets a Standard re-review, not a Full one. A fix is small
     when all three hold: (1) every finding it answers has a regression test
     that failed before the fix and passes after it; (2) it touches only the
     lines the findings name and their tests: no new function, option, field
     or file, and no behaviour beyond the finding; (3) the production diff
     (shipped files, tests excluded) is under twenty lines. It gets one
     scoped Standard review of its diff (`orch-review.py run --path standard
     --base <the head the previous review saw>`: one independent built-in
     reviewer, no refuter), and the controller also reads the whole diff and
     runs each regression test without the fix to see it fail. A finding
     that review raises is handled like any other finding. A fix for a
     catastrophic finding, or any fix in a diff the security lens applies to
     (authentication, secrets, tokens, payments), always gets the Full
     re-review. The controller records each finding `fixed` with its test
     and writes one line in the outcome record that the fix was reviewed
     under the small-fix clause.
   - A reproduced finding is always fixed, never deferred, unless the person
     says otherwise. A branch never lands over a known reproduced defect,
     whatever the round.
   - After two rounds in a row whose re-review found new reproduced defects
     in the fix itself, stop patching: the fixes are the problem. One
     read-only diagnosis owner (`orch-debugger`, which never edits) finds why
     before any third fix wave, and the history goes to the person. Repairs
     and tests stay with one assigned implementer. The debugger's limit of
     three hypotheses is a separate rule.
   - A finding the re-review raises on untouched code is recorded, not fixed
     in another round, unless it is reproduced and blocking; then it is fixed
     like any other.
   - Reviews of single tasks during the build (`dispatching-subagents`) are
     for tasks the plan marks sensitive or Full; a routine task relies on the
     landing review.

7. **Reproduce to block.** A serious finding that was not reproduced (its
   repro passed on the unpatched copy, or it had none) is recorded
   `follow-up` with the reference of the pull request, issue or plan task
   that will carry it, and the branch lands. A security, privacy or
   data-integrity finding is deferred only when the person says so
   (`"person_approved": true`); not reproducing it does not disprove it. A
   reproduced finding showed the bug: it is fixed. Catastrophic and unranked
   findings reach the person. Mild findings are fixed in the next fix wave
   or recorded with a reason. A `BLOCKED` with one specific question is a
   good outcome at any step; a READY or PASS that is not true is the worst.

8. **Keep each pull request small and land what is green.** A change that is
   one thing is reviewed faster, merges sooner and conflicts less; about a
   hundred changed lines is a comfortable size and a thousand is too big.
   When a branch has grown past that, land the part that is green and put
   the rest in a follow-up pull request, stacked on it if it depends on it.

9. **Nobody edits another agent's branch or pull request.** Each writer works
   on its own branch or worktree. A branch or pull request another agent or
   person owns: build on it, comment on it, or ask, but do not push to it,
   retarget it or edit it; if your branch already has their pull request,
   open your own from a new branch. Within one orchestrator, the parallel
   dispatch skill partitions files so writers do not collide.

10. **Never wait on a person to keep building.** When something needs the
   person's decision, comment on the pull request, add the `needs-person`
   label (`gh pr edit <n> --add-label needs-person`; create it once with
   `gh label create needs-person` if it is missing), and move on to other
   work. `gh pr list --label needs-person` is everything waiting on them.
   Only merging without authorization and deferring a security finding
   wait for their yes.

## Why

Small, frequent merges are the measured property of teams that deliver well
(DORA's trunk-based development page; Google's engineering practices on small
changes). GitHub supports stacking: it retargets a pull request to its base's
base when the base merges and its branch is deleted, and a merge queue tests
each queued change against `<main>` plus what is ahead of it, so a stacked
pull request joins the queue once it points at `<main>`. A reviewer asked
again finds something again, and a round with no new outside evidence corrects
nothing, so only reproduced findings extend the loop and a stall is
adjudicated, not rerun.

Sources: https://dora.dev/capabilities/trunk-based-development/ ;
https://google.github.io/eng-practices/review/developer/small-cls.html ;
https://github.blog/changelog/2020-05-19-pull-request-retargeting ;
https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/merging-a-pull-request-with-a-merge-queue ;
https://docs.github.com/en/pull-requests/get-started/about-stacked-prs
