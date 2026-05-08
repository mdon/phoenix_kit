# PR #524 — Add publishing routing-strategy shim to `phoenix_kit_routes/0`

**Author:** @mdon
**Branch:** `fix/route-collision-router-dispatch` ← `dev`
**Merged:** 2026-05-08T21:16:03Z (`588f3b4a`)
**Diff:** +138 / -0 (2 files, 1 commit)
**URL:** https://github.com/BeamLabEU/phoenix_kit/pull/524

## Verdict

**APPROVE** with a few elevated NITPICKs around the lack of automated
test coverage for what is a *router-level interception*.

The bug being fixed is real and load-bearing: publishing's
`/:language/:group/*path` catch-all matched every 2+-segment URL
under `url_prefix: "/"`, shadowing every host route shaped
`/:locale/<literal>/...` that was declared after `phoenix_kit_routes()`.
The PR body's canary case (`/fr/services/view/nos-services-a-nice`
→ 404 because publishing's controller matched first and didn't find
the group) is the kind of thing that's silently broken until someone
reports it.

The fix flips the trust direction: instead of publishing claiming
the root and the host hoping no URL collides, publishing's catch-all
now lives under an internal-prefix scope and a `def call/2` override
on the host router rewrites *only* URLs that resolve to known
publishing groups. Host routes get a fair shot at every URL.

The shape is right. Findings below are about ergonomics
(`mix phx.routes` blind spot is acknowledged), test coverage (zero
automated tests for the new macro AST — entirely smoke-tested), and
the `def call/2` override's compose-ability with future extensions.

## What changed

| Layer | Change |
|---|---|
| `lib/phoenix_kit_web/integration.ex` | New private `compile_publishing_routing/1` — emits internal-prefix scope + `def call/2` override AST when `PhoenixKitPublishing.RouterDispatch` is loaded; emits `quote do end` no-op AST otherwise |
| `phoenix_kit_routes/0` | Splices the result of `compile_publishing_routing(url_prefix)` at the end of the macro expansion |
| Internal scope | `/<url_prefix>/__phoenix_kit_publishing_dispatch` with two sub-scopes — `/localized` (binds `:language` + `:group`) and `/root` (binds `:group` only). Discriminator avoids first-match-wins collisions between the two forms. |
| Pipeline | New `:phoenix_kit_publishing_internal` runs `RouterDispatch.restore_path/2` after route binding so canonical-URL generation reads the original client path, not the internal-prefix path |
| `def call/2` override | Calls `RouterDispatch.maybe_rewrite/1`; on cache hit, prepends internal prefix to `path_info` + `request_path` and stashes originals in `conn.private`; then `super(conn, opts)` runs Phoenix's matcher against the internal-prefix scope. On miss, conn passes through unchanged. |
| `AGENTS.md` | New "Publishing routing strategy" subsection — documents the three-piece mechanism, the `mix phx.routes` blind spot, and the don't-generalize-prematurely posture |

## Findings

### IMPROVEMENT - MEDIUM — No automated test coverage for the macro AST

The PR body's verification is:

- `mix format` / `mix credo` / `mix dialyzer` — clean (none of which
  exercise the macro AST shape).
- `mix test` — 1055 tests, 4 pre-existing failures (none touch this
  PR's code path).
- Browser smoke matrix on a workbench parent app (8 URL classes).
- Canary install on a separate parent app.

**Zero automated tests** verify:

1. The compile-time `Code.ensure_loaded?` branch emits the expected
   `quote do end` no-op when publishing is absent.
2. The `:phoenix_kit_publishing_internal` pipeline is wired in the
   correct order (after `:phoenix_kit_optional_scope`, before
   the controller — the order matters for the path-restore to
   happen before canonical URL generation).
3. The `def call/2` override's `:pass` branch leaves the conn
   unchanged. A regression here (e.g., a future commit that
   accidentally touches `conn.path_info` in the pass-through path)
   would silently break every host route.
4. The discriminator scopes (`/localized` vs `/root`) actually
   prevent the first-match-wins collision that motivated their
   existence. A test where `RouterDispatch.maybe_rewrite/1`
   returns the localized rewrite and the matcher binds the right
   variables would pin this contract.

The browser smoke is the right *empirical* check, but a router-level
interception is exactly the kind of code where "works on my machine"
diverges from "works in CI for the next year." A `Phoenix.Router`-style
test that mounts a tiny test router with the macro applied, stubs out
`RouterDispatch.maybe_rewrite/1` to return a rewrite, and asserts the
internal-prefix path bound the expected variables would close the gap.

This is the kind of test that's not free to write (router test setup
is non-trivial) but the *blast radius* of a regression is "every host
route in every parent app." Worth the investment in a follow-up.

**Where:** No test file for `lib/phoenix_kit_web/integration.ex`'s
new code path

### IMPROVEMENT - LOW — `def call/2` override doesn't compose with host-defined `def call/2`

