defmodule PhoenixKit.Integration.Sitemap.SettingsExtensionSchemaTest do
  @moduledoc """
  Covers the sitemap settings page's extension point: a source module can
  declare `sitemap_settings_schema/0` and have its fields rendered and
  editable on the core sitemap settings page, without the core needing to
  know about that source ahead of time
  (see `PhoenixKit.Modules.Sitemap.Sources.Source`).

  Uses two in-file fixture source modules — one that declares a schema, one
  that doesn't — instead of depending on a real optional dependency (like
  phoenix_kit_entities) being installed in this repo's test suite.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Sitemap.Web.Settings, as: SitemapSettings
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/sitemap")

  defmodule FakeSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :fake_entities

    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts), do: []

    @impl true
    def sitemap_settings_schema do
      [
        %{
          key: "sitemap_fake_entities_include_index",
          type: :boolean,
          label: "Include entity index page",
          help: "Adds the /fake-entities listing page",
          default: true
        }
      ]
    end
  end

  defmodule NoSchemaSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :no_schema

    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts), do: []
  end

  defmodule BadDefaultSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :bad_default

    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts), do: []

    # A boolean field whose declared default is NOT a boolean — an easy
    # mistake for a third-party source author (`settings_field.default` is
    # typed `term()`). `Settings.get_boolean_setting/2` guards on
    # `is_boolean(default)`, so the toggle handler must not pass this default
    # straight through or it raises and kills the settings page.
    @impl true
    def sitemap_settings_schema do
      [
        %{
          key: "sitemap_bad_default_flag",
          type: :boolean,
          label: "Flag with a bad default",
          help: nil,
          default: nil
        }
      ]
    end
  end

  describe "build_extension_sources/1 (pure data prep, no LiveView needed)" do
    test "includes only sources that declare a settings schema, with values attached" do
      assert [{FakeSource, [field]}] =
               SitemapSettings.build_extension_sources([NoSchemaSource, FakeSource])

      assert field.key == "sitemap_fake_entities_include_index"
      assert field.label == "Include entity index page"
      # Unset in Settings -> falls back to the field's own declared default.
      assert field.value == true
    end

    test "reflects a saved value instead of the field's default" do
      {:ok, _} = Settings.update_boolean_setting("sitemap_fake_entities_include_index", false)

      assert [{FakeSource, [field]}] = SitemapSettings.build_extension_sources([FakeSource])
      assert field.value == false
    end

    test "returns an empty list when no source declares a schema" do
      assert SitemapSettings.build_extension_sources([NoSchemaSource]) == []
    end
  end

  describe "rendered on the settings page and toggleable" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      original_env = Application.get_env(:phoenix_kit, :sitemap, [])
      Application.put_env(:phoenix_kit, :sitemap, sources: [FakeSource])
      on_exit(fn -> Application.put_env(:phoenix_kit, :sitemap, original_env) end)

      %{conn: conn}
    end

    test "renders the field's label/help and lets an admin toggle it", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)

      assert html =~ "Include entity index page"
      assert html =~ "Adds the /fake-entities listing page"

      view
      |> element("input[phx-value-key='sitemap_fake_entities_include_index']")
      |> render_click()

      assert Settings.get_boolean_setting("sitemap_fake_entities_include_index", true) == false
    end
  end

  describe "boolean field declared with a non-boolean default" do
    setup %{conn: conn} do
      {user, _token} = create_admin_user()
      conn = log_in_user(conn, user)

      original_env = Application.get_env(:phoenix_kit, :sitemap, [])
      Application.put_env(:phoenix_kit, :sitemap, sources: [BadDefaultSource])
      on_exit(fn -> Application.put_env(:phoenix_kit, :sitemap, original_env) end)

      %{conn: conn}
    end

    test "renders and toggles without crashing the settings page", %{conn: conn} do
      {:ok, view, html} = live(conn, @path)
      assert html =~ "Flag with a bad default"

      # Before the fix this raised a FunctionClauseError from
      # get_boolean_setting/2 (guard: is_boolean(default)) and killed the LV.
      view
      |> element("input[phx-value-key='sitemap_bad_default_flag']")
      |> render_click()

      # nil default is treated as false, so the first toggle stores true.
      assert Settings.get_boolean_setting("sitemap_bad_default_flag", false) == true
    end
  end
end
