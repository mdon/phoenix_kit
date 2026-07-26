# PR #662 — Installer/doctor: ship Oban.Plugins.Lifeline to host apps

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-25
**Verdict:** ⚠️ APPROVE WITH FIXES — already merged. One HIGH bug in the shipped
plugin option, one MEDIUM crash in the touched doctor check, one MEDIUM latent
bug of the same class the PR fixed in a sibling function. All three fixed
post-merge.

---

## Summary

Adds `Oban.Plugins.Lifeline` to the Oban config PhoenixKit generates for host
apps, backfills it into existing host configs on `mix phoenix_kit.update`, and
adds a `mix phoenix_kit.doctor` warning when a host's running Oban config lacks
it. Motivation is sound: without Lifeline, a job orphaned in `:executing` by a
hard crash (`kill -9`, OOM, node loss) never returns to `:available`, and for a
unique worker whose `states:` includes `:executing` it also permanently blocks
every future insert for that worker.

The insertion machinery is the interesting part: `ensure_lifeline_plugin/2`
rewrites `config/config.exs` textually, and the PR already self-corrected one
review round (anchoring the plugins-block close to the `plugins:` keyword's own
indentation so a lazy match can't stop inside the Cron plugin's nested
`crontab: [...]`). That correction is right and well tested.

## Files changed (3)

| File | Change |
|---|---|
| `lib/phoenix_kit/install/oban_config.ex` | +86/−4 — Lifeline in the generated template (×2 sites), new public `ensure_lifeline_plugin/2`, wired into the `update_existing_oban_config/3` chain |
| `lib/mix/tasks/phoenix_kit.doctor.ex` | +20/−2 — `check_oban_config/1` now warns when Lifeline is absent |
| `test/phoenix_kit/install/oban_config_test.exs` | +118 — 7 tests for `ensure_lifeline_plugin/2` |

## Verification performed

- **The doctor's remediation advice is reachable.** The warning says "Run
  `mix phoenix_kit.update`". Traced `update.ex:1617` →
  `validate_and_add_oban_config/2` → `ObanConfig.add_oban_configuration/2`
  unconditionally (not gated on `config_exists`) →
  `oban_config_already_exists?/2` → `update_existing_oban_config/3` → the new
  `ensure_lifeline_plugin/2`. Confirmed: a host that already has Oban config —
  exactly the case that triggers the warning — does get the backfill.
- **Chain ordering is correct.** `ensure_lifeline_plugin/2` runs *after*
  `ensure_cron_plugin/2`, so when both are missing, Cron's nested `crontab: [...]`
  is already present when Lifeline's anchored regex runs. The anchoring handles
  it (covered by the PR's own test).
- **The indentation backreference holds against nested closes.** With
  `plugins:` at 2 spaces, the generated Cron entry's close is `     ]}` (5
  spaces); `\n\2\]` demands `\n` + exactly 2 spaces + `]`, which fails on that
  line and correctly walks on to the real block close. Verified by hand against
  both the 2-space and 4-space fixtures.
- **`lifeline_plugin_configured?/1` matches both entry shapes.** Bare
  `Oban.Plugins.Lifeline` and `{Oban.Plugins.Lifeline, opts}` are the only two
  forms Oban accepts in `plugins:`; both are covered.
- **Regression risk of `String.replace/4` with a binary pattern:** none. The
  replacement is treated literally for binary patterns (backslash escapes are
  only interpreted for `Regex` patterns), so a config containing `\1`-looking
  text can't corrupt the rewrite.

---

## BUG - HIGH — `rescue_after: :timer.minutes(30)` is at/below PhoenixKit's own longest job, so Lifeline rescues live jobs

**Where:** `lib/phoenix_kit/install/oban_config.ex` (generated template ×2,
`ensure_lifeline_plugin/2` insertion string, manual-fallback message) and
`lib/mix/tasks/phoenix_kit.doctor.ex:683` (the advice text).

Lifeline rescues **purely by elapsed time**. It never checks whether the node
executing the job is still alive. Oban's own moduledoc is explicit
(`deps/oban/lib/oban/plugins/lifeline.ex`):

> This plugin may transition jobs that are genuinely `executing` and cause
> duplicate execution.

so `rescue_after` is a safety margin that must sit **above the longest job the
system can legitimately run**. Oban's default is 60 minutes. This PR ships 30.

PhoenixKit itself ships a worker with a **30-minute** timeout:

```elixir
# lib/modules/storage/workers/sync_files_job.ex:54
def timeout(_job), do: :timer.minutes(30)
```

So the shipped `rescue_after` equals the longest *sanctioned* runtime in the
library — zero margin, by construction. Two distinct failure modes:

