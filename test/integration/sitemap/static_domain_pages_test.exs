defmodule PhoenixKit.Integration.Sitemap.StaticDomainPagesProviderStub do
  @moduledoc false
  def ok do
    [
      %{host: "site.example.com", language: "en", primary: true},
      %{host: "site.example.fr", language: "fr", primary: false}
    ]
  end

  def empty, do: []
end

defmodule PhoenixKit.Integration.Sitemap.StaticDomainPagesTest do
  @moduledoc """
  Pins that static pages reach the domain of every language that has one.

  The Static source emits URLs for the default language only, because in a
  prefix-based install a `/de/...` static page would 404. Under domain mode
  that premise does not hold: the language has its own host, and the page is
  served there prefix-free — verified on a live 3-domain install, where
  `https://<de-host>/` answers 200 with `lang="de"`.

  The consequence was that every non-primary domain's sitemap was missing its
  own home page — the single most important URL of that domain — while
  listing its products.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integration.Sitemap.StaticDomainPagesProviderStub, as: Stub
  alias PhoenixKit.Modules.Sitemap.DomainMode
  alias PhoenixKit.Modules.Sitemap.Sources.Static
  alias PhoenixKit.Settings

  @base "https://site.example.com"

  setup do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true},
        %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
      ]
    })

    # Keep the assertions about the home page alone.
    {:ok, _} = Settings.update_boolean_setting("sitemap_include_registration", false)
    Application.put_env(:phoenix_kit, :sitemap_domains_provider, {Stub, :ok})

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :sitemap_domains_provider)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  defp collect(language, is_default?) do
    [base_url: @base, language: language, is_default_language: is_default?]
    |> Static.collect()
    |> Enum.map(& &1.loc)
  end

  test "a language with its own domain gets the static pages, prefixed for re-hosting" do
    assert collect("fr", false) == ["#{@base}/fr/"]
  end

  test "a language without a domain still gets nothing" do
    assert collect("de", false) == []
  end

  test "the default language is unchanged" do
    assert collect("en", true) == ["#{@base}/"]
  end

  test "domain mode off leaves every non-default language empty" do
    Application.put_env(:phoenix_kit, :sitemap_domains_provider, {Stub, :empty})

    assert collect("fr", false) == []
    assert collect("en", true) == ["#{@base}/"]
  end

  test "the mapped domain's file ends up carrying its own home page" do
    entries = Static.collect(base_url: @base, language: "en", is_default_language: true)

    entries =
      entries ++ Static.collect(base_url: @base, language: "fr", is_default_language: false)

    result = DomainMode.rebuild_for_domains(entries, @base)

    assert Enum.map(result["site.example.com"], & &1.loc) == ["https://site.example.com/"]
    assert Enum.map(result["site.example.fr"], & &1.loc) == ["https://site.example.fr/"]

    # Both home pages belong to one canonical group, so each carries the
    # other as an alternate.
    [fr_entry] = result["site.example.fr"]
    hrefs = Map.new(fr_entry.alternates, &{&1.hreflang, &1.href})
    assert hrefs["en"] == "https://site.example.com/"
    assert hrefs["fr"] == "https://site.example.fr/"
    assert hrefs["x-default"] == "https://site.example.com/"
  end
end
