defmodule PhoenixKit.Email.Layout do
  @moduledoc """
  The shared HTML layout every email built from a file or a default is wrapped in.

  `PhoenixKit.Email.Content.resolve/5` calls `wrap/3` on the file/default path,
  so an email reaches the reader as HTML even when all it has is text: core's
  auth emails and the defaults a module passes to
  `PhoenixKit.Mailer.send_from_template/4` ship no `html` part of their own.
  Content from a database template is never wrapped — it carries its own
  chrome.

  ## The default is a function, like every other default

  `default_html/0` is core's layout, kept in code for the same reason the
  message defaults are Gettext calls rather than files: core ships no files of
  its own. It is deliberately neutral — the site's name above the body, the
  name and a link to the site below it, table markup with inline styles, no
  brand colours and no external resources. It carries **no words of its own**,
  so it needs no translation: everything it prints is the site's name, its URL
  and the message itself.

  ## Overriding it

  The layout is resolved like any other template, under the reserved name
  `_layout`, so a host replaces it with an ordinary override file:

      <host>/priv/phoenix_kit_templates/
      └── _layout/
          ├── html.html          <- every locale
          └── html.de.html       <- German readers

  Locale selection, roots and caching are exactly those of the message itself
  (`PhoenixKit.Templates`). The layout's `subject` and `text` parts are never
  read. A layout with no `content` placeholder (an empty file, a typo such as
  `{{{contnet}}}`) would drop the body of every email, so it is refused: a
  warning is logged and core's default is used instead. Finding a file under a name that starts with `_` needs
  `phoenix_kit_templates` 0.2.1 or later; older releases skip such names and
  core's default is used.

  ## Variables

  | placeholder | value |
  |---|---|
  | `{{{content}}}` | the message body, **already HTML** |
  | `{{subject}}` | the message subject, for `<title>` |
  | `{{site_name}}` | `PhoenixKit.Settings.get_project_title/0` |
  | `{{site_url}}` | `PhoenixKit.Utils.Routes.base_url/0` |

  `site_url` is whatever the site is configured with. Core's default links it
  only when it is an `http(s)://` address and prints it as text otherwise.

  `content` must be written with **three** braces. The `html` part escapes
  every `{{variable}}`, which is right for `subject` and the site's name but
  would print the body's markup as visible text. Triple braces are the
  escaping opt-out, and the body is safe to insert raw because it was escaped
  when it was built — by the `html` part's own substitution, or by
  `text_to_html/1`.

  ## Opting out

  `layout: false` to `Content.resolve/5` or `Mailer.send_from_template/4`
  leaves the message exactly as resolved. An `html` part that is already a
  whole document is never wrapped either — an export of an old database
  template is one. It is a document when, after any byte-order mark,
  whitespace, `<!-- comments -->` and `<?xml … ?>` prolog, it starts with
  `<!doctype` or an `<html` tag (`<html>`, `<html lang="…">`), in any case.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Templates
  alias PhoenixKit.Utils.Routes

  require Logger

  @name "_layout"

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  # Longer than any address a reader would click; left as text, which also
  # bounds the work a pathological value can cause.
  @max_link_bytes 2048

  # Sentence punctuation that ends a sentence rather than an address.
  @trailing ~c".,;:!?'\""

  @doc "The reserved template name the layout resolves under."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  Core's layout: a header with the site's name, the body, and a footer with the
  name and a link to the site.

  ## Options

    * `:locale` — becomes the document's `lang` attribute when it is a
      well-formed language tag; omitted otherwise.
    * `:link` — `false` prints `{{site_url}}` in the footer as text instead of
      a link. Default `true`.
  """
  @spec default_html(keyword()) :: String.t()
  def default_html(opts \\ []) do
    lang = lang_attribute(Keyword.get(opts, :locale))

    site =
      if Keyword.get(opts, :link, true),
        do: ~s(<a href="{{site_url}}" style="color:#71717a;">{{site_url}}</a>),
        else: "{{site_url}}"

    """
    <!DOCTYPE html>
    <html#{lang}>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{subject}}</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f5;" bgcolor="#f4f4f5">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#f4f4f5" style="background-color:#f4f4f5;">
    <tr>
    <td align="center" bgcolor="#f4f4f5" style="padding:24px 12px;background-color:#f4f4f5;">
    <!--[if mso]><table role="presentation" width="600" align="center" cellpadding="0" cellspacing="0" border="0"><tr><td><![endif]-->
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" bgcolor="#ffffff" style="width:100%;max-width:600px;background-color:#ffffff;border:1px solid #e4e4e7;">
    <tr>
    <td style="padding:20px 32px;border-bottom:1px solid #e4e4e7;font-family:#{@font};font-size:18px;font-weight:bold;color:#18181b;">{{site_name}}</td>
    </tr>
    <tr>
    <td style="padding:24px 32px;font-family:#{@font};font-size:15px;line-height:1.6;color:#27272a;">
    {{{content}}}
    </td>
    </tr>
    <tr>
    <td style="padding:16px 32px;border-top:1px solid #e4e4e7;font-family:#{@font};font-size:12px;line-height:1.5;color:#71717a;">{{site_name}}<br>#{site}</td>
    </tr>
    </table>
    <!--[if mso]></td></tr></table><![endif]-->
    </td>
    </tr>
    </table>
    </body>
    </html>
    """
  end

  @doc """
  Plain text as an HTML fragment.

  Every character of `text` is escaped. A blank line separates paragraphs,
  each a `<p>`; a single line break becomes `<br>`. An `http://` or `https://`
  address becomes a link — it ends at any whitespace (Unicode included) or
  CJK/fullwidth punctuation, and trailing sentence punctuation and unbalanced
  closing parentheses stay outside it. No other scheme becomes a link, so
  `javascript:` and friends remain text, and neither does an address longer
  than #{@max_link_bytes} bytes.
  """
  @spec text_to_html(String.t()) :: String.t()
  def text_to_html(text) when is_binary(text) do
    text
    |> String.replace(["\r\n", "\r"], "\n")
    |> String.split(~r/\n[ \t]*\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map_join("\n", fn paragraph ->
      lines = paragraph |> String.split("\n") |> Enum.map_join("<br>\n", &linkify/1)
      ~s(<p style="margin:0 0 16px;">) <> lines <> "</p>"
    end)
  end

  @doc """
  Wraps an HTML fragment in the layout for this message's locale.

  `subject` may be `nil`. Options are the message's own `:locale` and `:paths`,
  so the layout resolves from the same override roots and for the same reader
  as the message it wraps.
  """
  @spec wrap(String.t(), String.t() | nil, keyword()) :: String.t()
  def wrap(content, subject, opts \\ []) when is_binary(content) do
    locale = Keyword.get(opts, :locale)
    paths = Keyword.get(opts, :paths) || []
    site_url = Routes.base_url()

    defaults = %{html: default_html(locale: locale, link: http_url?(site_url))}

    variables = %{
      "content" => content,
      "subject" => subject || "",
      "site_name" => Settings.get_project_title(),
      "site_url" => site_url
    }

    render_opts = [locale: locale, paths: paths]

    if places_content?(defaults, variables, render_opts) do
      Templates.render(@name, defaults, variables, render_opts).html
    else
      Logger.warning(
        "Email layout #{@name}/html for locale #{inspect(locale)} in #{inspect(paths)} " <>
          "has no {{{content}}} placeholder; using PhoenixKit's default layout instead"
      )

      Templates.render(@name, defaults, variables, locale: locale, paths: []).html
    end
  end

  @doc """
  Whether `html` is a whole document rather than a fragment to wrap.

  Leading byte-order marks, whitespace (non-breaking included), comments and
  an XML prolog are skipped before looking for `<!doctype` or `<html`.
  """
  @spec document?(String.t()) :: boolean()
  def document?(html) when is_binary(html) do
    Regex.match?(~r/\A<(!doctype|html[\s>])/i, skip_preamble(html))
  end

  # The resolved layout places the body when leaving `content` unbound would
  # leave its placeholder unbound — the same resolution the render uses, so the
  # check can never inspect a different file from the one sent.
  defp places_content?(defaults, variables, opts) do
    missing =
      Templates.missing_variables(@name, defaults, Map.delete(variables, "content"), opts)

    "content" in Map.get(missing, :html, [])
  end

  defp skip_preamble(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: skip_preamble(rest)
  defp skip_preamble("<!--" <> rest), do: rest |> after_marker("-->") |> skip_preamble()
  defp skip_preamble("<?" <> rest), do: rest |> after_marker("?>") |> skip_preamble()

  defp skip_preamble(html) do
    case String.trim_leading(html) do
      ^html -> html
      trimmed -> skip_preamble(trimmed)
    end
  end

  defp after_marker(rest, marker) do
    case :binary.split(rest, marker) do
      [_skipped, after_it] -> after_it
      [_unterminated] -> ""
    end
  end

  defp lang_attribute(locale) when is_binary(locale) do
    if Regex.match?(~r/\A[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8}){0,3}\z/, locale),
      do: ~s( lang="#{escape(locale)}"),
      else: ""
  end

  defp lang_attribute(_locale), do: ""

  defp http_url?(url), do: Regex.match?(~r{\Ahttps?://[^\s]}i, url)

  # Escapes a line, turning each http(s) address in it into a link. Splitting
  # with the matches kept alternates text and address, so odd positions are
  # always addresses. A line that is not valid UTF-8 cannot be scanned as
  # Unicode and is escaped whole.
  defp linkify(line) do
    if String.valid?(line) do
      ~r|https?://[^\s\p{Z}<>"\N{U+3000}-\N{U+303F}\N{U+FF01}-\N{U+FF65}]+|iu
      |> Regex.split(line, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_join(fn
        {text, index} when rem(index, 2) == 0 -> escape(text)
        {url, _index} -> link(url)
      end)
    else
      escape(line)
    end
  end

  defp link(url) do
    {href, trailing} = split_trailing(url)

    if byte_size(href) <= @max_link_bytes and http_url?(href) do
      ~s(<a href="#{escape(href)}">#{escape(href)}</a>) <> escape(trailing)
    else
      escape(url)
    end
  end

  # "Visit https://example.com." links the address, not the full stop. A
  # closing parenthesis stays when the address opened one itself, as in a
  # Wikipedia URL. One pass from the end over bytes — the characters it strips
  # are all ASCII, which never occurs inside a multi-byte UTF-8 sequence — with
  # the parentheses counted once, so its cost is linear in the address.
  defp split_trailing(url) do
    opens = count(url, "(")
    closes = count(url, ")")
    keep = keep_bytes(url, byte_size(url), opens, closes)

    {binary_part(url, 0, keep), binary_part(url, keep, byte_size(url) - keep)}
  end

  defp keep_bytes(_url, 0, _opens, _closes), do: 0

  defp keep_bytes(url, size, opens, closes) do
    case :binary.at(url, size - 1) do
      char when char in @trailing -> keep_bytes(url, size - 1, opens, closes)
      ?) when closes > opens -> keep_bytes(url, size - 1, opens, closes - 1)
      _other -> size
    end
  end

  defp count(string, pattern), do: length(:binary.matches(string, pattern))

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
