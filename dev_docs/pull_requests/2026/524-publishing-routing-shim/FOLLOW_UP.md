# PR #524 — Follow-up

Triage of `CLAUDE_REVIEW.md` against current code.

## Fixed

- ~~**NITPICK: `apply/3` runtime resolution comment doesn't mention
  `__mix_recompile__?/0`.** Expanded the leading comment on
  `compile_publishing_routing/1` (`lib/phoenix_kit_web/integration.ex:1218-1227`)
  with a paragraph explaining the runtime resolution path: the host
  BEAM compiles the macro expansion containing literal `apply` calls
  into `RouterDispatch`, and the existing
  `__mix_recompile__?/0` mechanism (injected by `phoenix_kit_routes/0`)
  forces a host-router recompile when the discovered module set
  changes. Removing publishing flips the recompile hash → BEAM is
  regenerated without the `apply` calls → no `UndefinedFunctionError`
  at runtime. Closes the "what about `mix deps.compile` cache
  staleness?" gap.~~

- ~~**Pre-existing credo refactoring opportunities (3) on the `apply/3`
  calls in `compile_publishing_routing/1`** — silenced with inline
  `# credo:disable-for-next-line Credo.Check.Refactor.Apply`
  annotations on each of the three calls. Verified empirically that
  the variable-indirection alternative (`mod = ModuleName; mod.fun()`)
  does NOT shield the compiler's static-resolution warning — Elixir's
  compiler tracks the binding's value and still emits
  `UndefinedFunctionError` warnings on the dispatch. `apply/3` remains
  the only escape valve for this specific shape; the leading comment
  block now documents that empirical finding so the next reader doesn't
  re-derive it. `mix credo --strict` now reports zero issues across
  the whole tree.~~

## Skipped (deferred / out-of-scope)

- **IMPROVEMENT - MEDIUM: No automated test coverage for the macro
  AST.** A `Phoenix.Router`-style test mounting a tiny test router
  with the macro applied + stubbed `RouterDispatch.maybe_rewrite/1`
  would close the gap. Non-trivial setup; worth doing as a separate
  PR — high blast radius if a future commit silently breaks
  publishing-bound URL rewriting. Out of scope here.
- **IMPROVEMENT - LOW: `def call/2` override doesn't compose with
  host-defined `def call/2`.** Plug-based alternative is the more
  Phoenix-idiomatic shape. Architectural concern; out of triage
  scope.
- **NITPICK: `mix phx.routes` blind spot.** AGENTS.md notes the
  blind spot but no support docs / Logger.info / custom mix task
  exists. Worth a future "support tooling" PR.
- **NITPICK: "Don't generalize prematurely" posture.** Workspace
  preference; lift to registry shape when a second module needs the
  same pattern.
- **NITPICK: Per-request cost of `RouterDispatch.maybe_rewrite/1`.**
  Belongs in publishing PR #14's review surface, not core's. AGENTS.md
  sidebar note about the cache shape would be a nice forward
  reference; out of triage scope.

## Open

None.
