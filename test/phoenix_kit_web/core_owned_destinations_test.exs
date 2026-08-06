defmodule PhoenixKitWeb.CoreOwnedDestinationsTest do
  @moduledoc """
  The invariant this branch exists to establish: **core never sends anyone to a
  path it does not own.**

  Two halves, both database-free:

    * the router-level facts the resolver's safety argument rests on — core does
      NOT route `/` or its locale-prefixed twin, and DOES route the three
      landings the chain can terminate at, in every locale shape;
    * a source-level scan proving no destination site anywhere in `lib/` still
      hardcodes one. A per-site behavioural test would need a live conn per
      site; this catches the same regression, catches a *new* site added later,
      and runs on a clean checkout.

  `PhoenixKitWeb.Router` is a real compiled router that calls
  `phoenix_kit_routes()` (documented as "used only for development and
  testing"), so `Phoenix.Router.route_info/4` against it is the oracle for
  "does core own this path".
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Routes

  @router PhoenixKitWeb.Router

  defp resolves?(path) do
    Phoenix.Router.route_info(@router, "GET", path, "localhost") != :error
  end

  describe "what core does and does not route" do
    test "core does not route \"/\" — the premise of this whole branch" do
      refute resolves?("/")
    end

    test "core does not route the locale-prefixed root either — the shipped bug" do
      # `Routes.path("/")` emits `/phoenix_kit/en`. Nine call sites used to send
      # users there; the route belongs to the host, which may never have
      # declared it.
      refute resolves?(Routes.path("/"))
    end

    test "every path the resolver can terminate at resolves, in every locale shape" do
      for landing <- ["/admin", "/dashboard", "/users/log-in"],
          locale <- [nil, :none, "en", "de", "ru", "en-GB"] do
        path = Routes.path(landing, locale: locale)

        assert resolves?(path),
               "#{landing} with locale #{inspect(locale)} emitted #{path}, which does not resolve"
      end
    end
  end

  describe "no destination site hardcodes an unowned path" do
    # Kept deliberately narrow so the moduledoc/comment prose that *mentions*
    # these shapes (in `Routes`, and in this file) is not matched: only an
    # actual redirect target has `to:` in front of it.
    @hardcoded_root ~r/to:\s*"\/"/
    @locale_root ~r/to:\s*Routes\.path\("\/"\)/

    test "lib/ contains no `to: \"/\"` and no `to: Routes.path(\"/\")`" do
      offenders =
        Path.wildcard("lib/**/*.ex")
        |> Enum.flat_map(fn file ->
          source = File.read!(file)

          cond do
            Regex.match?(@locale_root, source) -> [{file, "to: Routes.path(\"/\")"}]
            Regex.match?(@hardcoded_root, source) -> [{file, "to: \"/\""}]
            true -> []
          end
        end)

      assert offenders == [],
             """
             These files still send a visitor to a path core does not own:

               #{Enum.map_join(offenders, "\n  ", fn {f, pat} -> "#{f} — #{pat}" end)}

             `Routes.path("/")` emits a locale-prefixed root (`/en`) and a bare
             `"/"` is the host's home page; core declares neither. Resolve the
             destination with `Routes.safe_destination/2` instead.
             """
    end
  end
end
