# PR #668 — SMTP encryption/auth/certificate/timeout settings + optional queue hook

**Author:** timujinne (Tymofii Shapovalov)
**Reviewer:** Claude Opus 5
**Date:** 2026-07-28
**Verdict:** ⚠️ APPROVE WITH FIXES — already merged. One HIGH that breaks the
project's own release gate, one MEDIUM that makes two of the PR's headline
settings impossible to reach from the UI, two MEDIUM robustness gaps, three
NITPICKs. All fixed post-merge.

---

## Summary

Three things on the email surface:

1. **SMTP transport settings.** Five optional setup fields (`security`, `auth`,
   `verify_cert`, `ca_cert`, `timeout`) on the `smtp` provider, parsed in
   `SmtpTransport.config/2`. Blank reproduces the old port-based rule exactly,
   unknown values are refused rather than coerced back to `auto`, and the
   probe (`Validators.smtp/1`) builds from the very same options — so "tests
   green" and "sends green" cannot drift.
2. **Setup-field rendering.** `setup_field/1` renders by `:type` instead of
   forcing `type="text"`, and the website-wide integration form drops its
   hand-rolled copy of that markup for the shared component.
3. **An optional `maybe_enqueue/2` provider callback**, offered on both delivery
   paths right after interception, so a queue package can take over the host's
   password resets and confirmations — not just what its own API sent.

The transport work is careful, and the reasoning in the comments is the good
kind: it names the failure each line prevents (`depth: 10` vs gen_smtp's
`{depth, 0}`, `ssl` vs `tls` on 465, `no_mx_lookups`). The parse layer refusing
unknown values instead of falling back to `auto` is exactly right — a typo in
`security` must not silently downgrade a connection's encryption.

What follows is what it got wrong.

---

## BUG - HIGH — the dialyzer gate fails, so `mix precommit` cannot pass

**`lib/phoenix_kit_web/live/settings/email_sending.ex:193`**

```elixir
defp loggable_sender?(email) when is_binary(email),
  do: Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, email)

defp loggable_sender?(_), do: false
```

```
lib/phoenix_kit_web/live/settings/email_sending.ex:193:8:pattern_match_cov
The pattern :variable_ can never match, because previous clauses completely
cover the type binary().
```