1. **`SyncFilesJob` (`max_attempts: 1`).** Lifeline discards rather than
   re-runs a job whose attempts are exhausted, so at the 30-minute mark a
   genuinely-running media sync is flipped `executing → discarded` while its
   process keeps working. No duplicate run, but the job row now lies about
   what the system is doing, and the Health LiveView's `:persistent_term`
   progress state is left contradicting the queue.
2. **Every worker with no `timeout/1` callback** — which is all of them except
   `SyncFilesJob` (30 min), `ProcessFileJob` (5 min) and
   `Sitemap.SchedulerWorker` (10 min). Oban's default timeout is `:infinity`,
   so these have *no* upper bound: a newsletters_delivery broadcast, a shop
   import over a large feed, or a sitemap run on a big site that passes 30
   minutes is flipped back to `:available` and **re-executed concurrently with
   the still-running original**. On the delivery queue that is duplicate
   emails to real recipients.

This is worth calling out precisely because the PR's premise is right — hosts
*should* have Lifeline. The aggressive value converts a "stuck job" failure
mode into a "job ran twice" failure mode, which is strictly worse for the
delivery and sync queues.

**Fixed.** Every site now emits `rescue_after: :timer.minutes(60)` — Oban's own
default, and 2× the longest declared worker timeout. The invariant is recorded
in the `ensure_lifeline_plugin/2` doc, in the generated config's comment (so
the host sees it in their own `config.exs`), and locked by a new test that
reads the value back out of the generated entry and asserts it exceeds the
maximum `timeout/1` of every worker PhoenixKit ships — a future long-running
worker fails that test rather than silently eroding the margin.

## BUG - MEDIUM — `check_oban_config/1` raises on `plugins: false` / `queues: false`

**Where:** `lib/mix/tasks/phoenix_kit.doctor.ex:670-671`

```elixir
queues = Keyword.get(config, :queues, [])
plugins = Keyword.get(config, :plugins, [])
base = "#{length(queues)} queues, #{length(plugins)} plugins. ..."
```

`queues: false` / `plugins: false` is Oban's documented way to disable either
wholesale — standard in test config, and used in production by hosts that run
jobs on a dedicated node while the web nodes only enqueue. Against such a
config `length(false)` raises `ArgumentError`; `run_check/2` rescues it, so the
check renders as `FAIL Exception: ...` rather than reporting anything useful.

Pre-existing (`length/1` predates this PR), but the PR extends the same
function with `Enum.any?(plugins, ...)` on the same value, so it's in scope and
the fix is two lines.

**Fixed.** Added `normalize_oban_list/1` — non-list values normalize to `[]`,
so a plugins-disabled host now reads `0 queues, 0 plugins` plus the (correct)
Lifeline warning instead of a bogus failure.

## BUG - MEDIUM (latent) — `add_cron_plugin_to_plugins/2` still carries the un-anchored pattern this PR fixed in its sibling

**Where:** `lib/phoenix_kit/install/oban_config.ex:686` (pre-PR line numbering)

The PR fixed the lazy-match-into-a-nested-list bug in `ensure_lifeline_plugin/2`
and documented it thoroughly — but the sibling it was modelled on kept the
broken pattern:

```elixir
~r/(^[ \t]+plugins:\s*\[\n)(.*?)(\n[ \t]+\])/ms
```

`\n[ \t]+\]` matches **any** indented `]`, so the close binds to the first
nested list's bracket instead of the plugins block's. It's latent today only
because Case 4 fires exclusively when `Oban.Plugins.Cron` is absent from the
file, and the entries PhoenixKit itself generates (Pruner, Lifeline) carry no
nested list. A host whose plugins list contains anything that does —
`{Oban.Plugins.Reindexer, indexes: [...]}`, an Oban Web stats plugin, a custom
plugin with a list option — gets its `config.exs` corrupted by
`mix phoenix_kit.update`, which is the exact failure the PR's own comment
describes.

It also hardcoded 4-space entry indentation regardless of the block's actual
depth, where the new function derives it.

**Fixed.** `add_cron_plugin_to_plugins/2` now uses the identical anchored
pattern (`(^([ \t]+)plugins:\s*\[\n)(.*?)(\n\2\])`) and derives the Cron
entry's indentation from the captured block indent, matching the sibling. Not
separately unit-tested: the function is `defp` and reached only through the
private `ensure_cron_plugin/2`, and making it public purely for testing is more
API surface than the change warrants — the regex is now byte-identical to the
one exercised by the PR's `"closes at the plugins-block bracket, not the Cron
crontab's nested one"` test.

## NITPICK — presence checks scan the whole file, not the target app's block

`ensure_lifeline_plugin/2` short-circuits on `Regex.match?(~r/Oban\.Plugins\.Lifeline/, content)`
over the entire `config.exs`. A mention in a comment, or a Lifeline entry in a
*second* app's Oban block in the same file, silently skips the update for the
app being installed into.

