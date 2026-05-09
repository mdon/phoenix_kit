# Per-Module i18n Migration — Operational Procedure

**Audience:** an agent or developer applying the per-module Gettext pattern from [`guides/per-module-i18n.md`](../../guides/per-module-i18n.md) to one specific `phoenix_kit_<x>` package.

**When to use:** the public guide tells you *what to build*. This document tells you *how to actually get there with this repo's git/build/test workflow* — including every grabbed-foot we hit on the Newsletters pilot ([`BeamLabEU/phoenix_kit_newsletters#12`](https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/12)).

Read the public guide first. Then come back here. Then start.

---

## Up-front context the agent must know

| Fact | Why it matters |
|---|---|
| `phoenix_kit` core ships the new API in [PR #522](https://github.com/BeamLabEU/phoenix_kit/pull/522). Until that PR merges and a Hex release goes out, `Tab.localized_label/1` does not exist on any version of `phoenix_kit` you can pull from Hex. | Drives the **path-dep workflow** for local development and the **conditional CI skip** in `test_helper.exs`. |
| The `phoenix_kit` PR-522 branch is checked out as a git worktree at `/tmp/pk-pr/i18n` on this machine. That checkout is the **only local source** of the new API. | Local `phoenix_kit_<x>` package's `mix.exs` `path:` override must point at `/tmp/pk-pr/i18n`, **not** `/app` (which is the user's working tree on a different branch). |
| Each `phoenix_kit_<x>` package follows the **fork-based** PR workflow: `timujinne/<repo>` is the user's fork, `BeamLabEU/<repo>` is the upstream. Newsletters' upstream branch is `main` (not `dev`). | PR target = `BeamLabEU/<repo>:main`, head = `timujinne:feature/per-module-i18n`. |
| The package's local `mix.exs` typically has the `path: "/app", override: true` line cached as **`skip-worktree`** (`git update-index --skip-worktree mix.exs`). | If you don't lift `skip-worktree` first, `git add mix.exs` silently does nothing AND `git diff` shows no diff even when content differs. See [Gotcha 1](#gotcha-1-skip-worktree-on-mixexs). |
| Local `main` may be **N commits ahead of `origin/main`** with prior unpushed work that has nothing to do with you. | Don't push `main` directly. Branch from `origin/main` and cherry-pick your commit, so the PR contains only your work. |

---

## End-to-end procedure

### 0. Pre-flight

```bash
# Confirm core PR-522 worktree exists and has the new API
test -d /tmp/pk-pr/i18n && \
  grep -q 'localized_label' /tmp/pk-pr/i18n/lib/phoenix_kit/dashboard/tab.ex && \
  echo "OK"

# Module repo
cd /root/projects/phoenix_kit_<x>
git fetch origin
git fetch upstream     # if it exists; some forks only have origin
git branch -vv          # note any local commits ahead of origin/main
```

### 1. Lift `skip-worktree` on `mix.exs`

```bash
cd /root/projects/phoenix_kit_<x>
git ls-files -t mix.exs
# If the leading char is 'S', it's skip-worktree. Lift it:
git update-index --no-skip-worktree mix.exs
```

If you skip this step, every edit you make to `mix.exs` is **invisible to git** — `git add` returns *"paths matched … exist outside of your sparse-checkout definition"* (a misleading error — the issue is `skip-worktree`, not sparse), and `git diff` shows zero changes despite the file being different. Verify with `git hash-object mix.exs` ≠ `git ls-files -s mix.exs | cut -d' ' -f2` if you're unsure.

### 2. Reset `mix.exs` to a clean baseline before editing

The committed `mix.exs` shape and the user's local `mix.exs` shape can diverge significantly under `skip-worktree` (the user maintains a stripped-down local form for development convenience). Don't trust the working copy. Reset:

```bash
git checkout HEAD -- mix.exs
```

Then make **only** the three targeted edits:

1. `extra_applications: [:logger]` → `extra_applications: [:logger, :gettext]`
2. Add `{:gettext, "~> 1.0"}` to `deps`
3. Add `priv` to `package files:` (was `~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)` → `~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)`)

Do **not** touch `phoenix_kit` dep constraint. Most packages already have `~> 1.7` which admits any future release.

### 3. Add the local `path:` override (uncommitted, just for dev)

```bash
sed -i 's|{:phoenix_kit, "~> 1.7"}|{:phoenix_kit, "~> 1.7", path: "/tmp/pk-pr/i18n", override: true}|' mix.exs
```

This is your local-only override. Per the package's CLAUDE-level conventions, the `path:` line is **never committed**. It only exists so `mix deps.compile phoenix_kit --force` pulls the new API from `/tmp/pk-pr/i18n` while you develop and run tests.

### 4. Build the i18n wiring

Follow the public guide:

- `lib/phoenix_kit/<x>/gettext.ex` — `use Gettext.Backend, otp_app: :phoenix_kit_<x>`
- `lib/phoenix_kit/<x>/<x>.ex` — every `Tab.new!`, `%Tab{}`, `Tab.divider/1`, `Tab.group_header/1` carries `gettext_backend: PhoenixKit.<X>.Gettext`. `gettext_domain:` is optional (defaults to `"default"`).
- `priv/gettext/default.pot` — manually maintained list of every msgid that appears as a `label:` (or `tooltip:`) on a Tab/Group registration. **`mix gettext.extract` will NOT find these** because they're plain strings, not `dgettext` macro calls.
- `priv/gettext/{en,ru,et}/LC_MESSAGES/default.po` — same set of msgids in each. `en/default.po` has `msgstr` equal to `msgid`; `ru` and `et` are filled with translations.

### 5. Conditional CI skip + smoke test

```elixir
# test/test_helper.exs
require Logger

if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
  ExUnit.start()
else
  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )

  ExUnit.start(exclude: [:requires_phoenix_kit_i18n_api])
end
```

Smoke test in `test/phoenix_kit/<x>/i18n_test.exs`:

```elixir
defmodule PhoenixKit.<X>.I18nTest do
  use ExUnit.Case, async: false

  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.<X>.Gettext, as: <X>Gettext

  setup do
    original = Gettext.get_locale(<X>Gettext)
    on_exit(fn -> Gettext.put_locale(<X>Gettext, original) end)
    :ok
  end

  test "every admin tab carries the module's own gettext backend" do
    for tab <- PhoenixKit.<X>.admin_tabs() do
      assert tab.gettext_backend == <X>Gettext
      assert tab.gettext_domain == "default"
    end
  end

  test "ru locale resolves the parent tab to the expected translation" do
    Gettext.put_locale(<X>Gettext, "ru")
    [parent | _] = PhoenixKit.<X>.admin_tabs()
    assert Tab.localized_label(parent) == "<TRANSLATED>"
  end

  test "unknown locale falls back to the raw msgid" do
    Gettext.put_locale(<X>Gettext, "zz")
    [parent | _] = PhoenixKit.<X>.admin_tabs()
    assert Tab.localized_label(parent) == parent.label
  end
end
```

### 6. Local verification (with API)

```bash
mix deps.get
mix deps.compile phoenix_kit --force
mix test test/phoenix_kit/<x>/i18n_test.exs
```

Expect: all assertions pass. If `Tab.localized_label/1 is undefined` — `path:` line is wrong (typo, missed `override: true`, or worktree path doesn't have the new API). Re-check Step 0.

If `mix.exs`-related `_build` artifacts give "not owner" errors during compile, blow them away: `rm -rf _build/dev/lib/phoenix_kit_<x>` and retry.

### 7. Local verification (graceful degradation simulation)

Skip this on the first attempt; do it before opening the PR to confirm CI will pass:

```bash
# Temporarily restore clean dep
sed -i 's|, path: "/tmp/pk-pr/i18n", override: true||' mix.exs
mix deps.compile phoenix_kit --force
mix test test/phoenix_kit/<x>/i18n_test.exs
# Expect: 4 tests, 0 failures, 4 excluded (helper detected missing API → skip kicked in)
```

Then re-add the path override for committing prep.

### 8. Bump `@version` and write CHANGELOG

For every owned `phoenix_kit_<x>` package, the team is the maintainer — so unlike `phoenix_kit` core, **you do bump version and write the CHANGELOG entry**:

```elixir
# mix.exs
@version "0.1.<n+1>"
```

```markdown
# CHANGELOG.md
## 0.1.<n+1> - YYYY-MM-DD

### Added
- Per-module Gettext backend (`PhoenixKit.<X>.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).
```

### 9. Stage and commit on `main`

Switch `mix.exs` to **clean form** (no `path:`) before committing. Then:

```bash
# Make sure the path override is gone from the file you're about to commit
grep -n 'path:.*pk-pr' mix.exs && echo "STILL HAS PATH OVERRIDE — fix"

git add \
  mix.exs mix.lock \
  lib/phoenix_kit/<x>/gettext.ex \
  lib/phoenix_kit/<x>/<x>.ex \
  priv/gettext/ \
  test/test_helper.exs \
  test/phoenix_kit/<x>/i18n_test.exs \
  CHANGELOG.md

git commit -m '...' # see Newsletters PR #12 for tone — descriptive, links PR #522
```

If pre-commit hooks fail on dialyzer or anything else, **investigate** before disabling. The Newsletters pilot pre-commit hooks were stable; if your module's pre-commit catches something, it's likely a real signal.

### 10. Branch from `origin/main` and cherry-pick

Local `main` may be ahead of `origin/main` with unrelated commits the user has stashed locally. Don't push them. Cherry-pick only your one commit onto a clean feature branch:

```bash
COMMIT=$(git rev-parse HEAD)

git branch feature/per-module-i18n origin/main
git checkout feature/per-module-i18n
git cherry-pick $COMMIT
```

Expect a conflict on `mix.lock` because of how `gettext` resolves between the user's local main state and `origin/main`. Resolve by:

```bash
git checkout HEAD -- mix.lock      # take feature-branch base's mix.lock
mix deps.get                        # let mix re-add gettext entry against the base
git add mix.lock
GIT_EDITOR=true git cherry-pick --continue
```

If `mix.lock` ends up identical to the base after `mix deps.get` (because the new dep was already a transitive of `phoenix_kit`), git will silently drop it from the commit — that's fine.

### 11. Push the feature branch

```bash
git push -u origin feature/per-module-i18n
```

### 12. Open the PR via API

```bash
TOKEN=$(awk '/^github.com:/,0' ~/.config/gh/hosts.yml | awk '/^[[:space:]]*oauth_token:/{print $2; exit}')

PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'title': 'Add per-module Gettext backend for sidebar tab labels',
  'head': 'timujinne:feature/per-module-i18n',
  'base': 'main',
  'body': open('/tmp/pr-body.md').read(),
  'maintainer_can_modify': True,
  'draft': False
}))")

