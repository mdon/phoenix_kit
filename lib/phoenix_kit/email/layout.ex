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
  read. Finding a file under a name that starts with `_` needs
  `phoenix_kit_templates` 0.2.1 or later; older releases skip such names and
  core's default is used.

  ## Variables

  | placeholder | value |
  |---|---|
  | `{{{content}}}` | the message body, **already HTML** |
  | `{{subject}}` | the message subject, for `<title>` |
  | `{{site_name}}` | `PhoenixKit.Settings.get_project_title/0` |
  | `{{site_url}}` | `PhoenixKit.Utils.Routes.base_url/0` |

  `content` must be written with **three** braces. The `html` part escapes
  every `{{variable}}`, which is right for `subject` and the site's name but
  would print the body's markup as visible text. Triple braces are the
  escaping opt-out, and the body is safe to insert raw because it was escaped
  when it was built — by the `html` part's own substitution, or by
  `text_to_html/1`.

  ## Opting out

  `layout: false` to `Content.resolve/5` or `Mailer.send_from_template/4`
  leaves the message exactly as resolved. An `html` part that is already a
  whole document (it starts with `<!doctype` or `<html>`) is never wrapped
  either — an export of an old database template is one.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Templates
  alias PhoenixKit.Utils.Routes

  @name "_layout"

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  @doc "The reserved template name the layout resolves under."
  @spec name() :: String.t()
  def name, do: @name

  @doc """
  Core's layout: a header with the site's name, the body, and a footer with the
  name and a link to the site.
  """
  @spec default_html() :: String.t()
  def default_html do
    """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{subject}}</title>
    </head>
    <body style="margin:0;padding:0;background-color:#f4f4f5;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f4f5;">
    <tr>
    <td align="center" style="padding:24px 12px;">
    <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background-color:#ffffff;border:1px solid #e4e4e7;">
    <tr>
    <td style="padding:20px 32px;border-bottom:1px solid #e4e4e7;font-family:#{@font};font-size:18px;font-weight:bold;color:#18181b;">{{site_name}}</td>
    </tr>
    <tr>
    <td style="padding:24px 32px;font-family:#{@font};font-size:15px;line-height:1.6;color:#27272a;">
    {{{content}}}
    </td>
    </tr>
    <tr>
    <td style="padding:16px 32px;border-top:1px solid #e4e4e7;font-family:#{@font};font-size:12px;line-height:1.5;color:#71717a;">{{site_name}}<br><a href="{{site_url}}" style="color:#71717a;">{{site_url}}</a></td>
    </tr>
    </table>
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
  address becomes a link — trailing sentence punctuation stays outside it — and
  no other scheme does, so `javascript:` and friends remain text.
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
    variables = %{
      "content" => content,
      "subject" => subject || "",
      "site_name" => Settings.get_project_title(),
      "site_url" => Routes.base_url()
    }

    rendered =
      Templates.render(@name, %{html: default_html()}, variables,
        locale: Keyword.get(opts, :locale),
        paths: Keyword.get(opts, :paths) || []
      )

    rendered.html
  end

  @doc """
  Whether `html` is a whole document rather than a fragment to wrap.
  """
  @spec document?(String.t()) :: boolean()
  def document?(html) when is_binary(html) do
    Regex.match?(~r/\A\s*<(!doctype|html[\s>])/i, html)
  end

  # Escapes a line, turning each http(s) address in it into a link. Splitting
  # with the matches kept alternates text and address, so odd positions are
  # always addresses.
  defp linkify(line) do
    ~r{https?://[^\s<>"]+}i
    |> Regex.split(line, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join(fn
      {text, index} when rem(index, 2) == 0 -> escape(text)
      {url, _index} -> link(url)
    end)
  end

  defp link(url) do
    {href, trailing} = split_trailing(url)

    if Regex.match?(~r{\Ahttps?://.}i, href) do
      ~s(<a href="#{escape(href)}">#{escape(href)}</a>) <> escape(trailing)
    else
      escape(url)
    end
  end

  # "Visit https://example.com." links the address, not the full stop. A
  # closing parenthesis stays when the address opened one itself, as in a
  # Wikipedia URL.
  defp split_trailing(url) do
    [href, trailing] = Regex.run(~r/\A(.*?)([.,;:!?'"]*)\z/s, url, capture: :all_but_first)

    if String.ends_with?(href, ")") and count(href, "(") < count(href, ")") do
      {inner, more} = split_trailing(String.slice(href, 0..-2//1))
      {inner, more <> ")" <> trailing}
    else
      {href, trailing}
    end
  end

  defp count(string, char), do: length(String.split(string, char)) - 1

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