Not fixed — every sibling in this module works the same way (`Oban.Plugins.Cron`,
`posts:\s*\d+`, `Oban.Plugins.Pruner.*max_age:`), and fixing it properly means
first scoping to the `config :app, Oban` block, which is a module-wide refactor
rather than a change to this PR. Recording it so the limitation is on the books.

## NITPICK — an empty or single-line `plugins:` list falls to the "could not parse" branch

`plugins: []`, `plugins: [{Oban.Plugins.Pruner, max_age: 300}]` (single line),
and `plugins: [\n]` all fail the regex, which requires a newline both after `[`
and before the closing `]`. Degrades safely — the user gets the
"Please manually add: ..." message — so not fixed.

---

## Post-merge changes applied

| File | Change |
|---|---|
| `lib/phoenix_kit/install/oban_config.ex` | `rescue_after` 30 → 60 min at all four emit sites; invariant documented in `@doc` + generated config comment; `add_cron_plugin_to_plugins/2` switched to the anchored pattern with derived indentation |
| `lib/mix/tasks/phoenix_kit.doctor.ex` | `normalize_oban_list/1` for `queues:`/`plugins:` `false`; advice text updated to 60 min |
| `test/phoenix_kit/install/oban_config_test.exs` | assertions updated to 60 min; new test asserting `rescue_after` exceeds every shipped worker's `timeout/1` |

Gate: `mix precommit` (format + `compile --warnings-as-errors` + `credo --strict`
+ dialyzer) clean. `test/phoenix_kit/install/oban_config_test.exs` — 16 tests, 0
failures.

---

## Second round (1.7.213) — external review of the 1.7.212 fixes

An independent review of `2dd50a47` raised three items. All three were valid and
are fixed; the first two are gaps in the 1.7.212 fixes themselves.

### BUG - MEDIUM — presence-checking Lifeline let an unsafe `rescue_after` pass

1.7.212 raised the value at every *emit* site, but both the installer and the
doctor still only asked *is Lifeline present?*. So:

- `ensure_lifeline_plugin/2` no-oped on any existing entry — a host carrying a
  30-minute Lifeline was never upgraded by `mix phoenix_kit.update`.
- `lifeline_plugin_configured?/1` returned a clean PASS for it.

The narrow population (main-trackers who updated between the PR merge and
1.7.212 — the 30-minute value was never published to Hex; `v1.7.212` is the
first tag containing it) is not the real point. The general case is: Oban's own
moduledoc advertises `rescue_after: :timer.minutes(5)` as its "more aggressive
period" example, so a host copying from Oban's docs lands squarely in the
duplicate-execution window and PhoenixKit told them everything was fine.

**Fixed.** The doctor now validates the *value*: it warns when `rescue_after` is
at or below `@lifeline_min_rescue_after` (30 min, the longest `timeout/1`
PhoenixKit ships), and treats an unset `rescue_after` as safe since that means
Oban's own 60-minute default. `ensure_lifeline_plugin/2` raises a too-low
`:timer.minutes(N)` literal to 60 rather than no-oping. Only that literal form is
rewritten — any other expression (raw milliseconds, an attribute, a runtime
lookup) is left alone with a notice, because rewriting an expression the
installer cannot evaluate is how a host's config gets corrupted.

### BUG - MEDIUM — the `plugins: false` normalization created a false positive

1.7.212's `normalize_oban_list/1` stopped the crash but then let `false` fall
through as `[]` into the Lifeline branch — so a node that deliberately runs with
plugins off got a warning telling it to run `mix phoenix_kit.update`, which would
rewrite `config.exs` for a node that must not run plugins at all.

**Fixed.** `plugins: false` now reports a pass ("Oban plugins are disabled on
this node") and skips the Lifeline check entirely. The Lifeline warning is
reserved for a real plugins list that omits or under-configures it.

### NITPICK — the invariant test hardcoded three worker modules

A new worker with a 45-minute timeout could land without touching that list, and
the test would still pass while the margin eroded.

**Fixed.** The test now discovers workers at runtime — every module in
`:phoenix_kit` that implements the `Oban.Worker` behaviour and exports
`timeout/1` — and asserts the emitted `rescue_after` exceeds the largest finite
one, naming the offending module on failure. Workers with no `timeout/1` are
excluded: Oban treats them as `:infinity`, and no finite `rescue_after` can
protect an unbounded job, which is why the doc frames the invariant around
*declared* timeouts. Verified the discovery finds all three (`SyncFilesJob`
1800000, `SchedulerWorker` 600000, `ProcessFileJob` 300000).

Also folded in: the `rescue_after` value now has a single source
(`@lifeline_rescue_after_minutes` + `lifeline_entry/0`) feeding the generated
template, the backfill, and the manual-fallback message, so the four emit sites
can't drift again.
