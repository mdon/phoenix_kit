defmodule PhoenixKitWeb.Live.Settings.ApiGuideTranslationsTest do
  @moduledoc """
  Every string of the admin API guide is in the template and has a translation in
  every shipped locale. The code samples and the tool texts are shown as declared and
  are not translated; the page's own sentences are. There is no automatic check of the
  catalogues, and a missing entry only shows as English text in the browser, so this
  test reads the `gettext/1` calls of the page's sources and looks each msgid up in the
  `.pot` and in the eight translated `.po` files. `en` is the source language and keeps
  empty msgstr values.
  """
  use ExUnit.Case, async: true

  @page_sources ~w(
    lib/phoenix_kit_web/live/settings/api_guide.ex
    lib/phoenix_kit_web/live/settings/api_guide.html.heex
  )
  @locales ~w(de es et fr it pl ru uk)
  @root Path.expand("../../../..", __DIR__)

  # Every literal first argument of a `gettext(...)` call in the page's sources.
  defp page_msgids do
    @page_sources
    |> Enum.flat_map(fn source ->
      ~r/gettext\(\s*"((?:[^"\\]|\\.)*)"/s
      |> Regex.scan(File.read!(Path.join(@root, source)))
      |> Enum.map(&List.last/1)
    end)
    |> Enum.uniq()
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), IO.iodata_to_binary(message.msgstr)}
    end
  end

  defp placeholders(text),
    do: ~r/%\{(\w+)\}/ |> Regex.scan(text) |> Enum.map(&List.last/1) |> Enum.sort()

  test "the page has strings to translate" do
    assert length(page_msgids()) > 30
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- page_msgids() do
      assert Map.has_key?(template, msgid), "default.pot lacks #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid and keeps its placeholders" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- page_msgids() do
        msgstr = Map.get(catalogue, msgid)
        assert is_binary(msgstr) and msgstr != "", "#{unquote(locale)} lacks #{inspect(msgid)}"

        assert placeholders(msgstr) == placeholders(msgid),
               "#{unquote(locale)} changes the placeholders of #{inspect(msgid)}"
      end
    end
  end

  test "en keeps the source language: every msgid is present with an empty msgstr" do
    catalogue = catalogue("priv/gettext/en/LC_MESSAGES/default.po")

    for msgid <- page_msgids() do
      assert Map.get(catalogue, msgid) == ""
    end
  end

  test "the backend serves the translation, not the English text" do
    backend = PhoenixKitWeb.Gettext
    previous = Gettext.get_locale(backend)
    on_exit(fn -> Gettext.put_locale(backend, previous) end)

    assert Gettext.with_locale(backend, "de", fn ->
             Gettext.gettext(backend, "Dangerous operations")
           end) == "Gefährliche Vorgänge"

    assert Gettext.with_locale(backend, "uk", fn ->
             Gettext.gettext(backend, "Dangerous operations")
           end) == "Небезпечні операції"
  end
end