`compile_publishing_routing/1` emits:

```elixir
def call(conn, opts) do
  conn =
    case PhoenixKitPublishing.RouterDispatch.maybe_rewrite(conn) do
      {:rewrite, rewritten} -> rewritten
      :pass -> conn
    end

  super(conn, opts)
end
```

This is correct *as long as the host doesn't define its own
`def call/2`*. Phoenix.Router publishes `defoverridable init: 1,
call: 2` from `match_dispatch/0`, which means the host can override
`call/2`, *and* this macro can override it. But override order is
defined by macro splice order:

1. `phoenix_kit_routes()` is called inside the host router.
2. The macro expansion includes this `def call(conn, opts)`.
3. If the host *also* defines `def call(conn, opts)` after
   `phoenix_kit_routes()`, that one wins and PhoenixKit's never
   runs → publishing-bound URLs go back to first-match-wins
   collision.
4. If the host defines `def call(conn, opts)` *before*
   `phoenix_kit_routes()`, this macro's override wins and the
   host's never runs → host instrumentation/telemetry/whatever
   gets bypassed for publishing URLs.

Two mitigations to consider:

1. **Document the constraint in `phoenix_kit_routes/0`'s
   moduledoc** — "Hosts that define their own `def call/2` must
   explicitly call `super(conn, opts)` and place
   `phoenix_kit_routes()` such that the macro's override runs
   first."
2. **Use a `Plug` instead of a `def call/2` override.** The
   `RouterDispatch` rewrite logic could live in a Plug that the
   host adds to their endpoint pipeline before `Phoenix.Router`'s
   plug. Same effect, no override-order dance, composable with
   any host instrumentation.

The Plug approach is the more Phoenix-idiomatic shape — `defoverridable
call: 2` is a documented extension point but not the canonical one
for "rewrite the conn before routing." Out of scope for this PR
given the constraint that publishing already exists with a specific
shape; worth flagging for the next revision.

**Where:** `lib/phoenix_kit_web/integration.ex:1267-1278`

### NITPICK — `mix phx.routes` blind spot is acknowledged but undocumented in dev_docs

AGENTS.md notes:

> `mix phx.routes` shows publishing routes under the internal prefix,
> not at the user-facing URL — known blind spot, surface in support
> docs.

The "support docs" referenced don't exist in this PR or in `dev_docs/`.
Three concrete shapes for closing this:

1. **A custom mix task** (`mix phoenix_kit.routes`) that
   post-processes `mix phx.routes` output, replacing the internal
   prefix with the user-facing URL pattern.
2. **A doc note in `dev_docs/instructions/`** for parent-app
   maintainers debugging routing.
3. **A `Logger.info` log line on application start** that prints the
   user-facing URL → internal-prefix mapping once at boot, so
   operators have it in their logs without needing to remember the
   blind spot exists.

For now the AGENTS.md note is the only documentation. A future
"why doesn't `mix phx.routes` show my publishing pages?" question
will hit a single google-able sentence.

**Where:** `AGENTS.md:691-693`

### NITPICK — `apply/3` to dodge compile-time "undefined function" warning

`lib/phoenix_kit_web/integration.ex:1219-1221`:

```elixir
internal_prefix = apply(PhoenixKitPublishing.RouterDispatch, :internal_prefix, [])
localized_segment = apply(PhoenixKitPublishing.RouterDispatch, :localized_segment, [])
root_segment = apply(PhoenixKitPublishing.RouterDispatch, :root_segment, [])
```

The inline comment correctly explains that `apply/3` shields the
compiler's static-resolution pass when calling into an optional dep:

> `apply/3` is the idiomatic dodge for the compile-time "undefined
> function" warning when calling into an optional dep — the
> `Code.ensure_loaded?/1` guard above is the runtime correctness
> check; `apply/3` shields the compiler's static-resolution pass.

This is *correct* but worth a one-line elaboration: the macro's
`Code.ensure_loaded?/1` is at *macro-expansion time*, which is the
host's compile time. When `mix compile` runs, the macro expands and
either emits the `apply` calls or the no-op AST. The `apply` calls
are then compiled into the host BEAM and resolved at runtime via
the dispatch table. So the apply has to succeed at *runtime*, not
just compile time. If a host removes publishing from their deps
without recompiling core, the cached BEAM still has the `apply`
calls baked in → runtime `UndefinedFunctionError`.

The existing `__mix_recompile__?/0` mechanism (host router
auto-recompiles when discovered modules change, see
`integration.ex:1184-1186`) covers the dep-removal case. Worth a
sentence in the macro's comment confirming that the recompile
guard is what makes the `apply` safe across dep changes.

**Where:** `lib/phoenix_kit_web/integration.ex:1216-1224`

### NITPICK — "Don't generalize prematurely" posture is correct but the surface area is small enough to lift now

