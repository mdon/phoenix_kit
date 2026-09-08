# Claude Review — PR #794

**Title:** Point the Integrations sidebar tab at the renamed route
**Author:** timujinne
**Merge commit:** 9f085ac2
**Verdict:** Approve, merged with a manual CHANGELOG fix

## Summary

`AdminTabs`'s Integrations sidebar entry still pointed at
`/admin/settings/integrations/website`, the path 2.21.3 renamed to
`/admin/settings/integrations`. Verified against the live route table
(`lib/phoenix_kit_web/integration.ex:563-565`): the old URL does **not**
404 as the 2.21.3 release note expected — it matches
`/admin/settings/integrations/:uuid` with `uuid = "website"`. Confirmed the
crash path: `Queries.get_setting_by_uuid/1` calls `repo().get(Setting, uuid)`
(`lib/phoenix_kit/settings/queries.ex:35`) against a `UUIDv7` primary key —
Ecto raises `Ecto.Query.CastError` casting `"website"`, which LiveView turns
into a 400 `ReloadError` during connected mount, and the browser reloads into
the same broken URL — an infinite loop, exactly as described. Fix: one-line
change in `admin_tabs.ex` plus stale-doc corrections in `README.md` and
`AGENTS.md` from the same 2.21.3 rename.

## Findings

### BUG - HIGH: merging this PR as-is would have deleted the released 2.22.1 CHANGELOG section — fixed during merge

The PR branch's own "merge main into branch" commit (`5ad4d533`) predates
main's `2.22.1` tag cut. When that commit resolved its `CHANGELOG.md`
conflict, it kept the *branch's* version of the top section (still headed
`## Unreleased`, holding only this PR's "Fixed" entry) instead of the
already-released `## 2.22.1` content newly on `main`. Since `main` hasn't
touched `CHANGELOG.md` again since that point (`ab20d686` only bumped
`mix.lock`), a plain `git merge` / `gh pr merge --merge` of PR #794 into
current `main` would apply that same resolution — no conflict is even
reported, since `main`'s tree is identical to the merge-base for this file —
and `2.22.1`'s "Tabs on the Media settings page" / "Public Edit link API"
entries would vanish from `CHANGELOG.md` entirely, even though 2.22.1 is
already published to Hex.

Caught by dry-running the merge (`git merge --no-commit`) before committing
and diffing the result against `HEAD`. Resolved by hand: restored the
`## 2.22.1` section, and put this PR's "Fixed" entry under a new
`## Unreleased` heading — combined with PR #793's own entry, which had a
related but different placement bug (see `793-users-pagination`'s review).
The four code/doc files (`admin_tabs.ex`, `README.md`, `AGENTS.md`) merged
cleanly with no such issue.

**Takeaway for future PRs:** a contributor branch that merges `main` once and
then sits open across a release cut will silently regress `CHANGELOG.md` on
final merge, because git sees no conflict — `main`'s side already matches
what the stale merge commit "resolved" to. Always diff a merge dry-run
against `CHANGELOG.md` specifically when a PR's branch-age spans a version
bump.
