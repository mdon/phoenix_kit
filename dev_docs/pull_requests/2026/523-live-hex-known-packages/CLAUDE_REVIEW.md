# PR #523 — Replace hardcoded known-packages list with live Hex.pm fetch

**Author:** @timujinne
**Branch:** `feature/known-packages-live-fetch` ← `dev`
**Merged:** 2026-05-08T21:14:25Z (`f2318432`)
**Diff:** +746 / -157 (6 files, multiple commits)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/523

## Verdict

**APPROVE** with one IMPROVEMENT-MEDIUM around external-HTTP-in-mount
called out below. The change is correct in shape — replacing 14
hand-maintained registry entries with a Hex.pm fetch + cache means
the catalog reflects whatever's actually published, no more "I added
a package and the admin Modules page still shows the old list" PRs.

The implementation is well-defended:

- **ETS cache, not `:persistent_term`** (the moduledoc explains the
  trade-off correctly: avoids global-GC write amplification on
  multi-node deploys).
- **Stale-while-revalidate with cap.** First Hex failure: serve
  cached. Cached older than 24h: drop, return extras-only. Two
  distinct log levels (`:warning` for stale-served, `:error` for
  stale-dropped) — operationally distinguishable.
- **`Link`-header pagination.** Reads the standard `rel="next"` link.
  Test exercises the multi-page path.
- **Config extras override.** Parent apps with private/forked
  packages declare them in `:phoenix_kit, :extra_known_packages` and
  win on the `package` dedup key. `source: "config"` baked in.