The AGENTS.md note explicitly opts into the YAGNI posture:

> The mechanism generalizes to any future module with a similar
> dynamic catch-all problem. For now it's hardcoded to publishing
> per the "don't generalize prematurely" principle; lift to a
> registry shape when a second module needs it.

This is the right discipline in general, but the mechanism here
*is* small (~40 lines of macro AST emission) and the trigger for
"we need a registry" is "a second module wants the same shape."
Lifting would mean turning `compile_publishing_routing/1` into:

```elixir
defp compile_dispatch_routing(url_prefix) do
  for module <- discover_dispatch_modules() do
    emit_dispatch_scope(module, url_prefix)
  end
end
```

Where `discover_dispatch_modules/0` walks `ModuleRegistry` for any
module exporting a documented `RouterDispatch`-shape callback. The
`def call/2` override would chain the rewrites:

```elixir
def call(conn, opts) do
  conn = apply_rewrites(conn, [Module1, Module2, ...])
  super(conn, opts)
end
```

The complexity argument is valid — registry-based abstraction in
this layer is non-trivial and has its own footguns. Just flagging
that the next time someone hits this same shape, the lift cost
won't be much higher than the current hardcoded form.

**Where:** `lib/phoenix_kit_web/integration.ex:1166-1278`,
`AGENTS.md:691-697`

### NITPICK — Per-request cost of `RouterDispatch.maybe_rewrite/1` not characterized

The override runs `RouterDispatch.maybe_rewrite(conn)` on every
request reaching the host router. The PR body says "cache hit /
miss" but doesn't characterize the cache shape, hit rate, or
worst-case latency. A request to `/some-unknown-route` (the URL not
in the publishing cache) needs to reach the cache miss path and
then fall through to host routes.

The mitigation pattern (cache lookup before any DB access) is in
the *publishing* PR (`#14`), which this PR pairs with — the load
characteristics are properly that PR's review surface. But it's
worth a one-line note in this PR's AGENTS.md section:

> Per-request cost: cache lookup in
> `RouterDispatch.maybe_rewrite/1` runs on every request. See
> publishing PR #14 for the cache shape (ETS table, populated
> from listing-cache + DB on cold start).

So a future operator chasing latency on an unrelated route knows
to look at the publishing cache.

**Where:** `lib/phoenix_kit_web/integration.ex:1267-1278`,
`AGENTS.md:691-697`

## What's good

- **The bug is real and the framing is right.** `phoenix_kit_legal`
  transitively pulling publishing → publishing's catch-all silently
  shadows host routes → 404s on `/fr/services/view/foo`. The PR
  body's canary case is concrete and reproducible. Not a hypothetical
  fix.
- **Compile-time gate is correctly conditional.** Hosts without
  publishing in their deps get `quote do end` (no-op AST) — zero
  behaviour change, zero compile cost beyond the
  `Code.ensure_loaded?/1` check. ✓
- **Discriminator scopes are load-bearing.** The `/localized` vs
  `/root` split inside the internal prefix is *not* cosmetic — the
  comment on `:1247-1252` explains exactly why a 2-segment internal
  path would otherwise hit the wrong route via first-match-wins,
  binding `language=<group-slug>` and 404'ing in the controller.
  This is the kind of subtle Phoenix.Router quirk that's easy to
  not catch without the discriminator.
- **`restore_path/2` for canonical URLs.** Without it, publishing's
  `default_language_no_prefix` redirect would loop on the internal
  prefix forever. This is the kind of side-effect that only shows
  up in production after deploy; the PR caught it in the canary,
  which is exactly what canaries are for.
- **Coordination notice is honest.** The PR body explicitly enumerates
  the three version-coupling shapes (old core + new publishing →
  regression; new core + old publishing → no-op AST; both new →
  bug fixed). Forces the maintainer to ship in the right order.
- **`__mix_recompile__?/0` integration.** The existing
  `module_hash` recompile mechanism (referenced at
  `integration.ex:1184-1186`) handles the dep-changes case for
  this PR's apply/3 calls. The hash includes the discovered
  module set; adding/removing publishing changes the hash → host
  router recompiles → new AST is generated. ✓
- **AGENTS.md section is well-written.** Names the three pieces,
  explains *why* each piece exists (especially the discriminator
  rationale), surfaces the `mix phx.routes` blind spot, and
  declares the don't-generalize-prematurely posture explicitly.
  Future maintainers reading this section will understand the
  shape without having to reverse-engineer it from the macro
  source.
- **No `lib/` test churn.** The PR body's 4 pre-existing test
  failures are independently verified by stashing the diff. This
  PR adds zero false-positive flakes.
- **Bug-fix PR scope is right.** 138 lines of additive code in 2
  files. No collateral cleanup, no opportunistic refactors, no
  "while I was in here…" — just the fix and its docs. Easy to
  revert if a corner case shows up post-merge.
