# PRs #881, #884, #885 — review

Merged 2026-10-01 (`8d1f308bc`, `8f1d175c2`, `61bb4fd1b`) · **Reviewer:** Claude

| PR | Author | Title |
|---|---|---|
| #881 | alexdont | Update the etcher pin to 0.18.0 and fresco's to 0.13.1 |
| #884 | timujinne | Build the external tools list in a function so 2.41.2+ compiles on OTP 28 |
| #885 | timujinne | Add a shared HTML layout for emails built from files and defaults |

**Verdict:** no defect found in any of the three. The only open items are follow-ups
that depend on a `phoenix_kit_templates` release (below).

## #881 — comment-only

The diff is a 13-line comment in `mix.exs`. The pins it describes were already moved
(`etcher ~> 0.18.0`, released as 2.42.1), and the comment is accurate. It states that
two-finger pan/pinch needs fresco ≥ 0.13.1 while the fresco alternative still admits
0.13.0 — intended, older fresco keeps the single-pointer reading.

## #884 — correct, mechanical

`@tools` → `defp tools/0`; both readers (`external_tools/0`, the cache reset) call it.
Same data. The cost is six `~r` literals built per call; both callers are admin-page
paths, so nothing to optimise. The other `@attr ~r/…/` attributes in `lib/` hold a bare
regex and compile here (Elixir 1.19.5 / OTP 28).

## #885 — `PhoenixKit.Email.Layout`

Read against the real source of truth rather than the description:

- **Substitution is single-pass.** `Templates.Substitution.substitute/3` is one
  `Regex.replace`, so the body inserted through `{{{content}}}` is never re-scanned for
  `{{site_name}}` etc. Raw insertion of the body is safe.
- **`places_content?/3` inspects the file that is sent** — it goes through
  `Templates.missing_variables/4` with the same roots/locale as the render.
- **Parts**: `drop_blank_parts` before `maybe_wrap` means a blank `html.html` never
  produces an empty body; `html: nil, text: nil` stays `nil`, so an unknown name still
  yields `{:error, :template_not_found}`. DB templates are not wrapped.
- **Probed by hand** (scratch script, not committed): nested parentheses and trailing
  punctuation, zero-width space and em dash ending a link, `javascript:` staying text,
  invalid UTF-8, a 3000-byte address left as text, Cyrillic paths, `&` in a query
  escaped, `<script>` escaped, BOM / comment / XML-prolog before `<!doctype`, `<htmlx>`
  not a document. 20 000 repeated `https://a.b/(` and 600 KB of `a. ` each ran in ~4 ms.
- **Tests:** 94 pass in `test/phoenix_kit/{email,system}` and
  `mailer_send_from_template_test.exs`; 6 are skipped (see below). Run again with
  underscore-name support patched into a scratch copy of `phoenix_kit_templates`
  (`PHOENIX_KIT_TEMPLATES_PATH`): **94 pass, 0 skipped**.

### IMPROVEMENT - MEDIUM — the host `_layout` override cannot work on any published release

Finding a `_layout` override needs `phoenix_kit_templates` 0.2.1, which is **not on Hex**
(latest is 0.2.0) and is not in the local `/workspace/phoenix_kit_templates` checkout
either (its `@name_pattern` still rejects a leading `_`). Until then:

- the override documented in the moduledoc, `guides/email-templates.md` and the
  CHANGELOG is silently ignored and core's default layout is used (documented fallback,
  not a crash);
- the six host-`_layout` tests are skipped via `Test.UnderscoreTemplateNames`.

Not changed: nothing in core can fix it. **To do when 0.2.1 ships:** raise the pin
`local_dep(:phoenix_kit_templates, "~> 0.2.0")` → `"~> 0.2.1"`, delete
`test/support/underscore_template_names.ex` and the `skip:` tags that use it.

### NITPICK — `<html/>` is not recognised as a document

`document?/1` matches `<html` followed by whitespace or `>`. A self-closed `<html/>`
(not valid HTML anyway) would be wrapped. Left alone.
