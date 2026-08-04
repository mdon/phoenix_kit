defmodule PhoenixKit.Utils.HtmlSanitizer do
  @moduledoc """
  HTML sanitization for user-supplied rich text.

  Backed by `MDEx.safe_html/2` — an ammonia-based **parsed allowlist**. It
  builds a real DOM, keeps only known-good tags and attributes, validates
  URL schemes per attribute, and re-serializes. It does not pattern-match
  on markup, which is why it holds up where the previous regex
  implementation did not (see `sanitize_html/1`).

  ## What survives

  Ordinary rich text: block elements (p, div, hr, h1-h6, blockquote, pre,
  code), inline elements (span, strong, em, u, s, a, sub, sup), lists,
  tables, and img. Relative, absolute, anchor, `mailto:` and `tel:` URLs
  are preserved.

  ## What is removed

  Script and style elements, event-handler attributes, dangerous URL
  schemes (`javascript:`, `data:`, …) **including entity-encoded
  spellings** such as `jav&#x61;script:`, and embedding elements
  (iframe, object, embed, svg, math).

  ## Output is normalised

  Because the result is re-serialized from a parse tree, it is valid HTML
  rather than a lightly-edited copy of the input: attribute values come
  back quoted, void elements lose a self-closing slash (`<br/>` →
  `<br>`), `<table>` gains an implicit `<tbody>`, and links gain
  `rel="noopener noreferrer"`. Compare rendered meaning, not exact
  strings, when asserting on sanitized output.

  ## Usage

      PhoenixKit.Utils.HtmlSanitizer.sanitize("<p>Hello</p><script>alert('xss')</script>")
      #=> "<p>Hello</p>"

      PhoenixKit.Utils.HtmlSanitizer.sanitize(~s|<a href="javascript:alert(1)">Click</a>|)
      #=> "<a rel=\\"noopener noreferrer\\">Click</a>"
  """

  # The tag/attribute allowlist is ammonia's default set, applied through
  # `MDEx.safe_html/2` — see `sanitize_html/1` at the bottom of this module
  # for why a parser rather than regexes. The list above is descriptive of
  # that default, not a second source of truth; to change what is allowed,
  # pass explicit `:sanitize` options rather than editing a comment.
  #
  # Behaviour worth knowing:
  #   * URL schemes are validated per attribute — `javascript:`, `data:`
  #     and friends are dropped, including entity-encoded spellings
  #     (`jav&#x61;script:`), which the old blacklist could not catch.
  #   * Relative, absolute, anchor, `mailto:` and `tel:` URLs survive.
  #   * Links gain `rel="noopener noreferrer"`.
  #   * Output is normalised HTML (attributes quoted, `<table>` gains an
  #     implicit `<tbody>`), because it is re-serialized from a parse tree.

  @doc """
  Sanitizes HTML content by removing dangerous elements and attributes.

  Returns sanitized HTML string that is safe to render.

  ## Parameters

  - `html` - The HTML string to sanitize

  ## Examples

      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize("<p onclick=\"alert('xss')\">Hello</p>")
      "<p>Hello</p>"
  """
  def sanitize(nil), do: nil
  def sanitize(""), do: ""

  def sanitize(html) when is_binary(html) do
    html
    |> sanitize_html()
    |> String.trim()
  end

  def sanitize(other), do: other

  @doc """
  Sanitizes all rich_text fields in an entity data map.

  Takes entity field definitions and data, returns data with all
  rich_text fields sanitized.

  ## Parameters

  - `fields_definition` - List of field definition maps
  - `data` - Map of field key => value

  ## Examples

      iex> fields = [%{"type" => "rich_text", "key" => "content"}]
      iex> data = %{"content" => "<script>alert('xss')</script><p>Hello</p>"}
      iex> PhoenixKit.Utils.HtmlSanitizer.sanitize_rich_text_fields(fields, data)
      %{"content" => "<p>Hello</p>"}
  """
  def sanitize_rich_text_fields(fields_definition, data)
      when is_list(fields_definition) and is_map(data) do
    rich_text_keys =
      fields_definition
      |> Enum.filter(fn field -> field["type"] == "rich_text" end)
      |> Enum.map(fn field -> field["key"] end)

    Enum.reduce(rich_text_keys, data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        value -> Map.put(acc, key, sanitize(value))
      end
    end)
  end

  def sanitize_rich_text_fields(_fields, data), do: data

  # Private functions

  # Sanitize via MDEx's `safe_html/2`, which is an ammonia-backed PARSED
  # ALLOWLIST: it builds a real DOM, keeps only known-good tags and
  # attributes, validates URL schemes per attribute, and re-serializes.
  #
  # This replaced a hand-rolled regex sanitizer. Regexes cannot sanitize
  # HTML — they have to model a parser they are not, and each attempt
  # leaked. Two bypass classes were found in the previous implementation,
  # the second of which left `<img/src=x/onerror=alert(1)>` completely
  # untouched because the patterns assumed whitespace between attributes
  # while HTML also permits `/`. Product descriptions render through here
  # on unauthenticated storefronts, so a leak here is a leak to every
  # visitor.
  #
  # MDEx is already a runtime dependency (it renders Markdown), so this
  # costs nothing to adopt — no new dep, and the allowlist is maintained
  # upstream by people who do this full time.
  #
  # `escape: [content: false]` because the job is to REMOVE unsafe
  # constructs, not to entity-escape the safe markup that survives —
  # callers render the result as HTML and expect `<p>` to still be a
  # paragraph.
  defp sanitize_html(html) do
    MDEx.safe_html(html,
      sanitize: MDEx.Document.default_sanitize_options(),
      escape: [content: false, curly_braces_in_code: false]
    )
  end
end
