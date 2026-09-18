defmodule PhoenixKitWeb.Gettext.Compiler do
  @moduledoc false

  # Compile-time loader for `PhoenixKitWeb.Gettext`.
  #
  # Gettext's default backend turns every message into a function clause.
  # ~2.7k messages × 7 translated locales is superlinear in the Erlang
  # compiler (~13s for this file after splitting by locale). Parsing the
  # PO files into a nested map and embedding it as a compressed binary
  # compiles in a few hundred milliseconds; lookups are `Map.get/2`.

  require Logger

  alias Expo.Message
  alias Expo.PO

  @default_priv "priv/gettext"

  @type interpolatable :: Gettext.Interpolation.Default.interpolatable()

  @type entry ::
          {:singular, interpolatable}
          | {:plural, String.t(), %{non_neg_integer() => interpolatable},
             {String.t(), pos_integer()}}

  @type catalog :: %{String.t() => %{String.t() => %{{String.t() | nil, String.t()} => entry}}}

  @type snapshot :: %{
          binary: binary(),
          plural_infos: %{{String.t(), String.t()} => term()},
          known_locales: [String.t()],
          po_paths: [String.t()],
          hash: binary()
        }

  @spec snapshot(keyword()) :: snapshot()
  def snapshot(opts) do
    interpolation = Keyword.get(opts, :interpolation, Gettext.Interpolation.Default)
    plural_mod = Keyword.get(opts, :plural_forms, Gettext.Plural)
    files = po_files(opts)
    {catalog, plural_infos} = build_catalog(files, interpolation, plural_mod)

    %{
      binary: :erlang.term_to_binary(catalog, [:compressed]),
      plural_infos: plural_infos,
      known_locales: catalog |> Map.keys() |> Enum.sort(),
      po_paths: Enum.map(files, & &1.expanded),
      hash: hash_paths(Enum.map(files, & &1.path))
    }
  end

  @spec hash(keyword()) :: binary()
  def hash(opts) do
    opts
    |> po_files()
    |> Enum.map(& &1.path)
    |> hash_paths()
  end

  defp hash_paths(paths) do
    paths |> Enum.sort() |> :erlang.md5()
  end

  defp po_files(opts) do
    priv = Keyword.get(opts, :priv, @default_priv)

    files =
      priv
      |> Path.join("*/LC_MESSAGES/*.po")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        {locale, domain} = locale_and_domain_from_path(path)
        # Hash the relative glob path so `__mix_recompile__?` is cwd-stable
        # (same as Gettext.Compiler). Expand only for `@external_resource`.
        %{locale: locale, domain: domain, path: path, expanded: Path.expand(path)}
      end)

    maybe_restrict_locales(files, opts[:allowed_locales])
  end

  defp maybe_restrict_locales(files, nil), do: files

  defp maybe_restrict_locales(files, allowed) when is_list(allowed) do
    allowed = MapSet.new(Enum.map(allowed, &to_string/1))
    Enum.filter(files, &MapSet.member?(allowed, &1.locale))
  end

  defp locale_and_domain_from_path(path) do
    [file, "LC_MESSAGES", locale | _rest] = path |> Path.split() |> Enum.reverse()
    {locale, Path.rootname(file, ".po")}
  end

  defp build_catalog(files, interpolation, plural_mod) do
    Enum.reduce(files, {%{}, %{}}, fn %{locale: locale, domain: domain, path: path},
                                      {catalog, plural_infos} ->
      messages_struct = PO.parse_file!(path, strip_meta: true)

      # Same resolution Gettext.Compiler uses: the file's `Plural-Forms:`
      # header when it has one, otherwise the bare locale.
      plural_info = Gettext.Plural.plural_info(locale, messages_struct, plural_mod)
      nplurals = plural_mod.nplurals(plural_info)

      entries = load_entries(messages_struct, path, interpolation, locale, nplurals)

      catalog =
        Map.update(catalog, locale, %{domain => entries}, fn domains ->
          Map.put(domains, domain, entries)
        end)

      {catalog, Map.put(plural_infos, {locale, domain}, plural_info)}
    end)
  end

  defp load_entries(%Expo.Messages{messages: messages}, path, interpolation, locale, nplurals) do
    messages
    |> Enum.filter(&match?(%{obsolete: false}, &1))
    |> Enum.flat_map(&entry(&1, interpolation, path, locale, nplurals))
    |> Map.new()
  end

  defp entry(%Message.Singular{} = message, interpolation, _path, _locale, _nplurals) do
    msgid = IO.iodata_to_binary(message.msgid)
    msgstr = IO.iodata_to_binary(message.msgstr)
    msgctxt = message.msgctxt && IO.iodata_to_binary(message.msgctxt)

    case msgstr do
      "" ->
        []

      _ ->
        [{{msgctxt, msgid}, {:singular, interpolation.to_interpolatable(msgstr)}}]
    end
  end

  defp entry(%Message.Plural{} = message, interpolation, path, locale, nplurals) do
    warn_if_missing_plural_forms(locale, nplurals, message, path)

    msgid = IO.iodata_to_binary(message.msgid)
    msgid_plural = IO.iodata_to_binary(message.msgid_plural)
    msgctxt = message.msgctxt && IO.iodata_to_binary(message.msgctxt)
    line = Message.source_line_number(message, :msgid) || 1

    msgstr =
      Map.new(message.msgstr, fn {form, str} -> {form, IO.iodata_to_binary(str)} end)

    if Enum.any?(msgstr, &match?({_form, ""}, &1)) do
      []
    else
      forms = Map.new(msgstr, fn {form, str} -> {form, interpolation.to_interpolatable(str)} end)
      [{{msgctxt, msgid}, {:plural, msgid_plural, forms, {path, line}}}]
    end
  end

  defp warn_if_missing_plural_forms(locale, nplurals, message, file) do
    Enum.each(0..(nplurals - 1), fn form ->
      unless Map.has_key?(message.msgstr, form) do
        line = Message.source_line_number(message, :msgid) || 1

        Logger.error([
          "#{file}:#{line}: message is missing plural form ",
          Integer.to_string(form),
          " which is required by the locale ",
          inspect(locale)
        ])
      end
    end)
  end
end
