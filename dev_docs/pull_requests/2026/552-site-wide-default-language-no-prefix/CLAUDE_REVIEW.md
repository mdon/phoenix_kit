# PR #552 — Site-wide `default_language_no_prefix` setting + sitemap honors it

Reviewed post-merge (merge commit `4abce05b`, squash-feature commit `911bad36`).
Skills: `elixir:phoenix-thinking`. Author: Max (mdon).

## Resolution status

Fixed in-tree on `dev` after review:

- ✅ Dead `@see` reference in `Languages.default_language_no_prefix?/0`
  docstring → repointed to `migrate_legacy/0`.
- ✅ Misleading `Routes.admin_path/2` doctest → deterministic examples
  kept inside `## Examples`; setting-dependent shapes lifted into a
  narrative block with `#=>` markers so ExDoc won't ever evaluate
  them as doctests.

Surfaced during the fix pass (not in original review):

- ✅ Dialyzer warning on the PR's own `@spec` —
  `lib/modules/languages/languages.ex:567` declared
  `PhoenixKit.Settings.Setting.t()` but the schema had no `@type t`.
  `mix precommit` failed with `unknown_type`. Added the missing
  `@type t :: %__MODULE__{...}` to `PhoenixKit.Settings.Setting`
  (`lib/phoenix_kit/settings/setting.ex`); precommit now clean
  (dialyzer 161 errors / 161 skipped — same as baseline).

## Summary

Lifts the primary-language prefix toggle out of `phoenix_kit_publishing` and
into a single core setting on the Languages admin page. `Routes.path/1`,
`Routes.admin_path/2`, and the publishing sitemap source now all consult
`Languages.default_language_no_prefix?/0`. Default is `false` (= keep `/en/`
in URLs), reverting the unconditional admin-strip that PR #551 had just
shipped. A `migrate_legacy/0` callback backfills from
`publishing_default_language_no_prefix`.

Scope is tight (5 prod files, 333/57 additions/deletions), the legacy-key
migration is genuinely idempotent, and the new integration test pins both
states of the setter→getter→Routes round-trip plus all three migrate paths.

## Findings

### BUG - MEDIUM — Dead `@see` reference in `default_language_no_prefix?/0` docstring — ✅ FIXED

`lib/modules/languages/languages.ex:555-556`:

```elixir
The setting can be migrated from the legacy
`publishing_default_language_no_prefix` key — see
`PhoenixKit.Migration.migrate_default_language_no_prefix/0`.
```

`PhoenixKit.Migration.migrate_default_language_no_prefix/0` does not exist
in this codebase (or anywhere else — `rg` finds zero matches outside this
docstring). The real entry point is `Languages.migrate_legacy/0`, run via
`PhoenixKit.ModuleRegistry.run_all_legacy_migrations/0` from the host
app's `Application.start/2` (as the `migrate_legacy/0` docstring just
above correctly states).

**Fix applied** (`lib/modules/languages/languages.ex:554-555`): docstring
now reads `— see `migrate_legacy/0`.`. The symbol resolves inside the
same module and ExDoc will render it as a working link.

### IMPROVEMENT - MEDIUM — `admin_path/2` doctest will fail if anyone ever runs `doctest Routes` — ✅ FIXED

`lib/phoenix_kit/utils/routes.ex:185-199`:

```elixir
## Examples

    iex> Routes.admin_path("/admin/users", "uk")
    "/phoenix_kit/uk/admin/users"

    # primary locale with setting OFF (default)
    iex> Routes.admin_path("/admin/users", "en")
    "/phoenix_kit/en/admin/users"

    # primary locale with `default_language_no_prefix` setting ON
    iex> Routes.admin_path("/admin/users", "en")
    "/phoenix_kit/admin/users"

    iex> Routes.admin_path("/admin/users", nil)
    "/phoenix_kit/admin/users"
```

Two problems:

1. **Doctests don't read mode-setting comments.** ExDoc treats each
   `iex>` block as an independent test case; nothing between examples
   flips the setting. Both `"en"` calls evaluate the *same* setting
   state. Today no module declares `doctest PhoenixKit.Utils.Routes`
   (`rg "doctest" test/` confirms), so the build stays green. The
   moment anyone adds it, the third example crashes — with the default
   `false`, `admin_path("/admin/users", "en")` returns
   `"/phoenix_kit/en/admin/users"`, not `"/phoenix_kit/admin/users"`.
2. **It's misleading as documentation.** A reader scanning the examples
   sees two identical calls returning different outputs with no visible
   cause. The comment is too quiet to carry the explanation.

**Fix applied** (`lib/phoenix_kit/utils/routes.ex:185-201`): kept the
two deterministic cases (`"uk"`, `nil`) inside `## Examples`; lifted
the setting-dependent `"en"` cases into a narrative block below,
written with `#=>` comment markers instead of `iex>` prompts so ExDoc
never evaluates them:

```elixir
  Primary-locale shape depends on the `default_language_no_prefix`
  setting (not shown as doctests because the result varies with
  runtime state):

      # setting OFF (default)
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/en/admin/users"

      # setting ON
      Routes.admin_path("/admin/users", "en") #=> "/phoenix_kit/admin/users"
```

Adding `doctest PhoenixKit.Utils.Routes` later is now safe.

### BUG - LOW — `@spec set_default_language_no_prefix/1` references undefined `Setting.t/0` — ✅ FIXED

Surfaced when running `mix quality.ci` after the docstring fix:

```
lib/modules/languages/languages.ex:567:44:unknown_type
Unknown type: PhoenixKit.Settings.Setting.t/0.
```

The spec:

```elixir
@spec set_default_language_no_prefix(boolean()) ::
        {:ok, PhoenixKit.Settings.Setting.t()} | {:error, Ecto.Changeset.t()}
```

`PhoenixKit.Settings.Setting` (the schema module) defines no
`@type t :: %__MODULE__{...}`. `rg "@type t" lib/phoenix_kit/settings/`
returns zero matches. Same shape was already present at HEAD for other
Settings consumers, so this is a workspace-wide pre-existing issue —
PR #552 didn't introduce the underlying gap, but it added a fresh spec
that now trips dialyzer.

**Fix applied** (`lib/phoenix_kit/settings/setting.ex`): added
`@type t :: %__MODULE__{...}` to the schema, with every field typed
against its column. Fixes the warning at the source — any future
consumer that specs `Settings.Setting.t()` will type-check cleanly
without further work. Verified with `mix precommit` (dialyzer:
161 errors / 161 skipped, same as baseline pre-PR).

### NITPICK — Free-floating comments inside `cond` clauses

`lib/modules/sitemap/sources/publishing.ex:529-538`:

```elixir
lang_parts =
  cond do
    is_nil(language) -> []
    single_language_mode?() -> []
    is_default and Languages.default_language_no_prefix?() -> []
    # Use display code to match controller's canonical URL logic
    # This returns base code ("en") when single dialect enabled,
    # or full code ("en-US") when multiple dialects enabled
    true -> [get_display_code(language)]
  end
```

The two comment lines parse cleanly (Elixir tolerates comments anywhere
inside a `cond`), and they *do* explain the `true ->` clause that
follows. But visually they float between clauses and read as if they
might belong to the line above. Either inline them as `true ->
[get_display_code(language)]  # display code matches controller…` (cap
at line length) or lift the whole why-block into the existing skip-rules
docstring directly above the `cond` (which already discusses
canonicalization). Pure cosmetics — no behavior change.

### OBSERVATION — `prefixless_primary?/0` rescue is belt-and-suspenders

`lib/phoenix_kit/utils/routes.ex:115-123` wraps
`Languages.default_language_no_prefix?/0` in `rescue _ -> false` and a
`mix_task_context?` short-circuit. But the inner call ultimately lands
in `Settings.get_boolean_setting/2`, which already rescues all errors
and returns the default (`settings.ex:892-904`). The outer rescue is
defensive overlap, not a bug — it matches the shape of
`get_default_language_base/0` (line 145), which is the explicit goal
the PR description calls out ("Same defensive rescue + mix-task
fallback"). Worth knowing as you read, not worth removing.

### OBSERVATION — mount/3 picks up one more synchronous read

`lib/phoenix_kit_web/live/modules/languages.ex:68` adds
`Languages.default_language_no_prefix?()` to `mount/3`. By the iron law
in `elixir:phoenix-thinking`, that read fires twice (HTTP + WebSocket).
The host module already does ~10 other synchronous loads in `mount/3`
(`get_config`, `get_display_languages`, `get_languages_grouped_by_continent`,
project title…), so adding one cached settings lookup is consistent
with the existing pattern. The whole module's mount should move to
`handle_params/3` eventually, but that's a pre-existing surface, not
this PR's regression.

### OBSERVATION — setter has no audit trail

`Languages.set_default_language_no_prefix/1` writes the setting silently;
no `Activity.log` entry. Other admin toggles on this page behave the
same way, so it's consistent — but a future activity-coverage pass for
this admin surface should pick up this toggle alongside its siblings.

## CHANGELOG

PR #552 merged into `dev` on 2026-05-19 22:17 UTC, then `dev → main`
landed in `4abce05b`. Current `@version` is still `1.7.114` and there
is no entry yet for this PR. Per `feedback_changelog_ownership.md`,
that's a Claude task at the next release bump — flagging here so it
doesn't fall through the cracks.

Suggested entry (next release):

```markdown
### Added
- Site-wide `default_language_no_prefix` setting on the Languages admin
  page controls whether the primary language emits its locale segment
  in URLs. When on, `/admin/users` and `/blog/post` replace
  `/en/admin/users` and `/en/blog/post` across admin pages, public
  pages, sitemap, and redirects; other languages always keep their
  prefix. Default is off, matching the historical publishing default,
  so existing installs' indexed URLs stay stable on upgrade. Installs
  that previously toggled `publishing_default_language_no_prefix` get
  auto-migrated to the new key on the next boot via
  `Languages.migrate_legacy/0` (PR #552).

### Changed
- Admin URL emission for the primary language now follows the new
  site-wide setting (default off), restoring the `/en/admin/users`
  shape that PR #551 had emitted prefixless unconditionally. Both URL
  shapes still resolve at the router level via the dual-scope admin
  emission, so existing bookmarks and external links keep working
  (PR #552).

### Fixed
- Publishing sitemap honors `default_language_no_prefix` for the
  primary language. Previously the sitemap always emitted
  `/en/blog/post` in multilang mode regardless of the setting, drifting
  away from the URLs publishing actually served at request time (PR #552).
```

## Follow-up surfaced in PR body (not in this PR)

The PR description names
`phoenix_kit_entities/lib/phoenix_kit_entities/url_resolver.ex` —
`build_path_with_language/3` and `add_public_locale_prefix/2` —
as still having the same site-wide-setting blind spot. That's an
entities-package change, separate repo, separate review. Flagging for
the entities owner.
