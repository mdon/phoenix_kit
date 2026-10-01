defmodule PhoenixKit.Modules.Sitemap.GeneratorSourcesTest do
  # Flips the global :sitemap config.
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.Sources

  setup do
    previous = Application.get_env(:phoenix_kit, :sitemap)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :sitemap, previous),
        else: Application.delete_env(:phoenix_kit, :sitemap)
    end)
  end

  test "extra_sources are added to the default list" do
    Application.put_env(:phoenix_kit, :sitemap, extra_sources: [MyApp.ExtraSource])
    sources = Generator.get_sources()

    assert Sources.Static in sources
    assert MyApp.ExtraSource in sources
  end

  test "extra_sources are added to a host's own :sources list" do
    Application.put_env(:phoenix_kit, :sitemap,
      sources: [Sources.Static],
      extra_sources: [MyApp.ExtraSource]
    )

    sources = Generator.get_sources()
    assert Sources.Static in sources
    assert MyApp.ExtraSource in sources
    refute Sources.RouterDiscovery in sources
  end

  test "a source listed in both is included once" do
    Application.put_env(:phoenix_kit, :sitemap, extra_sources: [Sources.Static])
    assert Enum.count(Generator.get_sources(), &(&1 == Sources.Static)) == 1
  end
end
