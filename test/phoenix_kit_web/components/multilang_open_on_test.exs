defmodule PhoenixKitWeb.Components.MultilangOpenOnTest do
  @moduledoc """
  `mount_multilang(socket, open_on: :viewing_language)` opens an edit form
  on the tab of the language the admin is viewing the page in, instead of
  the main one — the catalogue asked for it (via Max, 2026-09-21), and
  every module's edit forms share the need.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKitWeb.Components.MultilangForm

  alias Phoenix.LiveView.Lifecycle
  alias PhoenixKit.Modules.Languages

  defp socket, do: %Phoenix.LiveView.Socket{private: %{lifecycle: %Lifecycle{}}}

  defp viewing(dialect) do
    Languages.put_request_locale(dialect)
    on_exit(fn -> Process.delete(:phoenix_kit_request_locale) end)
  end

  describe "viewing_language/2" do
    test "the exact code, else the first sharing its base, else nil" do
      codes = ["en-US", "fr-FR", "fr-CA", "et-EE"]

      assert viewing_language(codes, "fr-CA") == "fr-CA"
      assert viewing_language(codes, "fr") == "fr-FR"
      assert viewing_language(codes, "et_EE") == "et-EE"
      assert viewing_language(codes, "EN") == "en-US"
      assert viewing_language(codes, "de-DE") == nil
      assert viewing_language(codes, nil) == nil
      assert viewing_language([], "en") == nil
      assert viewing_language(["en-US", "en-GB"], "en") == "en-US"
    end
  end

  describe "mount_multilang/2 with open_on" do
    setup do
      {:ok, _} = Languages.enable_system()
      {:ok, _} = Languages.add_language("fr-FR")
      :ok
    end

    test ":viewing_language opens on the page's language" do
      viewing("fr-FR")
      socket = mount_multilang(socket(), open_on: :viewing_language)

      assert socket.assigns.current_lang == "fr-FR"
      assert socket.assigns.primary_language == "en-US"
    end

    test "with no request locale — an embedded LiveView — the main tab, whatever Gettext says" do
      Gettext.put_locale(PhoenixKitWeb.Gettext, "fr")
      on_exit(fn -> Gettext.put_locale(PhoenixKitWeb.Gettext, "en") end)

      assert mount_multilang(socket(), open_on: :viewing_language).assigns.current_lang == "en-US"
    end

    test "the default, :primary, and an unmatched page language keep the main tab" do
      viewing("fr-FR")
      assert mount_multilang(socket()).assigns.current_lang == "en-US"
      assert mount_multilang(socket(), open_on: :primary).assigns.current_lang == "en-US"

      viewing("de-DE")
      assert mount_multilang(socket(), open_on: :viewing_language).assigns.current_lang == "en-US"
    end
  end

  test "with multilang off it is a no-op" do
    viewing("fr-FR")
    socket = mount_multilang(socket(), open_on: :viewing_language)

    refute socket.assigns.multilang_enabled
    assert socket.assigns.current_lang == nil
  end
end
