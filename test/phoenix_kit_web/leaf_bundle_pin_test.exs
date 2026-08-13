defmodule PhoenixKitWeb.LeafBundlePinTest do
  @moduledoc """
  The editor's JavaScript is fetched from a CDN tag; its Elixir half comes
  from hex. Nothing makes the two agree except the string in `phoenix_kit.js`.

  They drifted two minor versions apart — hex resolved leaf 0.5.1 while the
  tag still served v0.3.2 — and nothing said so. Almost everything leaf adds
  is a server<->client contract, so a stale bundle renders an identical
  editor and just stops implementing what the server now expects: no
  `{:leaf_flushed, ...}` reply for a host awaiting a save before it
  navigates, no dirty re-baseline, atomic blocks with no styling.

  Leaf carries its own guard against exactly this — it renders
  `data-leaf-js-version` and the bundle warns when the two disagree — but a
  bundle old enough to matter predates the guard and cannot fire it. That is
  the shape of the problem: the further behind the pin falls, the quieter it
  gets. So the check belongs here, where the pin is written.
  """
  use ExUnit.Case, async: true

  @bundle Path.join(__DIR__, "../../priv/static/assets/phoenix_kit.js")
  @pin ~r{cdn\.jsdelivr\.net/gh/alexdont/leaf@([^/]+)/priv/static/assets/leaf\.js}

  defp pins do
    @bundle |> File.read!() |> then(&Regex.scan(@pin, &1)) |> Enum.map(fn [_, tag] -> tag end)
  end

  test "the CDN tag names the leaf release that hex resolved" do
    resolved = to_string(Application.spec(:leaf, :vsn))

    assert [tag] = pins()

    assert tag == "v#{resolved}",
           """
           The leaf editor bundle is pinned to #{tag}, but this project resolves \
           leaf #{resolved}.

           Update LEAF_CDN in priv/static/assets/phoenix_kit.js to \
           v#{resolved}. A mismatch is silent: the editor renders normally and \
           quietly stops honouring the parts of the API the server has moved on to.
           """
  end

  test "there is one pin to keep in step" do
    # A second copy of the URL is a second thing to remember, and the one that
    # gets forgotten is by definition the one no test named.
    assert length(pins()) == 1,
           "expected exactly one leaf CDN pin, found #{length(pins())}"
  end

  test "the loader still keys off the version the bundle publishes" do
    # `window.LeafHooks.version` is what leaf's own stale-bundle warning
    # compares against `data-leaf-js-version`. Fetching a bundle that predates
    # it disables that warning, which is why this test exists rather than
    # relying on the console.
    js = File.read!(@bundle)

    assert js =~ "window.LeafHooks && window.LeafHooks.Leaf",
           "the lazy loader no longer probes LeafHooks; the pin check may be guarding nothing"
  end
end