curl -sS -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/BeamLabEU/phoenix_kit_<x>/pulls \
  -d "$PAYLOAD"
```

Body skeleton lives at the bottom of this document.

### 13. After PR creation

- Restore the local `path:` override in `mix.exs` (uncommitted) so subsequent local development still picks up `/tmp/pk-pr/i18n`'s new API.
- Reapply `git update-index --skip-worktree mix.exs` if the user wants `mix.exs` to stay invisible to git going forward.

---

## Gotchas (full list, with diagnosis)

### Gotcha 1: `skip-worktree` on mix.exs

**Symptom:** `git add mix.exs` errors with *"paths and/or pathspecs matched paths that exist outside of your sparse-checkout definition"*. `git diff` shows zero diff. `md5sum` of the file ≠ what's at HEAD.

**Diagnosis:** `git ls-files -t mix.exs` shows `S mix.exs`. The file is marked skip-worktree.

**Fix:** `git update-index --no-skip-worktree mix.exs`. Now stage normally.

**Why it's there:** the user keeps a `path: "/app", override: true` line locally for dev that they don't want git to see. Once your committed mix.exs is clean (no path), the user can re-skip-worktree it after your PR.

### Gotcha 2: Sparse-checkout error is misleading

The `git add mix.exs` error message says "sparse-checkout". `git sparse-checkout list` returns "*this worktree is not sparse*". The actual cause is skip-worktree (gotcha 1). Don't go down the sparse-checkout rabbit hole.

### Gotcha 3: `mix gettext.extract` doesn't see `Tab.new!(label: "…")`

These are plain strings, not `dgettext` macro calls. The extractor silently produces an empty `.pot`. **Maintain `priv/gettext/default.pot` manually** — list every msgid by hand. Add a header comment in the file documenting that.

### Gotcha 4: `priv` missing from `mix.exs` `package files:`

If `package files:` is `~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)` (no `priv`), the `.po` files are silently omitted from the Hex tarball. Consumers who install from Hex get a backend with no catalogue → all locales return raw msgids.

**Verification:** `mix hex.build && tar -tzf phoenix_kit_<x>-*.tar | grep priv/gettext` should list every `.pot`/`.po`. If it's empty, `priv` is missing.

### Gotcha 5: `function_exported?` returns `false` for unloaded modules

`if function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1)` returns `false` if the `Tab` module hasn't been loaded yet — and at `test_helper.exs` start time it hasn't been. Symptom: i18n tests get excluded **even when the API is available**.

**Fix:** wrap with `Code.ensure_loaded?/1` first:

```elixir
if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
```

### Gotcha 6: `_build/` artifacts owned by `root`

If past `mix compile` runs were done as root, you may hit *"could not touch … not owner"* on subsequent `mix` invocations as `node`. Fix:

```bash
rm -rf _build/dev/lib/phoenix_kit_<x>
mix compile
```

The `+` ACL bit on the file usually means group-writable, so deletion via `rm -f` works for `node` even on root-owned files in this repo's layout.

### Gotcha 7: Cherry-pick conflicts on `mix.lock`

When you cherry-pick your commit from local `main` onto a fresh `feature/...` branch from `origin/main`, `mix.lock` will conflict if the user's local main has different deps than origin's. Resolve by taking the base's `mix.lock` and re-running `mix deps.get`:

```bash
git checkout HEAD -- mix.lock
mix deps.get
git add mix.lock
GIT_EDITOR=true git cherry-pick --continue
```

`GIT_EDITOR=true` keeps the cherry-pick non-interactive (otherwise it tries to open `$EDITOR`).

### Gotcha 8: `gh` CLI is not installed

The container has no `gh` binary. Use `curl` against the GitHub REST API with the token from `~/.config/gh/hosts.yml`:

```bash
TOKEN=$(awk '/^github.com:/,0' ~/.config/gh/hosts.yml | awk '/^[[:space:]]*oauth_token:/{print $2; exit}')
curl -sS -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" ...
```

### Gotcha 9: Don't push local `main`

The user keeps unpushed commits on local `main` for development. Pushing `main` to origin would expose them. Always work via a feature branch cherry-picked from `origin/main`.

### Gotcha 10: `System.cmd("psql", …)` crashes with `:enoent` when psql isn't installed

**Symptom:** `mix test` aborts before running any test with `(ErlangError) Erlang error: :enoent` raised from `:erlang.open_port/2`.

**Diagnosis:** the package's `test/test_helper.exs` runs a DB-existence probe via `System.cmd("psql", ["-lqt"], …)` to decide whether to include `:integration` tests. `System.cmd/3` does not catch `:enoent` from a missing executable — it raises an ErlangError. Containers without the `postgresql-client` package on PATH (most CI images, by default) hit this immediately.

**Fix:** wrap the `System.cmd` call in `try/rescue`, returning `:try_connect` (or whatever the file's "fall back to TCP probe" branch is) on any error:

```elixir
db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        # … existing parse-output logic …
        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    _ -> :try_connect
  end
