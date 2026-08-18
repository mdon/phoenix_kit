defmodule PhoenixKit.Integration.Sitemap.RegenerateTest do
  @moduledoc """
  Pins that `Sitemap.regenerate/1` actually regenerates.

  It used to return `{:ok, %{status: :pending, message: "Generator not yet
  implemented"}}` — a placeholder left behind after `Sitemap.Generator` landed.
  The generator has been real for many releases, but the placeholder (and its
  "will be implemented" comment) survived, so anyone reading it — or calling
  it — concludes sitemap generation is missing.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap
  alias PhoenixKit.Settings

  @base_url "https://example.test"

  setup do
    {:ok, _} = Settings.update_setting("site_url", @base_url)
    {:ok, _} = Settings.update_boolean_setting("crawlers_no_index", false)
    :ok
  end

  test "regenerate/1 runs the generator instead of returning a placeholder" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)

    # Give the run something it must find, so the assertions below prove real
    # collection happened rather than an empty-but-valid document.
    {:ok, _} =
      Settings.update_setting(
        "sitemap_custom_urls",
        JSON.encode!([%{"path" => "/regenerate-probe", "title" => "Probe"}])
      )

    assert {:ok, result} = Sitemap.regenerate(:test_scope)

    refute match?(%{status: :pending}, result)
    assert result.total_urls >= 1
    assert result.index_xml =~ "<?xml"
    assert result.index_xml =~ "/regenerate-probe"
  end

  test "regenerate/1 refuses when no base URL is configured" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)
    {:ok, _} = Settings.update_setting("site_url", "")

    # Generator.generate_all/1 only rejects nil, so an unset site_url would
    # otherwise be written into the files as host-less <loc>s. The scheduler
    # guards this; so must this entry point.
    assert Sitemap.regenerate() == {:error, :base_url_not_configured}
  end

  test "regenerate/1 refuses when the module is disabled" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", false)

    assert Sitemap.regenerate() == {:error, :sitemap_disabled}
  end
end
