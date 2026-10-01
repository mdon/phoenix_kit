defmodule PhoenixKit.Email.Markdown do
  @moduledoc """
  An email body written in Markdown, as HTML and as plain text.

  `PhoenixKit.Email.Content.resolve/5` uses this for a `markdown` part
  (`markdown[.<locale>].md`): the HTML body comes from it when the message has
  no `html` part, and the text body when it has no `text` part.

  ## Placeholders

  `{{variable}}` and `{{{variable}}}` work as in an `html` part: two braces
  escape the value, three insert it raw. They are substituted **after** the
  Markdown is rendered — a renderer percent-encodes `{{url}}` in a link
  target, so a value substituted before it would arrive as `%7B%7Burl%7D%7D`,
  and a value rendered as Markdown could change the markup around it. Each
  placeholder is swapped for an opaque token, the Markdown is rendered and
  sanitized (`PhoenixKit.Utils.HtmlSanitizer`), the placeholders are put back
  and substituted with `PhoenixKit.Templates.Substitution`.

  ## Links and buttons

  Every link and image is built here rather than by the renderer, so its
  address is known after substitution:

    * The address is the link target with its placeholders filled in, raw or
      not — inside an attribute both spellings are escaped as an attribute
      value.
    * Only an `http://`, `https://` or `mailto:` address (images: `http(s)`
      only) is kept. Anything else — `javascript:`, a relative path, a
      placeholder nothing bound — drops the link and keeps its label as text.
    * A paragraph that is exactly one `[label](url)` link becomes a button: a
      table cell in the accent colour, which renders the same in every email
      client. A bare address on its own line stays a link.
    * Other links are coloured with the accent colour.

  The accent colour is the `accent_color` variable, checked by
  `PhoenixKit.Email.Branding.normalize_color/1`.

  ## Raw HTML

  HTML written inside the Markdown is not rendered: a placeholder inside an
  attribute of it could not be checked like a link target. A body that needs
  markup of its own belongs in an `html` part.
  """

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Templates.Substitution
  alias PhoenixKit.Utils.HtmlSanitizer

  @mdex_options [
    extension: [strikethrough: true, table: true, autolink: true],
    parse: [smart: true],
    render: [unsafe: false]
  ]

  # The placeholder grammar of `PhoenixKit.Templates.Substitution`: triple and
  # double braces, one pass. Linear — no nested quantifiers.
  @placeholder ~r/\{\{\{\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\}\}\}|\{\{\s*[a-zA-Z_][a-zA-Z0-9_]*\s*\}\}/

  @font "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

  @paragraph ~s(<p style="margin:0 0 16px;">)

  @doc """
  `markdown` as a sanitized HTML fragment with `variables` substituted.
  """
  @spec to_html(String.t(), Substitution.variables()) :: String.t()
  def to_html(markdown, variables) when is_binary(markdown) do
    if String.valid?(markdown),
      do: render_html(markdown, variables),
      else: fallback_html(markdown, variables)
  end

  defp render_html(markdown, variables) do
    accent = variables |> fetch("accent_color") |> Branding.normalize_color()
    {protected, placeholders, nonce} = protect(markdown)

    case MDEx.parse_document(protected, @mdex_options) do
      {:ok, document} ->
        {document, elements} = extract(document, %{nonce: nonce, elements: [], count: 0})

        html =
          document
          |> MDEx.to_html!(@mdex_options)
          |> HtmlSanitizer.sanitize()

        {html, attributes} =
          elements.elements
          |> Enum.reverse()
          |> Enum.reduce({html, %{}}, &place(&1, &2, placeholders, variables, accent))

        html
        |> String.replace("<p>", @paragraph)
        |> restore(placeholders)
        |> Substitution.substitute(variables, escape: true)
        |> restore(attributes)

      {:error, _reason} ->
        fallback_html(markdown, variables)
    end
  end

  # Content MDEx cannot take (it raises on invalid UTF-8) is sent as escaped
  # text rather than failing the send.
  defp fallback_html(markdown, variables),
    do: markdown |> Substitution.substitute(variables) |> Layout.text_to_html()

  @doc """
  `markdown` as plain text with `variables` substituted.

  Headings and paragraphs are lines separated by a blank line, list items
  start with `- ` (`1. ` when numbered), `[label](url)` becomes
  `label: url`, an image becomes its alt text, and emphasis, code and raw
  HTML marks are dropped.
  """
  @spec to_text(String.t(), Substitution.variables()) :: String.t()
  def to_text(markdown, variables) when is_binary(markdown) do
    if String.valid?(markdown),
      do: render_text(markdown, variables),
      else: markdown |> String.trim() |> Substitution.substitute(variables)
  end

  defp render_text(markdown, variables) do
    {protected, placeholders, nonce} = protect(markdown)

    case MDEx.parse_document(protected, @mdex_options) do
      {:ok, document} ->
        {document, {urls, _count}} =
          text_urls(document, {%{}, 0}, nonce, placeholders, variables)

        document.nodes
        |> blocks_text()
        |> String.trim()
        |> restore(placeholders)
        |> Substitution.substitute(variables)
        |> restore(urls)

      {:error, _reason} ->
        markdown |> String.trim() |> Substitution.substitute(variables)
    end
  end

  ## Placeholders

  # Each placeholder becomes `0pk<nonce>x<i>x`: letters and digits only, so no
  # Markdown construct, no percent-encoding and no sanitizer touches it, and
  # the renderer sees an ordinary word — in an email address it is part of the
  # address, so `{{user}}@example.com` is linked like any other. The leading
  # digit keeps `<{{url}}>` from reading as an HTML tag (a tag name starts with
  # a letter), which would drop it. The nonce is random and absent from the
  # source, so a token can only be one this render minted; the closing `x`
  # keeps token 1 from matching inside token 12, and hex digits never contain
  # an `x`, `y` or `z`.
  defp protect(markdown) do
    nonce = nonce(markdown)

    {pieces, placeholders} =
      @placeholder
      |> Regex.split(markdown, include_captures: true)
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn
        {text, index}, acc when rem(index, 2) == 0 ->
          {text, acc}

        {placeholder, index}, acc ->
          token = "0pk#{nonce}x#{index}x"
          {token, Map.put(acc, token, placeholder)}
      end)

    {IO.iodata_to_binary(pieces), placeholders, nonce}
  end

  defp nonce(source) do
    nonce = 6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if String.contains?(source, "pk" <> nonce), do: nonce(source), else: nonce
  end

  # Replaces every key of `tokens` in `string` with its value, in one pass.
  defp restore(string, tokens) when map_size(tokens) == 0, do: string

  defp restore(string, tokens) do
    String.replace(string, Map.keys(tokens), &Map.fetch!(tokens, &1))
  end

  ## Links, buttons and images

  # Links and images leave the document as marker tokens — `pk<nonce>y<i>o`
  # before the label and `pk<nonce>y<i>c` after it, or one `pk<nonce>y<i>i`
  # for an image — and are built after sanitizing, once their address is
  # known. The label stays in the document, so it is rendered and sanitized
  # with everything else.
  defp extract(%MDEx.Paragraph{nodes: [%MDEx.Link{} = link]} = paragraph, acc) do
    if autolink?(link) do
      extract_children(paragraph, acc)
    else
      {label, acc} = extract_list(link.nodes, acc)
      {open, close, acc} = add_element(acc, {:button, link.url})
      {%{paragraph | nodes: [text(open)] ++ label ++ [text(close)]}, acc}
    end
  end

  defp extract(%MDEx.Link{} = link, acc) do
    {label, acc} = extract_list(link.nodes, acc)
    {open, close, acc} = add_element(acc, {:link, link.url})
    {[text(open)] ++ label ++ [text(close)], acc}
  end

  defp extract(%MDEx.Image{} = image, acc) do
    {marker, _close, acc} = add_element(acc, {:image, image.url, inline_text(image.nodes)})
    {text(marker), acc}
  end

  defp extract(%{nodes: nodes} = node, acc) when is_list(nodes), do: extract_children(node, acc)
  defp extract(node, acc), do: {node, acc}

  defp extract_children(node, acc) do
    {nodes, acc} = extract_list(node.nodes, acc)
    {%{node | nodes: nodes}, acc}
  end

  defp extract_list(nodes, acc) do
    {nodes, acc} = Enum.map_reduce(nodes, acc, &extract/2)
    {List.flatten(nodes), acc}
  end

  defp add_element(acc, element) do
    prefix = "pk#{acc.nonce}y#{acc.count}"
    marker = if elem(element, 0) == :image, do: prefix <> "i", else: prefix <> "o"

    {marker, prefix <> "c",
     %{acc | elements: [{prefix, element} | acc.elements], count: acc.count + 1}}
  end

  defp text(literal), do: %MDEx.Text{literal: literal}

  # `<https://a.test>` or a bare address the autolink extension found
  # (`www.a.test` gains `http://`, `a@b.test` gains `mailto:`): the label is
  # the address itself. A line holding only an address reads as a
  # link, not as a button labelled with a URL.
  defp autolink?(%MDEx.Link{url: url, nodes: [%MDEx.Text{literal: literal}]}),
    do: url in [literal, "mailto:" <> literal, "http://" <> literal]

  defp autolink?(_link), do: false

  # Attribute values — the address, an image's alt text — are filled in and
  # escaped here, on their own, and travel as tokens (`…z` for the address,
  # `…a` for the alt) until the body's placeholders are filled: in an
  # attribute `{{{x}}}` is escaped like `{{x}}`, and a value is substituted
  # once.
  defp place({prefix, element}, {html, attributes}, placeholders, variables, accent) do
    url = element |> elem(1) |> fill(placeholders, variables)
    safe? = safe_url?(url, elem(element, 0))

    attributes =
      if safe?,
        do: Map.put(attributes, prefix <> "z", escape(String.trim(url))),
        else: attributes

    attributes =
      case element do
        {:image, _url, alt} ->
          Map.put(attributes, prefix <> "a", alt |> fill(placeholders, variables) |> escape())

        _link ->
          attributes
      end

    {build(element, html, prefix, safe?, accent), attributes}
  end

  defp fill(text, placeholders, variables),
    do: text |> restore(placeholders) |> Substitution.substitute(variables)

  defp build({:button, _url}, html, prefix, safe?, accent) do
    splice(html, prefix, fn before, label, rest ->
      # The button replaces the paragraph that held the link.
      before = String.replace_suffix(before, "<p>", "")
      rest = String.replace_prefix(rest, "</p>", "")

      markup =
        if safe?,
          do: button(prefix <> "z", label, accent),
          else: "<p>" <> label <> "</p>"

      before <> markup <> rest
    end)
  end

  defp build({:link, _url}, html, prefix, safe?, accent) do
    splice(html, prefix, fn before, label, rest ->
      markup =
        if safe?,
          do: ~s(<a href="#{prefix}z" style="color:#{accent};">#{label}</a>),
          else: label

      before <> markup <> rest
    end)
  end

  defp build({:image, _url, _alt}, html, prefix, safe?, _accent) do
    markup =
      if safe?,
        do:
          ~s(<img src="#{prefix}z" alt="#{prefix}a" ) <>
            ~s(style="max-width:100%;height:auto;border:0;">),
        else: prefix <> "a"

    String.replace(html, prefix <> "i", markup)
  end

  # Hands `fun` the HTML before the element's opening marker, the label
  # between its markers, and the rest. The sanitizer keeps text as text, so
  # both markers are always there; the HTML is left alone if one is not.
  defp splice(html, prefix, fun) do
    with [before, after_open] <- :binary.split(html, prefix <> "o"),
         [label, rest] <- :binary.split(after_open, prefix <> "c") do
      fun.(before, label, rest)
    else
      _missing -> html
    end
  end

  # A bulletproof button: the colour is on the table cell, so clients that
  # ignore padding on `<a>` (Outlook) still show a coloured block.
  defp button(href, label, accent) do
    text_color = Branding.text_color_on(accent)

    ~s(<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 16px;">) <>
      ~s(<tr><td align="center" bgcolor="#{accent}" style="border-radius:6px;background-color:#{accent};">) <>
      ~s(<a href="#{href}" style="display:inline-block;padding:12px 24px;border-radius:6px;) <>
      ~s(font-family:#{@font};font-size:15px;font-weight:bold;line-height:1.2;) <>
      ~s(color:#{text_color};text-decoration:none;">#{label}</a>) <>
      "</td></tr></table>"
  end

  defp safe_url?(url, :image), do: Regex.match?(~r/\Ahttps?:\/\/[^\s]/i, String.trim(url))

  defp safe_url?(url, _link),
    do: Regex.match?(~r/\A(?:https?:\/\/[^\s]|mailto:[^\s])/i, String.trim(url))

  ## Plain text

  # The text body gets the same address rules as the HTML one: a link target
  # is substituted and checked on its own, and travels as a token until the
  # body's own placeholders are filled, so a value is never substituted twice.
  # An unsafe target leaves only the label (`url: ""`).
  defp text_urls(%MDEx.Link{} = link, acc, nonce, placeholders, variables) do
    {nodes, acc} = text_urls_list(link.nodes, acc, nonce, placeholders, variables)
    link = %{link | nodes: nodes}

    if autolink?(link) do
      {link, acc}
    else
      {urls, count} = acc
      url = link.url |> restore(placeholders) |> Substitution.substitute(variables)

      if safe_url?(url, :link) do
        token = "pk#{nonce}z#{count}z"
        {%{link | url: token}, {Map.put(urls, token, String.trim(url)), count + 1}}
      else
        {%{link | url: ""}, acc}
      end
    end
  end

  defp text_urls(%{nodes: nodes} = node, acc, nonce, placeholders, variables)
       when is_list(nodes) do
    {nodes, acc} = text_urls_list(nodes, acc, nonce, placeholders, variables)
    {%{node | nodes: nodes}, acc}
  end

  defp text_urls(node, acc, _nonce, _placeholders, _variables), do: {node, acc}

  defp text_urls_list(nodes, acc, nonce, placeholders, variables) do
    Enum.map_reduce(nodes, acc, &text_urls(&1, &2, nonce, placeholders, variables))
  end

  defp blocks_text(nodes, separator \\ "\n\n") do
    nodes
    |> Enum.map(&block_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(separator)
  end

  defp block_text(%MDEx.Heading{nodes: nodes}), do: inline_text(nodes)
  defp block_text(%MDEx.Paragraph{nodes: nodes}), do: inline_text(nodes)
  defp block_text(%MDEx.ThematicBreak{}), do: "---"
  defp block_text(%MDEx.CodeBlock{literal: literal}), do: String.trim_trailing(literal)
  defp block_text(%MDEx.HtmlBlock{}), do: ""

  defp block_text(%MDEx.BlockQuote{nodes: nodes}) do
    nodes |> blocks_text() |> prefix_lines("> ", "> ")
  end

  defp block_text(%MDEx.List{nodes: items} = list) do
    items
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {item, index} ->
      marker = if list.list_type == :ordered, do: "#{list.start + index}. ", else: "- "

      item.nodes
      |> blocks_text("\n")
      |> prefix_lines(marker, String.duplicate(" ", String.length(marker)))
    end)
  end

  defp block_text(%MDEx.Table{nodes: rows}) do
    Enum.map_join(rows, "\n", fn row ->
      Enum.map_join(row.nodes, " | ", &inline_text(&1.nodes))
    end)
  end

  defp block_text(%{nodes: nodes}) when is_list(nodes), do: blocks_text(nodes)
  defp block_text(_node), do: ""

  defp prefix_lines(text, first, rest) do
    [head | tail] = String.split(text, "\n")

    Enum.join(
      [
        first <> head
        | Enum.map(tail, &if(&1 == "", do: String.trim_trailing(rest), else: rest <> &1))
      ],
      "\n"
    )
  end

  defp inline_text(nodes), do: Enum.map_join(nodes, &inline/1)

  defp inline(%MDEx.Text{literal: literal}), do: literal
  defp inline(%MDEx.Code{literal: literal}), do: literal
  defp inline(%MDEx.SoftBreak{}), do: "\n"
  defp inline(%MDEx.LineBreak{}), do: "\n"
  defp inline(%MDEx.HtmlInline{}), do: ""
  defp inline(%MDEx.Image{nodes: nodes}), do: inline_text(nodes)

  defp inline(%MDEx.Link{url: url, nodes: nodes} = link) do
    label = inline_text(nodes)

    cond do
      autolink?(link) or url == "" -> label
      label == "" -> url
      true -> label <> ": " <> url
    end
  end

  defp inline(%{nodes: nodes}) when is_list(nodes), do: inline_text(nodes)
  defp inline(_node), do: ""

  defp fetch(variables, key) when is_map(variables) do
    Enum.find_value(variables, fn {k, v} -> if to_string(k) == key, do: v end)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