`Mailer.get_from_email/0` is the only caller and always returns a binary (its
last fallback is the literal `"noreply@localhost"`), so the catch-all is dead
code. `mix dialyzer` halts with exit status 2, which fails `quality.ci`, which
fails `precommit` — and because `precommit` runs its steps in order, everything
after `quality.ci` (including this PR's sibling `test.js` step from #669) never
runs at all.

This is easy to miss locally: `mix precommit 2>&1 | tail -60` reports the exit
code of `tail`, not of mix. It has bitten this repo before; the pipeline has to
be checked with `echo "EXIT=$?"` on the *unpiped* command.

**Fixed** — one clause, no unreachable head, same defensiveness:

```elixir
defp loggable_sender?(email),
  do: Regex.match?(~r/^[^\s]+@[^\s]+\.[^\s]+$/, to_string(email))
```

`to_string(nil)` is `""`, which the regex rejects, so a non-binary settings
value still answers `false` instead of crashing the settings page.

---

## BUG - MEDIUM — `auth: never` and `security: none` cannot be configured

**`lib/phoenix_kit/integrations/providers.ex`** (smtp provider) +
**`lib/phoenix_kit/integrations/validators.ex`**

The PR adds an "Authentication → Never" option whose own help text reads
*"Never is for relays that authenticate by IP"*, and a "None — plaintext"
encryption option for *"an internal relay in the clear"*. Neither is reachable:
the `smtp` provider still declares

```elixir
%{key: "username", required: true, …},
%{key: "password", required: true, …},
```

so the relay that has no login is refused twice over:

1. the rendered `<input required>` blocks form submission, and
2. `Integrations.has_flat_credential_fields?/2` requires **every** required
   field to be present, so `connected?/1` is false — meaning
   `Mailer.default_send_integration_uuid/0` returns `:error` and *all* mail
   silently falls back to the built-in mailer even if the operator selected the
   connection as the default sender.

The transport layer has always been built for this case and says so —
`credentials?/1` picks `starttls_optional` over `starttls` for a login-less
relay, and the `:no_ca_store` rule degrades instead of failing closed
*specifically* because "a relay that takes no credentials has nothing to
protect". The provider definition was the only thing standing in the way.

There is a second half to it. Even with the fields made optional, the Test
Connection probe would fail on every such relay: `probe_auth/1` upgrades
`if_available` → `always` to stop a wrong password passing the check, which for
a connection with *no* password demands an AUTH exchange it has nothing to send.

**Fixed** — `username`/`password` are `required: false`. `host` and `port` stay
required, so `has_flat_credential_fields?/2`'s empty-list footgun guard is
unaffected, and the absent `*` is the UI signal. Their `help` strings are
deliberately left byte-identical: both msgids are translated in all eight
locales, and appending a "leave blank for an IP-authenticated relay" sentence
would orphan every one of those translations — the `security` and `auth` selects
already carry that hint in their own (new, as-yet-untranslated) help text.

`probe_auth/1` gained the symmetric case:

```elixir
cond do
  Keyword.get(options, :auth, :if_available) == :never -> :never
  blank?(options[:username]) and blank?(options[:password]) -> :never
  true -> :always
end
```

Tests added: `providers_test.exs` asserts the required-field set and saves an
IP-authenticated relay end to end; `smtp_transport_test.exs` asserts the whole
shape (`auth: :never`, `tls: :never`, no `ssl`, no `tls_options`) in one go,
because each half passing alone says nothing about the pair.

---

## BUG - MEDIUM — a cleared optional field silently keeps its old value (personal integrations)

**`lib/phoenix_kit_web/live/integrations/my_integration_form.ex:340`**

The two integration forms disagree about blanks. The website form
(`Settings.IntegrationForm.extract_setup_attrs/2`) persists an empty string for
everything except `:password`. The personal form dropped blanks for *every*
field:

```elixir
case params[key] do
  v when is_binary(v) and v != "" -> Map.put(acc, key, v)
  _ -> acc
end
```

Before this PR that asymmetry was nearly invisible — the flat providers'
optional fields were short scalars nobody clears. This PR adds a **textarea**
holding a pasted CA bundle and a numeric timeout, both of which an operator will
realistically want to remove. Clearing either one, saving, and getting a
"Saved" flash while the old PEM keeps being used for TLS is a bad failure: the
form shows empty, the connection does not.

**Fixed** — the personal form now mirrors the website rule exactly (drop blanks
for `:password` only) and trims like it too, so a trailing space in an SMTP host
can no longer break SNI on one path but not the other.

Not covered by a test: `setup_attrs/2` is a private function of a LiveView with
no existing test module, and standing one up needs the DB. Recorded here rather
than half-covered.

---

## IMPROVEMENT - MEDIUM — the soft-map-access hardening stopped at the renderer

**`lib/phoenix_kit_web/components/core/integrations_ui.ex`** vs the two save paths

`setup_field/1` was deliberately made tolerant of a field map with no `:type`,
with a good reason at the call site: providers can be contributed by external
modules through `integration_providers/0`, and one missing key must not take the
whole form down with a `KeyError`.

But `Settings.IntegrationForm.extract_setup_attrs/2` still did `field.type ==
:password`. So such a provider renders fine and then raises on **save** — the
worst of both worlds, since the operator loses everything they typed and the
crash happens after they committed to it.

**Fixed** — `Map.get(field, :type)` on both save paths, so tolerance is
consistent from render through persist.

---

## NITPICK — `parse_timeout/1` accepted a number with a unit

`Integer.parse("30s")` returns `{30, "s"}`, and `Integer.parse("30 minutes")`
returns `{30, " minutes"}`. Both passed the `{int, _} when int > 0` clause, so
an operator who typed "30 minutes" got a 30-second timeout with no complaint —
a wrong answer dressed as a lenient one, and one the `<input type="number">`
does not prevent for a stored value or an external caller.

**Fixed** — the remainder must be empty; test added for both shapes.

---

## NITPICK — `deliver_via_integration/3`'s documented error list went stale

Its `@doc` enumerates every `{:error, _}` a caller can pattern-match, down to
`{:invalid_smtp_port, term()}`. The PR added five more reasons
(`:invalid_security`, `:invalid_verify_cert`, `:invalid_auth`,
`:invalid_timeout`, `:invalid_ca_cert`) and left the list alone.

**Fixed** — the list now names them, and says why they are errors rather than a
silent fallback to `auto`.

---

## NITPICK — `skip_queue: true` re-runs the interceptor, and nothing said so

`intercept_and_offer_queue/2` runs `intercept_before_send/2` *before* checking
`skip_queue`, so a queued message passes through the tracking interceptor twice:
once when it was accepted into the queue, once when the worker delivers it. That
is arguably right — the second pass is a genuine send attempt and the callback
is where a provider stamps its tracking header — but a package author reading
`maybe_enqueue/2`'s doc would not expect it, and the obvious naive
implementation double-logs every queued message.

Core cannot dedupe this (it has no idea what the provider records), so it is
documented rather than changed: `Provider.maybe_enqueue/2` now carries a warning
admonition spelling out that the worker's re-send is intercepted again and that
the provider must recognise its own message.

---

## Checked and found correct

Recording these so a later reviewer does not re-derive them:

- **`resolve_cacerts/4` skipping PEM validation for `:none` / `:verify_none`.**
  Deliberate and right — rejecting a plaintext relay over a stale PEM in a field
  that transport never reads would be an error about a certificate that would
  not have been used.
- **`transport(:auto, 465, …)` delegating to `:ssl`.** The `resolve_cacerts`
  call upstream was made with `security = :auto`, but that function only
  special-cases `:none`, so the store is identical either way.
- **`auth:` added to `base` rather than to the transport options.** gen_smtp
  reads `auth` from the top-level option list; `Validators.probe_auth/1` reads
  it back from there, which is what keeps probe and send in step.
- **The `:no_ca_store` fail-closed rule is still unreachable from `auto`.** Only
  an explicit `verify_none` or `security: none` bypasses it, exactly as the
  moduledoc claims.
- **`put_flash(socket, :warning, …)`** on the sender-identity save renders:
  `Core.Flash` declares `values: [:info, :warning, :error]` and `flash_group/1`
  emits a `:warning` slot.
- **`has_flat_credential_fields?/2`** is unaffected by the five new fields —
  it filters on `& &1.required`, and all five are `required: false`.

---

## Verification

- `mix format` — clean.
- `mix precommit` (format check + credo --strict + dialyzer + compile with
  warnings as errors + `test.js`) — clean, exit 0, verified unpiped.
- `mix test` for the touched unit suites — 0 failures. Integration tests are
  auto-excluded here (no PostgreSQL), per the repo's standalone-testing stance.

---

## Post-release verification (1.7.217, 2026-07-28)

Independent re-check of the released tree (`d7008e00`) against the findings
above — every claimed fix confirmed present in code, not just in the commit
message:

- HIGH: `loggable_sender?/1` is the single `to_string/1` clause
  (`lib/phoenix_kit_web/live/settings/email_sending.ex:196`) — no unreachable
  head.
- MEDIUM: smtp `username`/`password` are `required: false`
  (`lib/phoenix_kit/integrations/providers.ex:780`, `:792`), `host`/`port`
  stay required; `probe_auth/1` has the symmetric no-login → `:never` branch
  (`lib/phoenix_kit/integrations/validators.ex:134`).
- MEDIUM: the personal form drops blanks for `:password` only and trims
  (`lib/phoenix_kit_web/live/integrations/my_integration_form.ex:345`),
  matching the website rule.
- IMPROVEMENT: `Map.get(field, :type)` on both save paths
  (`lib/phoenix_kit_web/live/settings/integration_form.ex:590`,
  `my_integration_form.ex:349`).
- NITPICKs: `parse_timeout/1` requires an empty remainder
  (`lib/phoenix_kit/mailer/smtp_transport.ex:151`); the five new error reasons
  are documented on `deliver_via_integration/3`
  (`lib/phoenix_kit/mailer.ex:336`); the double-interception warning admonition
  is on `maybe_enqueue/2` (`lib/phoenix_kit/email/provider.ex:31`).

Gates re-run on the release commit:

- `mix quality.ci` — credo 0 issues, dialyzer passed, exit 0 (the exact gate
  the HIGH was breaking).
- `mix format --check-formatted` — clean.
- `mix test` on `smtp_transport_test.exs` + `providers_test.exs` — 30 tests,
  0 failures. Integration tests auto-excluded (no PostgreSQL here).