- **11 tests** cover happy path, cache hit/miss, Hex 500, transport
  error, malformed body, pagination, extras config, and stale-cap.
  Stub via `Req.Test` (decoupled from real Hex), call counts via
  `:counters` (clean assertions on "did the second call hit the
  network?").

Findings below — one Phoenix-thinking concern, plus PR-body / shape
observations.

## What changed

| Layer | Change |
|---|---|
| `lib/phoenix_kit/known_packages.ex` (new, 271 lines) | `list/1` — Hex fetch + ETS cache + stale-while-revalidate. `clear_cache/0` for tests. `parse_marker/1` extracts `hex_docs_icon_name: hero-<name>` from package descriptions. `merge_extras/1` overlays `extra_known_packages` config (config wins on `package` collision). |
| `lib/phoenix_kit/module_registry.ex` | `known_external_packages/0` becomes a 1-line delegate to `KnownPackages.list/0`. The 14 hardcoded entries (~140 lines) are deleted. |
| `lib/phoenix_kit/module_registry.ex` | `not_installed_packages/0` switches from `Code.ensure_loaded?(pkg.module)` to OTP-app-name MapSet membership — installed-deps check (the more correct semantics). |
| `lib/phoenix_kit_web/live/modules.html.heex` | `pkg.icon` rendered via `<.icon name=…>` (heroicon) instead of a unicode emoji span; `pkg.hex_url` guarded with `:if`; mix.exs snippet uses `pkg.package` instead of `pkg.hex_package`. |
| `test/test_helper.exs` | Wraps `System.cmd("psql", ...)` in `try/rescue ErlangError` — handles environments where `psql` binary isn't on PATH. |
| Tests | New `known_packages_test.exs` (11 tests, ~400 lines); regression suite for `not_installed_packages/0` in `module_registry_test.exs`. |

## Findings

### IMPROVEMENT - MEDIUM — `not_installed_packages/0` is called from `mount/3`; cold-cache page load blocks on Hex for up to 3 seconds

`lib/phoenix_kit_web/live/modules.ex:35`:

```elixir
not_installed = ModuleRegistry.not_installed_packages()
```

…which on a cold node transitively runs:

1. `KnownPackages.list/0`
2. `fetch_from_hex/1` → `Req.get/2` with `receive_timeout: 3000`
3. `Link`-header pagination → up to N additional Hex roundtrips

`mount/3` runs **twice** for every connected LiveView (the HTTP
disconnected mount + the WS-connect mount). Cold cache: first run
spends up to 3s on Hex. Second run hits the warm cache. Happy path
total cost on a cold deploy: 3s perceived latency on the first
Modules page load.

Per the phoenix-thinking iron law: **NO DATABASE QUERIES IN MOUNT**.
External HTTP is even worse — a Hex outage now blocks the dead-render
HTTP response (the user sees a blank page for 3s, then a render
based on `extras-only` if the cache is empty).

The right shape is `assign_async/3`:

```elixir
def mount(_params, _session, socket) do
  socket =
    socket
    |> assign(:not_installed_packages, [])
    |> assign(:loading_packages?, true)
    |> assign_async(:not_installed_packages, fn ->
      {:ok, %{not_installed_packages: ModuleRegistry.not_installed_packages()}}
    end)

  {:ok, socket}
end
```

…with the template rendering a skeleton state when
`@not_installed_packages == []` and `@loading_packages?` is `true`.
Net effect: dead render is fast (no Hex roundtrip), the connected
mount kicks off the async, and the user sees the catalog populate
~50-3000ms after the page is interactive.

Or alternatively, move the call into `handle_params/3` so it only
runs once per navigation rather than twice per mount.

The 10-min cache means the *second* user to hit the page in any
10-min window is fine. But the cold-deploy / cache-miss case is the
one that defines the user's worst-case experience, and 3s of
mount-time HTTP is a paper cut waiting to happen.

**Where:** `lib/phoenix_kit_web/live/modules.ex:25-48`,
`lib/phoenix_kit/known_packages.ex:34-46`

### NITPICK — PR body is at odds with the shipped shape on two points

The PR body says:

> Removed from the previous shape: `module:` (atom — UI never used it),
> `hex_package:` (renamed to `package:`), `github_url:`,
> `latest_version:`. No in-repo callers of the removed fields remain.

But the test-pinned shape has 11 keys including all four:

```elixir
# test/phoenix_kit/known_packages_test.exs:128-141
test "all 11 keys present" do
  [pkg] = KnownPackages.list(test_opts())
  assert Enum.sort(Map.keys(pkg)) == [
           :description, :github_url, :hex_package, :hex_url,
           :icon, :key, :latest_version, :module,
           :name, :package, :source
         ]
end
```

The moduledoc on `lib/phoenix_kit/known_packages.ex:1-23` and the
inline comment on `:215-218` both correctly say the fields are
**kept** for backwards compat. So the *code* is right; the PR body
is the part that drifted. Two things follow from this:

1. **Future maintainers reading the PR body will assume the API is
   smaller than it is.** The next "let's clean up KnownPackages"
   PR may try to delete fields that are still load-bearing for
   external consumers (parent apps' admin Modules pages,
   conceivably any consumer reading `pkg.module`).
2. **The PR body also says `:persistent_term`**: *"cached in
   `:persistent_term` for 10 minutes."* The actual implementation
   uses ETS (the moduledoc explains why: avoids global-GC write
   amplification on multi-node cold deploys). Same drift.

Worth a one-line PR description correction in a `git notes` or a
follow-up `FOLLOW_UP.md` so the next reader doesn't get confused.

**Where:** PR description vs. `lib/phoenix_kit/known_packages.ex:1-26, 215-225`

### IMPROVEMENT - LOW — `derive_module_atom/1` calls `String.to_atom` on Hex package names

`lib/phoenix_kit/known_packages.ex:223-228`:

```elixir
defp derive_module_atom(package) do
  package
  |> String.split("_")
  |> Enum.map_join("", &String.capitalize/1)
  |> then(&("Elixir." <> &1))
  |> String.to_atom()
end
```

Each unique `phoenix_kit_*` package name on Hex creates a new atom
in the BEAM atom table. The atom is never used as a module reference
(consumer code that wants the module looks it up by name elsewhere,
not from this field), so it's pure back-compat preservation —
matches what the old hardcoded list returned.

Two practical mitigations to consider:

1. **`String.to_existing_atom/1` with `nil` fallback.** Returns the
   atom only if it was already created (which it would be for any
   actually-installed package). For not-installed packages, returns
   nil — which is exactly what the field is for ("show this in the
   not-installed list").
2. **Drop `derive_module_atom/1` entirely.** The PR body's framing
   ("module: removed") was actually the right call — keeping the
   field is back-compat ceremony for a field no in-repo caller reads.

Atom-table growth is bounded by the Hex prefix filter (~20 known
phoenix_kit packages today, plausibly ~100 long-term), so this isn't
a runtime DoS. Just a code-smell that grows mildly with Hex
adoption.

**Where:** `lib/phoenix_kit/known_packages.ex:213-228`

### NITPICK — `fetch_hex_page/3` recursion has no page-count cap

`lib/phoenix_kit/known_packages.ex:155-175`:

```elixir
defp fetch_hex_page(url, acc, req_options) do
  case Req.get(url, req_options) do
    {:ok, %{status: 200, body: packages, headers: headers}} when is_list(packages) ->
      valid = packages |> Enum.reject(&skip_package?/1) |> Enum.map(&shape_entry/1)
      next_url = parse_next_link(headers)
      fetch_hex_page(next_url, acc ++ valid, req_options)
    ...
  end
end
```

The recursion terminates when `parse_next_link/1` returns `nil`. In
practice Hex's pagination is bounded (~100 packages per page, max
~10 pages for the `phoenix_kit_*` namespace). But:

1. **A malformed `Link` header from Hex** could in theory produce a
   loop (next URL same as current). The recursion would diverge.
2. **A man-in-the-middle response** (Hex itself unlikely, but a
   misconfigured corporate proxy could substitute responses) could
   feed an attacker-controlled `Link` header.

A defensive max-pages cap (10? 20?) would close both gaps:

```elixir
defp fetch_hex_page(_url, acc, _opts, page) when page > 10, do: {:ok, acc}

defp fetch_hex_page(url, acc, opts, page) do
  ...
  fetch_hex_page(next_url, acc ++ valid, opts, page + 1)
end
```

Cosmetic given Hex's behaviour today, but trivial to add.

**Where:** `lib/phoenix_kit/known_packages.ex:151-175`

### NITPICK — `ensure_table/0` rescues `ArgumentError` to handle a race; comment would help

`lib/phoenix_kit/known_packages.ex:67-78`:

```elixir
defp ensure_table do
  case :ets.whereis(@table) do
    :undefined ->
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

    _ ->
      :ok
  end
rescue
  ArgumentError -> :ok
end
```

The `rescue ArgumentError -> :ok` handles the race where two
processes both see `:undefined` from `:ets.whereis/1` and both
attempt `:ets.new/2` — the second one raises `ArgumentError` because
the named table already exists. The PR body doesn't mention this;
the function name doesn't either; a reader has to derive it from
"why would `:ets.new` raise an `ArgumentError`?"

A two-line comment would close the gap:

```elixir
defp ensure_table do
  ...
rescue
  # Race: another process called :ets.new/2 between our :ets.whereis/1
  # and our :ets.new/2. The named table now exists; we're fine.
  ArgumentError -> :ok
end
```

**Where:** `lib/phoenix_kit/known_packages.ex:67-78`

### NITPICK — `parse_next_link/1` regex won't handle quoted commas in the URL

`lib/phoenix_kit/known_packages.ex:181-189`:

```elixir
defp parse_next_link(headers) when is_map(headers) do
  link = headers |> Map.get("link", []) |> List.first()

  with binary when is_binary(binary) <- link,
       [_, url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, binary) do
    url
  else
    _ -> nil
  end
end
```

Two edge cases:

1. **Multi-rel headers.** RFC 5988's `Link` header can contain
   multiple comma-separated entries:
   `<...>; rel="prev", <...>; rel="next", <...>; rel="last"`.
   The regex `<([^>]+)>;\s*rel="next"` correctly matches the
   `next` portion when it's anywhere in the string — `<([^>]+)>`
   doesn't span across `>` characters, so the first match
   short-circuits. ✓
2. **Header lookup case sensitivity.** The PR uses lowercase
   `"link"`. `Req`'s normalised headers are lowercase, so this is
   correct for the current setup, but a switch to a different HTTP
   client (Mint, Finch, Tesla) would silently break unless the
   header lookup is canonicalised. Worth a `String.downcase/1` on
   the header key for portability — or a comment that `Req` is the
   contract.

**Where:** `lib/phoenix_kit/known_packages.ex:181-189`

### NITPICK — Logger.warning vs Logger.error split is correct but undocumented

`handle_hex_failure/3` uses three log levels:

| Condition | Level |
|---|---|
| Cached, within max_stale_age — serving stale | `:warning` |
| Cached, exceeds max_stale_age — dropping | `:error` |
| No cache — extras-only | `:warning` |

The "exceeds max stale age" → `:error` is the operationally important
signal: it's the case where the admin Modules page degrades to
extras-only because Hex has been unreachable for over 24h. Worth a
moduledoc note tagging the levels so on-call doesn't have to read
the source to understand which Hex outage trips which alert.

**Where:** `lib/phoenix_kit/known_packages.ex:96-129`

## What's good

- **Stale-while-revalidate with a cap is the right shape.** A naïve
  cache says "if Hex is down forever, the catalog stays empty." A
  naïve fallback says "always serve whatever's in the cache." This
  PR's pattern — serve stale up to 24h, then drop — bounds the
  cache's freshness without the admin page going dark on the first
  Hex outage. Two log levels make the operational state observable.
- **Test coverage is excellent.** 11 tests, every error path covered
  with explicit stubs:
  - Happy path with shaping assertions
  - Hex 500 (HTTP error path)
  - Transport error (raise in stub)
  - Malformed 200 body (non-list)
  - Pagination (multi-page Link header)
  - Cache hit (call-count via `:counters.new`)
  - Cache clear → re-fetch
  - Stale-served / stale-dropped boundaries (with `:timer.sleep` for
    the "exceeds max" case)
  - Config extras valid + extras-wins-on-collision
- **`Req.Test.stub/2` for HTTP isolation.** No real Hex roundtrip in
  tests. The stub setup is one helper (`stub_hex/1`) used across
  the file; per-test stubs only when behaviour-specific (`:counters`
  call count, status codes).
- **`hex_docs_icon_name:` convention.** The icon-marker pattern lets
  package authors opt into a custom catalog icon by editing their
  Hex package description — no PhoenixKit-side patch needed. The
  marker is stripped from the displayed text so users don't see the
  hint. Default fallback (`hero-puzzle-piece`) keeps the catalog
  visually consistent for packages that don't opt in.
- **Config-extras override is the right escape hatch.** Parent apps
  with private packages don't have to run a fork of PhoenixKit —
  they declare in app config, and the catalog merges them in. The
  `source: "config"` tag on the merged record makes the precedence
  observable in the UI / logs.
- **`not_installed_packages/0` semantic upgrade.** Old check:
  `Code.ensure_loaded?(pkg.module)` (which depended on the `:module`
  atom existing in the registry list — itself derived from a Hex
  package name). New check:
  `MapSet.member?(installed_otp_apps, pkg.package)` — directly asks
  the Application registry whether the OTP app is installed. More
  correct because module-loading state and OTP-app-installed state
  aren't the same: an extracted-but-not-yet-installed module
  fragment could pass `Code.ensure_loaded?` but isn't actually a dep.
- **`test_helper.exs` `try/rescue ErlangError`.** Orthogonal to the
  PR's main subject but useful — in environments where `psql`
  isn't on PATH (Nix / Bazel / minimal CI), the previous
  `System.cmd` would crash the test boot. Now it falls through to
  the connect-direct branch.
