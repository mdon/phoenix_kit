defmodule PhoenixKitWeb.Live.ApprovalsTranslationsTest do
  @moduledoc """
  The sentences the approvals page builds from a number or a key: each is one message, so
  that a language can word it as a whole, and every shipped language has it.
  """
  use ExUnit.Case, async: true

  @locales ~w(de es et fr it pl ru uk)
  @expiry [
    "Expires in less than a minute",
    "Expires in %{count} min",
    "Expires in %{count} h",
    "Expires in %{count} d"
  ]
  @words ~w(created updated deleted removed unchanged skipped error)

  defp translate(locale, msgid, bindings \\ []) do
    Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
      Gettext.gettext(PhoenixKitWeb.Gettext, msgid, bindings)
    end)
  end

  defp word(locale, word) do
    Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fn ->
      Gettext.pgettext(PhoenixKitWeb.Gettext, "approval summary", word)
    end)
  end

  test "the expiry sentences are whole messages, translated in every language" do
    for locale <- @locales, msgid <- @expiry do
      text = translate(locale, msgid, count: 7)

      assert text != String.replace(msgid, "%{count}", "7"), "#{locale}: #{msgid}"
      refute text =~ "%{", "#{locale}: #{msgid}"
      if msgid =~ "%{count}", do: assert(text =~ "7", "#{locale}: #{msgid}")
    end
  end

  test "less than a minute is worded as a whole where the case of the noun matters" do
    msgid = "Expires in less than a minute"

    assert translate("de", msgid) == "Läuft in weniger als einer Minute ab"
    assert translate("et", msgid) == "Aegub vähem kui minuti pärast"
    assert translate("ru", msgid) == "Истекает менее чем через минуту"
    assert translate("uk", msgid) == "Спливає менш ніж за хвилину"
  end

  test "the words of actions and totals are translated in every language" do
    for locale <- @locales, word <- @words do
      assert word(locale, word) != word, "#{locale}: #{word}"
    end
  end

  test "English keeps the word as it is" do
    for word <- @words, do: assert(word("en", word) == word)
  end
end
