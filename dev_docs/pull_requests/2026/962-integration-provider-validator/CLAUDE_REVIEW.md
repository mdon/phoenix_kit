# PR #962 — Let a module that contributes an integration provider supply its connection check

**Author:** timujinne · **Merged:** 2026-10-23 (570ba3211) · **Reviewer:** Claude

## Summary

A provider contributed by another module (`integration_providers/0`) could not add a named strategy to `Integrations.do_validate/2`, so "Test Connection"
could only answer "not verified". It now declares `validation: %{strategy: :module, module: Mod}`; `Mod` implements the new
`PhoenixKit.Integrations.Validator` (`validate_connection/1`). The clause runs ahead of the auth-type clauses, through `Probe.run/1` (own process, hard
deadline, operator's locale), after a required-fields gate, and the answer is normalised by `module_verdict/1`. `:unverified` joins the `Probe.check` type.

Verdict: correct. The 20 new tests pass (`PGDATABASE=beamlab_test mix test test/phoenix_kit/integrations/module_validation_test.exs`) and cover every
verdict, raise/throw/exit, the deadline, the log (no credentials, no answer body), locale, the pre-save path and the three "cannot check" shapes.

## Verified

- Clause order: `do_validate/3` (object_storage, smtp) only matches those strategies, so a `:module` provider falls through to `/2` and the `:module` clause
  runs before `:oauth2` and the `api_key`/`bot_token` generic clause. Nothing else in `lib/` reads `provider.validation.url`/`auth_header`, so a
  `validation` map without them breaks no other consumer.
- A saved row with `"status" => "connected"` passes `has_credentials?/1` with no key at all; `required_fields_filled?/2` is what stops it reaching the
  module, and a test pins that.
- `module_check/2` rescues and catches inside the `Probe.run` process, so the credentials in the call arguments never reach a crash report; only
  `LogSafe.exception_label/1` is logged. `Probe`'s own `:DOWN` branch covers an untrappable kill.
- Required setup fields are `:text`, `:password`, `:number` or `:select`, all stored as strings (`setup_attrs/2` does `to_string |> String.trim`), so
  `present?/1` (binary and non-empty) is the right test.
- Gettext: the one new string is in `default.pot` and all nine `.po` files, none fuzzy.

## Findings

- **NITPICK (fixed):** the `Validator` moduledoc said the module gets "the setup fields". On the saved path it gets the whole stored data map
  (`"status"`, `"provider"`, ... sit beside the fields; `has_credentials?/1` reads them from the same map). Reworded so a module author matches the
  keys they need and ignores the rest.
- **IMPROVEMENT - MEDIUM (not changed, documented in the moduledoc):** the module is not told whose connection it checks, so a provider with
  `scopes: [:personal]` whose check dials a host typed into a setup field cannot apply the personal policy (`Storage.Endpoint.check/3` `:personal`,
  `SmtpEndpointPolicy`). The limitation is stated and the provider author controls the check, so no fix here. If a contributing module needs it, add an
  optional `validate_connection/2` taking `owner:` rather than widening `/1`.
- **NITPICK (not changed):** `module_check?/1` logs a warning on every validation of a provider whose module has no `validate_connection/1`. That is
  deliberate (a misdeclared provider should be loud) and the volume is one line per operator click.
