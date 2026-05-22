defmodule PhoenixKit.Modules.Languages.DialectMapper do
  @moduledoc """
  Handles mapping between base language codes (en, es) and full dialect codes (en-US, es-MX).

  This module provides the core logic for PhoenixKit's simplified URL architecture where
  URLs show base codes (/en/) but translations use full dialect codes (en-US).

  ## Architecture

  PhoenixKit uses a two-tier locale system:

  1. **Base Language Codes** - Used in URLs for simplicity
     - Format: 2-letter ISO 639-1 codes (en, es, fr, de, pt, zh, ja, etc.)
     - Examples: `/en/dashboard`, `/es/admin`, `/fr/users`
     - User-facing, SEO-friendly, easy to remember

  2. **Full Dialect Codes** - Used internally for translations
     - Format: BCP 47 language tags (en-US, es-MX, pt-BR, zh-CN)
     - Examples: en-US, en-GB, es-ES, es-MX, pt-PT, pt-BR
     - Translation-aware, respects regional differences

  ## Data Flow

  ```
  User visits: /en/dashboard
        ↓
  Extract base: "en"
        ↓
  Resolve dialect: "en" → "en-US" (default mapping for the base code)
        ↓
  Set Gettext: "en-US"
        ↓
  Generate URLs: Always use base code "en"
  ```

  ## Default Dialect Mapping

  When no user preference exists, base codes map to most common regional variants:
  - `en` → `en-US` (American English)
  - `es` → `es-ES` (European Spanish)
  - `pt` → `pt-BR` (Brazilian Portuguese)
  - `zh` → `zh-CN` (Simplified Chinese)
  - `de` → `de-DE` (German Germany)
  - `fr` → `fr-FR` (French France)

  ## URL-Driven Resolution

  Dialect resolution is purely URL-driven: a base code maps to its
  default dialect and nothing else. A logged-in user's locale preference
  is intentionally not consulted (see `PhoenixKitWeb.Users.Auth` for the
  URL-is-authoritative rationale), so `/en/dashboard` always resolves to
  the default `en-US` regardless of who is signed in.

  ## Examples

      # Extract base language from full dialect
      iex> DialectMapper.extract_base("en-US")
      "en"

      iex> DialectMapper.extract_base("es-MX")
      "es"

      # Convert base to default dialect
      iex> DialectMapper.base_to_dialect("en")
      "en-US"

      iex> DialectMapper.base_to_dialect("pt")
      "pt-BR"

      # Resolve a base code to its default dialect (URL-driven)
      iex> DialectMapper.resolve_dialect("en")
      "en-US"

  ## Validation

      iex> DialectMapper.valid_base_code?("en")
      true

      iex> DialectMapper.valid_base_code?("xx")
      false

  ## Getting Available Dialects

      iex> DialectMapper.dialects_for_base("en")
      ["en-US", "en-GB", "en-CA", "en-AU"]

      iex> DialectMapper.dialects_for_base("es")
      ["es-ES", "es-MX", "es-AR", "es-CO"]
  """

  alias PhoenixKit.Modules.Languages

  # Default dialect mapping for most common variants
  # Based on usage statistics and regional population
  @default_dialects %{
    "en" => "en-US",
    # English
    "es" => "es-ES",
    # Spanish
    "fr" => "fr-FR",
    # French
    "de" => "de-DE",
    # German
    "pt" => "pt-BR",
    # Portuguese (Brazilian Portuguese more common)
    "zh" => "zh-CN",
    # Chinese (Simplified more common)
    # Languages without regional variants map to themselves
    "ar" => "ar",
    # Arabic
    "ja" => "ja",
    # Japanese
    "ko" => "ko",
    # Korean
    "it" => "it",
    # Italian
    "ru" => "ru",
    # Russian
    "hi" => "hi",
    # Hindi
    "bn" => "bn",
    # Bengali
    "pa" => "pa",
    # Punjabi
    "jv" => "jv",
    # Javanese
    "vi" => "vi",
    # Vietnamese
    "tr" => "tr",
    # Turkish
    "pl" => "pl",
    # Polish
    "uk" => "uk",
    # Ukrainian
    "th" => "th",
    # Thai
    "nl" => "nl",
    # Dutch
    "sv" => "sv",
    # Swedish
    "no" => "no",
    # Norwegian
    "da" => "da",
    # Danish
    "fi" => "fi",
    # Finnish
    "cs" => "cs",
    # Czech
    "hu" => "hu",
    # Hungarian
    "ro" => "ro",
    # Romanian
    "el" => "el",
    # Greek
    "he" => "he",
    # Hebrew
    "id" => "id",
    # Indonesian
    "ms" => "ms",
    # Malay
    "fa" => "fa",
    # Persian
    "sw" => "sw",
    # Swahili
    "ta" => "ta",
    # Tamil
    "te" => "te",
    # Telugu
    "mr" => "mr",
    # Marathi
    "ur" => "ur",
    # Urdu
    "gu" => "gu",
    # Gujarati
    "kn" => "kn",
    # Kannada
    "ml" => "ml"
    # Malayalam
  }

  @doc """
  Extracts base language code from full dialect code.

  Splits on hyphen and returns first part (lowercased).
  Handles both dialect codes (en-US) and base codes (en).
  Returns "en" as default fallback for nil and empty string values.

  ## Examples

      iex> DialectMapper.extract_base("en-US")
      "en"

      iex> DialectMapper.extract_base("es-MX")
      "es"

      iex> DialectMapper.extract_base("zh-Hans-CN")
      "zh"

      iex> DialectMapper.extract_base("ja")
      "ja"

      iex> DialectMapper.extract_base("EN-GB")
      "en"

      iex> DialectMapper.extract_base(nil)
      "en"

      iex> DialectMapper.extract_base("")
      "en"
  """
  # Default fallback for nil and empty strings
  def extract_base(nil), do: "en"
  def extract_base(""), do: "en"

  def extract_base(locale) when is_binary(locale) do
    locale
    |> String.split("-")
    |> List.first()
    |> String.downcase()
  end

  @doc """
  Converts base language code to default dialect.

  Uses predefined mapping for most common regional variants.
  Falls back to base code if no mapping exists.

  ## Examples

      iex> DialectMapper.base_to_dialect("en")
      "en-US"

      iex> DialectMapper.base_to_dialect("pt")
      "pt-BR"

      iex> DialectMapper.base_to_dialect("ja")
      "ja"

      iex> DialectMapper.base_to_dialect("xx")
      "xx"
  """
  def base_to_dialect(base_code) when is_binary(base_code) do
    base_lower = String.downcase(base_code)
    Map.get(@default_dialects, base_lower, base_lower)
  end

  @doc """
  Resolves the full dialect code for a base language URL.

  The URL is authoritative: the base code maps straight to its default
  dialect via `base_to_dialect/1`. User locale preferences are
  deliberately NOT consulted here — locale resolution is URL-driven
  across both the LiveView mount and the HTTP plug (see the rationale in
  `PhoenixKitWeb.Users.Auth`). Resolving without a user keeps a logged-in
  user's `custom_fields["preferred_locale"]` from silently upgrading e.g.
  base `"en"` to `"en-GB"`.

  ## Examples

      iex> DialectMapper.resolve_dialect("en")
      "en-US"

      iex> DialectMapper.resolve_dialect("es")
      "es-ES"

      iex> DialectMapper.resolve_dialect("ja")
      "ja"
  """
  def resolve_dialect(base_code) when is_binary(base_code) do
    base_to_dialect(base_code)
  end

  @doc """
  Validates if a base language code is supported.

  Checks if the default dialect for this base code exists in the
  predefined language list.

  ## Examples

      iex> DialectMapper.valid_base_code?("en")
      true

      iex> DialectMapper.valid_base_code?("ja")
      true

      iex> DialectMapper.valid_base_code?("xx")
      false

      iex> DialectMapper.valid_base_code?("en-US")
      false  # Not a base code (contains hyphen)

  ## Notes

  - Only validates base codes (2 letters)
  - Full dialect codes will return false (use extract_base first)
  - Checks against Languages.get_predefined_language/1
  """
  def valid_base_code?(base_code) when is_binary(base_code) do
    # Only validate if it looks like a base code (2 letters, no hyphen)
    if String.length(base_code) == 2 and not String.contains?(base_code, "-") do
      dialect = base_to_dialect(base_code)
      Languages.get_predefined_language(dialect) != nil
    else
      false
    end
  end

  @doc """
  Gets all available dialect codes for a base language.

  Searches the predefined language list for all dialects
  matching the given base code.

  ## Examples

      iex> DialectMapper.dialects_for_base("en")
      ["en-US", "en-GB", "en-CA", "en-AU"]

      iex> DialectMapper.dialects_for_base("es")
      ["es-ES", "es-MX", "es-AR", "es-CO"]

      iex> DialectMapper.dialects_for_base("ja")
      ["ja"]

      iex> DialectMapper.dialects_for_base("xx")
      []

  ## Use Cases

  - Populate user preference dropdown
  - Admin analytics (dialects per base language)
  - Migration tools (find affected users)
  """
  def dialects_for_base(base_code) when is_binary(base_code) do
    base_lower = String.downcase(base_code)

    Languages.get_available_languages()
    |> Enum.filter(fn %{code: code} ->
      extract_base(code) == base_lower
    end)
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  @doc """
  Gets the default dialects map.

  Useful for debugging, testing, or documentation purposes.

  ## Examples

      iex> defaults = DialectMapper.default_dialects()
      iex> defaults["en"]
      "en-US"

      iex> defaults["pt"]
      "pt-BR"
  """
  def default_dialects, do: @default_dialects

  @doc """
  Counts how many entries share each base language code in a list of
  language entries. Used by language switchers to decide whether to
  show a country qualifier or just the bare language name.

  Accepts both maps with atom-keyed `:code` (e.g. `%Language{}` structs)
  and string-keyed `"code"` (e.g. JSON-decoded settings). Entries
  without a recognizable code are skipped.

  ## Examples

      iex> DialectMapper.group_dialects_by_base([
      ...>   %{code: "en-US"},
      ...>   %{code: "en-GB"},
      ...>   %{code: "et-EE"}
      ...> ])
      %{"en" => 2, "et" => 1}

      iex> DialectMapper.group_dialects_by_base([])
      %{}
  """
  def group_dialects_by_base(languages) when is_list(languages) do
    languages
    |> Enum.reduce([], fn lang, acc ->
      case lang_code(lang) do
        nil -> acc
        code -> [extract_base(code) | acc]
      end
    end)
    |> Enum.frequencies()
  end

  defp lang_code(%{code: code}) when is_binary(code), do: code
  defp lang_code(%{"code" => code}) when is_binary(code), do: code
  defp lang_code(_), do: nil
end
