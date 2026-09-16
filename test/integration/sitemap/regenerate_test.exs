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

  test "regenerate/1 refuses when neither site_url nor the endpoint gives a base URL" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)
    {:ok, _} = Settings.update_setting("site_url", "")
    without_parent_endpoint()

    # Generator.generate_all/1 only rejects nil, so an unset base URL would
    # otherwise be written into the files as host-less <loc>s. The scheduler
    # guards this; so must this entry point.
    assert Sitemap.get_base_url() == ""
    assert Sitemap.regenerate() == {:error, :base_url_not_configured}
  end

  test "with site_url unset, the sitemap uses the host endpoint's URL" do
    # The generated file lives inside the dependency, so an upgrade deletes it
    # and the next request regenerates — which used to mean a 503 for every
    # site that had never set site_url.
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", true)
    {:ok, _} = Settings.update_setting("site_url", "")
    # Core's own endpoint stands in for the host's. Set explicitly rather than
    # inherited: this test is about the fallback, not about what state the
    # suite happens to leave `:parent_module` in.
    with_parent_module(PhoenixKit)

    {:ok, _} =
      Settings.update_setting(
        "sitemap_custom_urls",
        JSON.encode!([%{"path" => "/fallback-probe", "title" => "Probe"}])
      )

    endpoint_url = String.trim_trailing(PhoenixKitWeb.Endpoint.url(), "/")
    assert Sitemap.get_base_url() == endpoint_url

    assert {:ok, result} = Sitemap.regenerate(:test_scope)
    assert result.index_xml =~ endpoint_url
  end

  # Point the parent-endpoint lookup at an application (with or without an
  # endpoint). `PhoenixKit.Config.get/1` reads the application env directly,
  # so this is enough; async: false keeps it from leaking into other tests.
  defp without_parent_endpoint, do: with_parent_module(NoSuchHostApp)

  defp with_parent_module(module) do
    previous = Application.get_env(:phoenix_kit, :parent_module)
    Application.put_env(:phoenix_kit, :parent_module, module)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:phoenix_kit, :parent_module)
        value -> Application.put_env(:phoenix_kit, :parent_module, value)
      end
    end)
  end

  test "regenerate/1 refuses when the module is disabled" do
    {:ok, _} = Settings.update_boolean_setting("sitemap_enabled", false)

    assert Sitemap.regenerate() == {:error, :sitemap_disabled}
  end
end
