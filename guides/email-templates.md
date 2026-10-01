# Customizing emails with template files

PhoenixKit's emails — account confirmation, password reset, magic link, the
new-login alert, and anything a module sends through
`PhoenixKit.Mailer.send_from_template/4` — ship with translated default copy.
A host changes that copy, or the HTML every email is wrapped in, by adding
**override files** to its own application. No database rows, no admin screen:
the files deploy with the code.

## Where the files go

By default PhoenixKit looks in the host application's
`priv/phoenix_kit_templates/`. To search other directories instead, list them
(most specific first):

```elixir
# config/config.exs
config :phoenix_kit, template_paths: [Path.expand("../priv/email_overrides", __DIR__)]
```

An empty list means "no overrides": every email uses PhoenixKit's defaults.

## One directory per email

The email's **name is a directory**; the files inside are named for the part
they supply, optionally with a locale:

```
priv/phoenix_kit_templates/
└── magic_link/
    ├── subject.txt        <- every language
    ├── subject.de.txt     <- German readers
    ├── text.txt
    └── html.html          <- optional
```

| part | file | |
|---|---|---|
| `subject` | `subject[.locale].txt` | subject line |
| `text` | `text[.locale].txt` | plain-text body |
| `html` | `html[.locale].html` | HTML body, optional |

Each part resolves on its own: for a reader in `de-AT`, `text.de-AT.txt`, then
`text.de.txt`, then `text.txt`, then PhoenixKit's translated default. A host
that overrides only `text.txt` keeps the translated subject in every language.

Placeholders are `{{variable}}`. In `html` a `{{variable}}` is HTML-escaped;
`{{{variable}}}` (three braces) inserts the value raw and is only for a value
that is already HTML.

Files are read once and cached; changing one takes a restart (a deploy).

## The layout every email is wrapped in

Every email built from a file or a default is sent with an HTML body inside a
shared layout. PhoenixKit's own layout is deliberately plain: the site's name
above the message, the name and a link to the site below it — table markup
with inline styles, no colours of any brand, no images, and no words of its
own, so it needs no translation. Its `<html lang>` is the reader's locale
(`pt_BR` written as `pt-BR`).

- An email with only a `text` part gets its HTML body built from the text:
  every character escaped, a blank line starts a paragraph, a line break
  becomes `<br>`, and `http://`/`https://` addresses become links (no other
  scheme does, and neither does an address longer than 2 KB). The `text`
  body is sent unchanged next to it. An empty or whitespace-only part counts
  as missing, with or without the layout.
- An `html` part that is a fragment (`<p>…</p>`) is placed inside the layout.
- An `html` part that is a whole document — starting with `<!doctype` or
  `<html`, after any byte-order mark, whitespace, comments or `<?xml ?>`
  prolog — is sent as it is; it already has its own chrome.
- Emails still coming from database templates (the `phoenix_kit_emails`
  package) are never wrapped.

### Replacing the layout

The layout is an override like any other, under the reserved name `_layout`
(names starting with `_` hold shared parts, never an email of their own):

```
priv/phoenix_kit_templates/
└── _layout/
    ├── html.html          <- every language
    └── html.de.html       <- German readers
```

It is resolved for the same reader and from the same directories as the email
it wraps. Only `html` is read. Finding `_layout` needs
`phoenix_kit_templates` 0.2.1 or later.

A layout with no `content` placeholder — an empty file, or a typo such as
`{{{contnet}}}` — would drop the body of every email, the password reset
included. PhoenixKit refuses it: it uses its own layout until the file is
fixed, and logs a warning the first time (once per directory list and
language until the next restart).

Variables available to the layout:

| placeholder | value |
|---|---|
| `{{{content}}}` | the email's HTML body |
| `{{subject}}` | the email's subject, e.g. for `<title>` |
| `{{site_name}}` | the project title (the `project_title` setting, else `config :phoenix_kit, project_title:`) |
| `{{site_url}}` | the site URL used in email links (the `site_url` setting, else the endpoint's URL) — as configured; PhoenixKit's own layout links it only when it is `http(s)://` |

Write the body as `{{{content}}}` — **three braces**. It is already HTML,
escaped when it was built; with two braces it would be escaped a second time
and the reader would see the tags as text. Use two braces for everything
else, so a subject or a site name containing `<` or `&` cannot break the
markup.

A minimal layout:

```html
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>{{subject}}</title></head>
<body style="margin:0;padding:24px;font-family:Arial,sans-serif;">
  <p style="font-weight:bold;">{{site_name}}</p>
  {{{content}}}
  <p style="font-size:12px;color:#666;"><a href="{{site_url}}">{{site_url}}</a></p>
</body>
</html>
```

Email clients ignore most of what a browser supports: keep styles inline, lay
out with tables, and do not rely on external stylesheets or web fonts.

### Sending one email without the layout

```elixir
PhoenixKit.Mailer.send_from_template("export_ready", email, vars,
  defaults: fn -> %{subject: gettext("Your export"), text: gettext("…")} end,
  layout: false
)
```

With `layout: false` a text-only email is sent as plain text, and an `html`
part is sent exactly as written.
