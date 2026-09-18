defmodule PhoenixKitWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext),
  your module gains a set of macros for translations, for example:

      use Gettext, backend: PhoenixKitWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.

  This backend does **not** `use Gettext.Backend`. That macro compiles each
  message into a function clause, and ~2.7k messages × 7 translated locales
  is superlinear in the Erlang compiler (a clean `mix compile --force` spent
  ~13s on this file even after `split_module_by: [:locale]`, tripping the
  ">10s" notice). Translations are parsed from `priv/gettext` at compile
  time into a nested map, embedded as a compressed binary, and looked up
  with `Map.get/2`. Callers still go through `Gettext.dgettext/3` and friends;
  only the storage changes.
  """

  @behaviour Gettext.Backend

  require Logger

  alias PhoenixKitWeb.Gettext.Compiler

  @otp_app :phoenix_kit

  # Host config wins over the defaults, exactly like `Gettext.Backend.__using__`.
  # Every attribute below is derived from the MERGED opts -- reading a default
  # directly would build the catalog from a configured `:priv` while reporting
  # the unconfigured one to `mix gettext.extract`.
  @opts [
          otp_app: @otp_app,
          priv: "priv/gettext",
          interpolation: Gettext.Interpolation.Default,
          default_domain: "default"
        ]
        |> Keyword.merge(Application.compile_env(@otp_app, __MODULE__, []))
        |> Keyword.put_new(
          :plural_forms,
          Application.compile_env(:gettext, :plural_forms, Gettext.Plural)
        )

  @priv Keyword.fetch!(@opts, :priv)
  @interpolation Keyword.fetch!(@opts, :interpolation)
  @default_domain Keyword.fetch!(@opts, :default_domain)
  @plural_mod Keyword.fetch!(@opts, :plural_forms)

  @snapshot Compiler.snapshot(@opts)
  @catalog_bin @snapshot.binary
  @known_locales @snapshot.known_locales
  @plural_infos @snapshot.plural_infos
  @po_hash @snapshot.hash

  for path <- @snapshot.po_paths do
    @external_resource path
  end

  @doc false
  def __mix_recompile__? do
    @po_hash != Compiler.hash(@opts)
  end

  @doc false
  def __gettext__(:priv), do: @priv
  def __gettext__(:otp_app), do: @otp_app
  def __gettext__(:known_locales), do: @known_locales
  def __gettext__(:default_domain), do: @default_domain
  def __gettext__(:interpolation), do: @interpolation

  def __gettext__(:default_locale) do
    Keyword.get(@opts, :default_locale) || Application.fetch_env!(:gettext, :default_locale)
  end

  if Gettext.Extractor.extracting?() do
    Gettext.ExtractorAgent.add_backend(__MODULE__)
  end

  @impl Gettext.Backend
  def lgettext(locale, domain, msgctxt \\ nil, msgid, bindings)

  def lgettext(locale, domain, msgctxt, msgid, bindings) do
    case lookup(locale, domain, msgctxt, msgid) do
      {:singular, interpolatable} ->
        @interpolation.runtime_interpolate(interpolatable, bindings)

      {:plural, _msgid_plural, %{0 => interpolatable}, _file} ->
        @interpolation.runtime_interpolate(interpolatable, bindings)

      _ ->
        handle_missing_translation(locale, domain, msgctxt, msgid, bindings)
    end
  end

  @impl Gettext.Backend
  def lngettext(locale, domain, msgctxt \\ nil, msgid, msgid_plural, n, bindings)

  def lngettext(locale, domain, msgctxt, msgid, msgid_plural, n, bindings) do
    case lookup(locale, domain, msgctxt, msgid) do
      {:plural, ^msgid_plural, forms, file} ->
        interpolate_plural(locale, domain, forms, n, bindings, file)

      _ ->
        handle_missing_plural_translation(
          locale,
          domain,
          msgctxt,
          msgid,
          msgid_plural,
          n,
          bindings
        )
    end
  end

  @impl Gettext.Backend
  def handle_missing_bindings(exception, incomplete) do
    _ = Logger.error(Exception.message(exception))
    incomplete
  end

  @impl Gettext.Backend
  def handle_missing_translation(_locale, domain, _msgctxt, msgid, bindings) do
    Gettext.Compiler.warn_if_domain_contains_slashes(domain)

    with {:ok, interpolated} <- @interpolation.runtime_interpolate(msgid, bindings),
         do: {:default, interpolated}
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(
        _locale,
        domain,
        _msgctxt,
        msgid,
        msgid_plural,
        n,
        bindings
      ) do
    Gettext.Compiler.warn_if_domain_contains_slashes(domain)
    string = if n == 1, do: msgid, else: msgid_plural
    bindings = Map.put(bindings, :count, n)

    with {:ok, interpolated} <- @interpolation.runtime_interpolate(string, bindings),
         do: {:default, interpolated}
  end

  defp lookup(locale, domain, msgctxt, msgid) do
    catalog()
    |> Map.get(locale, %{})
    |> Map.get(domain, %{})
    |> Map.get({msgctxt, msgid}, :miss)
  end

  defp interpolate_plural(locale, domain, forms, n, bindings, file) do
    # `plural_info` carries the file's own `Plural-Forms:` header when it has
    # one, so a translator-authored rule wins over Gettext's built-in table --
    # and `@plural_mod` honours `config :gettext, :plural_forms`.
    form = @plural_mod.plural(Map.get(@plural_infos, {locale, domain}, locale), n)
    bindings = Map.put(bindings, :count, n)

    case forms do
      %{^form => interpolatable} ->
        @interpolation.runtime_interpolate(interpolatable, bindings)

      %{} ->
        raise Gettext.PluralFormError,
          form: form,
          locale: locale,
          file: file,
          line: 1
    end
  end

  @doc """
  Decodes the embedded catalogue into `:persistent_term` ahead of the first
  lookup.

  Called from `PhoenixKit.Application.start/2`. The decode costs ~20ms and
  `:persistent_term.put/2` scans every process, so leaving it to the first
  `gettext` call puts both on a random request instead of on boot.
  """
  @spec warm_catalog() :: :ok
  def warm_catalog do
    _ = catalog()
    :ok
  end

  defp catalog do
    key = {__MODULE__, :catalog}

    case :persistent_term.get(key, :"$miss") do
      :"$miss" ->
        cat = :erlang.binary_to_term(@catalog_bin)
        :persistent_term.put(key, cat)
        cat

      cat ->
        cat
    end
  end
end
