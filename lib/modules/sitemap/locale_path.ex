defmodule PhoenixKit.Modules.Sitemap.LocalePath do
  @moduledoc """
  Shared locale-segment policy for sitemap sources.

  Every sitemap source (`publishing`, `static`, `posts`, ...) decides
  whether a URL entry should carry a language prefix using the same
  three rules:

    1. No language supplied → no prefix.
    2. Single-language mode (Languages module disabled or only one
       enabled) → no prefix is meaningful.
    3. The language is the site's primary AND the site-wide
       `Languages.default_language_no_prefix?/0` setting is on → omit
       the prefix to keep the sitemap consistent with the public URL
       shape served at request time. Indexed canonicals must not drift
       from served URLs.
    4. Otherwise → emit the prefix.

  Each source still decides **how** to format the prefix (base code via
  `DialectMapper.extract_base/1`, or display code via
  `LanguageHelpers.get_display_code/2` for hreflang-aware emission) —
  this module owns only the decision, not the formatting.
  """

  alias PhoenixKit.Modules.Languages

  @doc """
  Returns true when the sitemap entry for `language` should include
  the locale segment. `is_default` should be true when `language` is
  the site's primary language.

  Wrapped to survive boot / mix-task contexts where the Languages
  module or Settings table may not be reachable —
  `single_language_mode?/0`'s rescue returns `true` in that case, so
  `emit_prefix?/2` falls back to `false` (no prefix). That keeps the
  sitemap consistent with single-language sites under DB-unreachable
  conditions; runtime sitemap generation always has a reachable DB.
  """
  @spec emit_prefix?(String.t() | nil, boolean()) :: boolean()
  def emit_prefix?(nil, _is_default), do: false

  def emit_prefix?(_language, is_default) do
    cond do
      single_language_mode?() -> false
      is_default and Languages.default_language_no_prefix?() -> false
      true -> true
    end
  end

  @doc """
  Returns true when the site is effectively single-language (Languages
  module disabled, or only one language enabled). Defensive: rescues
  to `true` on any lookup failure so the sitemap omits prefixes
  during install / mix tasks rather than emitting broken multi-lang
  entries.
  """
  @spec single_language_mode?() :: boolean()
  def single_language_mode? do
    not Languages.enabled?() or length(Languages.get_enabled_languages()) <= 1
  rescue
    _ -> true
  end
end
