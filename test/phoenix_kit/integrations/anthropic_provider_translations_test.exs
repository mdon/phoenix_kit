defmodule PhoenixKit.Integrations.AnthropicProviderTranslationsTest do
  @moduledoc """
  Every string of the Anthropic provider definition is in the template (`.pot`)
  and translated, not fuzzy, in each of the eight shipped locales. Nothing
  checks the catalogues on its own and a missing entry only shows as English in
  the browser, so this reads the `gettext/1` calls of `anthropic/0` in
  `providers.ex` and looks each msgid up. `en` is the source language and keeps
  empty msgstr values.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)
  @root Path.expand("../../..", __DIR__)
  @source "lib/phoenix_kit/integrations/providers.ex"

  # The literal `gettext("...")` msgids between `defp anthropic do` and the
  # next provider.
  defp provider_msgids do
    code = File.read!(Path.join(@root, @source))
    [_, rest] = String.split(code, "defp anthropic do", parts: 2)
    [definition, _] = String.split(rest, "defp openrouter do", parts: 2)

    ~r/(?<![a-z_])gettext\(\s*"((?:[^"\\]|\\.)*)"/s
    |> Regex.scan(definition)
    |> Enum.map(fn [_, msgid] -> msgid end)
    |> Enum.uniq()
  end

  defp catalogue(path) do
    {:ok, po} = Expo.PO.parse_file(Path.join(@root, path))

    for %Expo.Message.Singular{} = message <- po.messages, into: %{} do
      {IO.iodata_to_binary(message.msgid), message}
    end
  end

  test "the provider has strings to translate" do
    msgids = provider_msgids()

    assert "Anthropic" in msgids
    assert "From console.anthropic.com/settings/keys" in msgids
    assert length(msgids) >= 12
  end

  test "the template (.pot) has every msgid" do
    template = catalogue("priv/gettext/default.pot")

    for msgid <- provider_msgids() do
      assert Map.has_key?(template, msgid), "default.pot is missing #{inspect(msgid)}"
    end
  end

  for locale <- @locales do
    test "#{locale} translates every msgid, none left fuzzy" do
      catalogue = catalogue("priv/gettext/#{unquote(locale)}/LC_MESSAGES/default.po")

      for msgid <- provider_msgids() do
        message = Map.get(catalogue, msgid)

        assert message, "#{unquote(locale)} is missing #{inspect(msgid)}"

        assert IO.iodata_to_binary(message.msgstr) != "",
               "#{unquote(locale)} leaves #{inspect(msgid)} untranslated"

        refute "fuzzy" in List.flatten(message.flags),
               "#{unquote(locale)} marks #{inspect(msgid)} fuzzy"
      end
    end
  end
end
