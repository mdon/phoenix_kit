defmodule PhoenixKit.Integration.Sitemap.GeneratorDedupeTest do
  @moduledoc """
  Regression test for a `loc` collision bug: `RouterDiscovery` blindly
  enumerates every GET route, and when a content source (Publishing,
  Entities, ...) emits a richer entry for the same URL, the old
  `Enum.uniq_by(& &1.loc)` dedup kept whichever entry happened to be listed
  first — which was always the poor `RouterDiscovery` entry, since it is
  first in `Generator.default_sources/0`. This silently dropped priority
  and hreflang alternates from the final sitemap for any URL that both a
  route and a content source produced (observed in production for
  `/cemented-carbides` and `/legal`).
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  defmodule FakeRouterDiscoverySource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :router_discovery
    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts) do
      [
        UrlEntry.new(%{
          loc: "https://example.com/cemented-carbides",
          priority: 0.5,
          changefreq: "weekly",
          source: :router_discovery
        })
      ]
    end
  end

  defmodule FakeContentSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :fake_content
    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts) do
      [
        UrlEntry.new(%{
          loc: "https://example.com/cemented-carbides",
          priority: 0.8,
          changefreq: "weekly",
          source: :fake_content,
          canonical_path: "/cemented-carbides",
          alternates: [
            %{hreflang: "en", href: "https://example.com/cemented-carbides"},
            %{hreflang: "et", href: "https://example.com/et/cemented-carbides"}
          ]
        })
      ]
    end
  end

  defmodule FakePlainContentSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :fake_plain_content
    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts) do
      [
        UrlEntry.new(%{
          loc: "https://example.com/legal",
          priority: 0.3,
          changefreq: "monthly",
          source: :fake_plain_content
        })
      ]
    end
  end

  defmodule FakeRicherLegalSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :fake_richer_legal
    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts) do
      [
        UrlEntry.new(%{
          loc: "https://example.com/legal",
          priority: 0.8,
          changefreq: "monthly",
          source: :fake_richer_legal,
          canonical_path: "/legal"
        })
      ]
    end
  end

  describe "collect_all_entries/2 — RouterDiscovery vs. content-source loc collisions" do
    test "the content-source entry wins when RouterDiscovery collides on the same loc" do
      entries =
        Generator.collect_all_entries(
          [base_url: "https://example.com"],
          [FakeRouterDiscoverySource, FakeContentSource]
        )

      assert [entry] = entries
      assert entry.loc == "https://example.com/cemented-carbides"
      assert entry.source == :fake_content
      assert entry.priority == 0.8
      assert entry.canonical_path == "/cemented-carbides"
      assert entry.alternates != nil
    end

    test "source list order does not matter — RouterDiscovery still loses when listed second" do
      entries =
        Generator.collect_all_entries(
          [base_url: "https://example.com"],
          [FakeContentSource, FakeRouterDiscoverySource]
        )

      assert [entry] = entries
      assert entry.source == :fake_content
    end

    test "a RouterDiscovery entry survives untouched when no other source claims its loc" do
      entries =
        Generator.collect_all_entries(
          [base_url: "https://example.com"],
          [FakeRouterDiscoverySource]
        )

      assert [entry] = entries
      assert entry.source == :router_discovery
      assert entry.priority == 0.5
    end

    test "between two non-RouterDiscovery entries, the one with canonical_path wins" do
      entries =
        Generator.collect_all_entries(
          [base_url: "https://example.com"],
          [FakePlainContentSource, FakeRicherLegalSource]
        )

      assert [entry] = entries
      assert entry.loc == "https://example.com/legal"
      assert entry.source == :fake_richer_legal
      assert entry.canonical_path == "/legal"
    end
  end
end
