# PR #830 — Read the provider's text body when an email template comes from the database

**Author:** Timujeen (`fix/db-template-text-body`) · **Merged:** 2026-09-18 · **Reviewed:** 2026-09-18 (post-merge)

2 files: `lib/phoenix_kit/email/content.ex` swaps `rendered.text` for
`rendered.text_body` in `resolve/5`'s database branch; a new
`test/phoenix_kit/email/content_db_template_test.exs` covers that branch.

## Verdict

Correct, and the commit message's account of the bug checks out end to end. One
IMPROVEMENT, not applied — see below.

Every claim verified against the producing code rather than the description:

- `PhoenixKit.Email.DefaultProvider.render_template/2,3` returns
  `%{subject: "", html_body: "", text_body: ""}` (`lib/phoenix_kit/email/default_provider.ex:24`).
  There is no `:text` key anywhere in a provider's answer, so the old
  `rendered.text` raised `KeyError` on **every** send that found an active
  template. The fix is the only shape that works.
- The consumers do read `.text`: `UserNotifier.deliver_templated/5`
  (`user_notifier.ex:48`) and both `Mailer` send paths (`mailer.ex:213`,
  `mailer.ex:694`). So normalising to `:text`/`:html` inside `resolve/5` — rather
  than changing the three call sites — is the right side of the boundary to fix.
- The fallback branch is untouched and still returns what `Templates.render/4`
  produced, so the two branches now genuinely answer in one shape.
- The new test pins both branches, including the fallback, which is what stops a
  future change from quietly swapping which shape wins. 5 tests, all passing.
  `async: false` is correct — it swaps the global `:email_provider`.

## IMPROVEMENT - MEDIUM — the behaviour callback is typed `map()`, which is why nothing caught this

`PhoenixKit.Email.Provider` declares:

```elixir
@callback render_template(map(), map()) :: map()
@callback render_template(map(), map(), String.t()) :: map()
```

A bare `map()` return is why a total shape mismatch survived dialyzer *and* a
`--warnings-as-errors` compile. Naming the three keys the contract actually
requires would make this class of bug a build failure instead of a runtime one:

```elixir
@type rendered :: %{
        required(:subject) => String.t(),
        required(:html_body) => String.t(),
        required(:text_body) => String.t(),
        optional(atom()) => term()
      }
```

**Not applied deliberately.** The behaviour's real implementor is a *separate*
package (`phoenix_kit_emails`), and tightening a callback return type is checked
against implementors — so this reddens that repo's dialyzer the moment it picks
up the new core, for a payoff that only lands once both sides move. It belongs in
a coordinated cross-repo change, not in a post-merge fix to a one-line bug, and
the open map form above is the shape to use when it happens.

## Note (no action)

`text: rendered.text_body` now propagates a `nil` where the old code raised, if a
provider ever answers `text_body: nil`. That is strictly better than crashing the
caller's LiveView — Swoosh accepts a nil text body when an html body is present —
and neither core's `DefaultProvider` nor `phoenix_kit_emails` can produce it
(the latter validates all three keys on every render).
