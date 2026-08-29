# Claude Review — PR #758

**Title:** Verify config.exs splices parse and land before adopting them
**Author:** timujinne
**Merge commit:** `b5d36bec` (parent `201a76b0`)
**Reviewer:** Claude (AI)
**Verdict:** Approve — no bugs found

## Summary

Adds `PhoenixKit.Install.ConfigVerify`, a shared parse-then-verify-then-rollback
primitive, and wires it into every regex-based `config.exs`/`application.ex`
splice in `oban_config.ex`, `boot_hook.ex`, `phoenix_kit.update.ex` (Ueberauth
fix), and `runtime_detector.ex` (dev-mailer guard). A candidate produced by a
regex replace/splice is now parsed with `Code.string_to_quoted/1` and checked
against an AST predicate that confirms the *specific* change landed in the
*right place* (not just that some valid Elixir came out) before it's accepted;
otherwise the original content is kept and a manual-fallback message is printed.

Also fixes several real bugs uncovered while building the safety net:

1. **Buffer-vs-disk read** (`boot_hook.ex`, Ueberauth fix in `phoenix_kit.update.ex`):
   both used to read the target file from disk and unconditionally overwrite the
   Igniter buffer with a candidate built from that stale read, silently
   discarding whatever an earlier step in the same `mix phoenix_kit.update`/`install`
   pipeline had already staged for the same file (e.g. `PrefixConfig`'s prefix
   backfill, `ApplicationSupervisor`'s supervisor wiring). Fixed to decide from
   `Rewrite.Source.get(source, :content)` inside the `Igniter.update_file/3`
   callback.
2. **Unanchored `plugins:`/`crontab:` regex** (`oban_config.ex`): several splices
   matched the *first* `plugins:`/`crontab:` list anywhere in `config.exs`,
   which could belong to a different application entirely if one appeared
   earlier in the file — landing (and reporting success) in the wrong app's
   config while the target app's own Oban config stayed untouched. Fixed by
   anchoring the regex to `config :app_name, Oban` and scoping the semantic
   check the same way (`ConfigVerify.app_config_satisfies?/5`).
3. **Unconditional leading comma** (`add_worker_entries_to_crontab/3`,
   `add_digest_entries_to_crontab/3`, `add_scheduled_posts_job_to_crontab/2`):
   always prepended `,\n` before new entries, producing a double comma (parse
   failure) when the existing crontab's last entry already ended in a comma —
   an entirely ordinary `mix format` output shape. Fixed with a
   `has_trailing_comma` check.
4. **Unanchored lazy match** in `add_scheduled_posts_job_to_crontab/1`: the one
   crontab-splice helper still using an un-anchored `.*?` instead of the
   same-indentation-close backreference pattern its siblings use. An ordinary
   comment containing `]` produced a `MismatchedDelimiterError`; a nested list
   value (`args: %{tags: [...]}`) produced something that still parsed but
   landed the new entry inside the wrong list. Both are now caught by
   `ConfigVerify.verify_or_rollback/3` and anchored/scoped like the rest.

## Review notes

Traced the `ConfigVerify.app_config_satisfies?/5` scoping against every call
site that uses it (`plugins_contains_module?/3`, `crontab_contains_module?/3`,
`crontab_has_all_modules?/3`, `crontab_has_all_digest_cadences?/3`) and
confirmed each splice's regex anchor and its paired semantic check are scoped
to the *same* `app_name`, so a check can't report success against a
neighbouring application's block. Specifically verified
`add_cron_plugin_to_plugins/2` (oban_config.ex:1275), which inserts a *new*
`{Oban.Plugins.Cron, crontab: [...]}` tuple into `plugins:` but is verified
with `crontab_contains_module?/3` (checks the `crontab:` key, not `plugins:`)
— at first glance a mismatched check, but `app_config_satisfies?/5` walks the
*entire* app's `opts` subtree for `root_key`, so it correctly finds the
`crontab:` nested inside the newly-added Cron plugin tuple. This is exercised
directly by the "Case 4 (no Cron plugin yet)" test in `oban_config_test.exs`.

Checked `ConfigVerify.verify/2`'s two failure branches (`:syntax` vs
`:semantic`) are both exercised by tests, and that every `{:rolled_back, ...}`
branch at every call site returns the *original* content rather than the
(rejected) candidate — a rollback that silently kept the corrupted candidate
would defeat the entire mechanism. All checked out.

The moduledoc's own "What this deliberately does NOT cover" section (JS/HEEX/
CSS splices in `js_integration.ex`/`css_integration.ex` stay regex-only, since
`Code.string_to_quoted/1` only understands Elixir) is accurate — confirmed
both files only gained explanatory comments, no functional change, in this PR.

No CRITICAL/HIGH/MEDIUM bugs found. Test coverage is unusually thorough for
this kind of fix: neighbour-non-interference, both mutation shapes (parse
failure vs. silent misplacement), idempotency, and the trailing-comma
regression are all exercised with dedicated tests rather than just the happy
path.

## Findings

None requiring a fix. Two sub-MEDIUM observations, left as-is:

- **NITPICK** — `ConfigVerify.to_app_atom/1` uses `String.to_atom/1` (not
  `String.to_existing_atom/1`) on a caller-supplied `app_name`. Normally an
  atom-exhaustion smell, but this only runs inside `mix phoenix_kit.install`/
  `update` at install time against the developer's own `mix.exs` app name —
  not attacker-reachable input — so tightening it would be defense against a
  threat model that doesn't apply here. Not fixed.
- **NITPICK** — the Ueberauth regex fix path is the only splice that doesn't
  scope its match to a specific app (`config :ueberauth, Ueberauth, providers: [...]`
  is inherently singular — Ueberauth isn't configured per-app the way Oban is),
  so no neighbour-collision risk exists there. No change needed.

## Files reviewed

`lib/mix/tasks/phoenix_kit.update.ex`, `lib/phoenix_kit/install/boot_hook.ex`,
`lib/phoenix_kit/install/config_verify.ex` (new),
`lib/phoenix_kit/install/css_integration.ex`,
`lib/phoenix_kit/install/js_integration.ex`,
`lib/phoenix_kit/install/oban_config.ex`,
`lib/phoenix_kit/install/runtime_detector.ex`,
`test/mix/tasks/phoenix_kit_update_ueberauth_test.exs` (new),
`test/phoenix_kit/install/boot_hook_test.exs` (new),
`test/phoenix_kit/install/config_verify_test.exs` (new),
`test/phoenix_kit/install/oban_config_test.exs`.

No code changes applied — the PR is correct as merged.