```

**When to apply:** every package that has `System.cmd("psql", …)` (or any other system binary call) without an existing rescue clause in `test_helper.exs`. Found and fixed on `phoenix_kit_customer_support` (PR [#3](https://github.com/BeamLabEU/phoenix_kit_customer_support/pull/3)). Newsletters did not have this — its `test_helper.exs` was a bare `ExUnit.start()` before the i18n migration.

If your module's `test_helper.exs` already has a different DB-probe shape, audit it for the same class of bug — any `System.cmd`-style call without `try/rescue` is a CI crash waiting to happen on a slim container.

### Gotcha 11: Module reads `mix.exs` from the working tree, but the commit shape is what matters

When verifying that `mix.exs` is clean (no `path:` override) before pushing, a reviewer or follow-up agent might `Read` the working tree file and see `path: "/tmp/pk-pr/i18n", override: true` — and panic that the path leaked into the commit. It didn't. The committed snapshot is clean; the working tree retains the local dev override (uncommitted).

**Verification rule:** always check the committed form via `git show <sha>:mix.exs`, not by reading the file from the working tree. The two diverge by design under the established workflow.

### Gotcha 12: Skip-worktree may already be lifted (`H` not `S`)

The playbook's step 1 (lift `skip-worktree` on `mix.exs`) is a precaution. Several packages had already-`H` (normal) status — the lift was a no-op. If `git ls-files -t mix.exs` returns `H` rather than `S`, skip step 1 and proceed to step 2.

### Gotcha 13: Dynamic-label tabs do NOT receive `gettext_backend:`

If a module builds `%Tab{label: …}` with a **runtime** value rather than a static string (e.g. `label: role.name` for a per-role admin tab, or `label: project.title` for a per-project tab), do **not** add `gettext_backend:`. There is no static msgid for gettext to look up — the runtime string would be passed to `Gettext.dgettext/3` which would fail to find it in the catalogue and return the raw string anyway, just with an unnecessary call per render.

The "every `%Tab{}`" rule in the public guide implicitly applies to **static-label** tabs (admin nav, settings nav, fixed sidebar items). Dynamic-label tabs (built from DB rows, user input, etc.) keep their raw `label: <value>` and stay untouched.

Found on `phoenix_kit_crm`'s `sidebar_bootstrap.ex` (`role_tab/1` builds tabs from CRM role names).

### Gotcha 14: `use PhoenixKitWeb, :live_view` files are off-limits for the migration

If a module's LiveView file begins with `use PhoenixKitWeb, :live_view` (or `:controller`), that file is **deliberately part of the host app's web layer dependency chain**. The host's web module injects Gettext, router helpers, and other compile-time macros at the host-app level. The package can't override that with its own backend without breaking host apps.

**Rule:** if a file does NOT have a direct `use Gettext, backend: ...` declaration of its own, but uses `PhoenixKitWeb.Gettext` only via `use PhoenixKitWeb, :live_view`, leave it alone. Migrating it would break runtime translations.

Found on `phoenix_kit_crm/web/settings_live.ex`. Confirmed correct by reviewer.

### Gotcha 15: Body-string `PhoenixKitWeb.Gettext` references in `lib/.../web/*` are out of scope

Several modules (notably `phoenix_kit_billing` with 23 files, `phoenix_kit_ecommerce` with `shop_web.ex`, `phoenix_kit_legal` with calls in `legal.ex`) have **pre-existing** `use Gettext, backend: PhoenixKitWeb.Gettext` declarations or `Gettext.gettext(PhoenixKitWeb.Gettext, …)` calls in their LiveView/controller body code. These translate **page body strings** (form labels, button text, table headers) — not Tab labels.

The per-module-i18n migration is **scoped to sidebar Tab labels only**. Body-string i18n is a separate, much larger sweep:

- Replace every `use Gettext, backend: PhoenixKitWeb.Gettext` with `use Gettext, backend: PhoenixKit<X>.Gettext`
- Run `mix gettext.extract` to discover all body-string msgids (often hundreds per module)
- Produce translations in `ru` / `et` (or leave empty for graceful fallback)

**Document body-string tech debt in the PR description** as out-of-scope, with the file count. Don't mix it into the tab-label PR — keep the diff focused. CRM was the exception: it had `gettext()` wrappers ON Tab labels themselves, so the wrapper-strip + backend-swap was bundled with the tab migration; for purely-body-string modules (billing, ecommerce, legal) the body-string sweep stays a separate PR.

### Gotcha 16: Tab count vs. unique msgid count

A module can have N `Tab.new!` sites but only M unique msgid values (M ≤ N), because the same label often appears across `admin_tabs/0`, `settings_tabs/0`, and `user_dashboard_tabs/0` (e.g. "Newsletters" parent in admin, "Newsletters" settings root, "Newsletters" user dashboard root — all the same msgid).

Count msgids by reading the file's distinct `label:` values, not by counting `Tab.new!` sites. The `.pot` and `.po` files should have M entries, not N.

Reported counts from the rollout:
- `newsletters`: 9 sites → 9 msgids (no repeats)
- `customer_support`: 4 sites → 3 msgids ("Customer Support" repeats)
- `emails`: 10 sites → 8 msgids ("Emails" repeats)
- `billing`: 13 sites → 11 msgids ("Billing" repeats)
- `ecommerce`: 10 sites → 9 msgids ("E-Commerce" repeats)
- `legal`: 1 site → 1 msgid
- `crm`: 4 sites → 3 msgids ("CRM" repeats)

---

## PR body skeleton

Copy the [Newsletters PR #12 body](https://github.com/BeamLabEU/phoenix_kit_newsletters/pull/12) and substitute:

- Module name (`Newsletters` → `<X>`)
- Hex package name (`phoenix_kit_newsletters` → `phoenix_kit_<x>`)
- Number of `Tab.new!` sites
- The translation table (msgid / ru / et)
- The version line in the rollout note

Keep the **Behaviour matrix** table and the **Out of scope** section verbatim — they're load-bearing for reviewer expectations.

---

## When this document goes stale

After PR #522 merges and `phoenix_kit` ships a Hex release with the API, the conditional CI skip becomes a defensive guard rather than a critical workaround. The `path:` override workflow goes away (replace with the actual Hex constraint). Update this document to reflect that — or delete it once all `phoenix_kit_<x>` packages have been migrated.
