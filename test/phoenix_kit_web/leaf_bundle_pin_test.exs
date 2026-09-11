defmodule PhoenixKitWeb.LeafBundlePinTest do
  @moduledoc """
  Holds the Leaf CDN pin and the Leaf dependency together.

  phoenix_kit.js lazy-loads Leaf's editor bundle from a pinned jsdelivr tag,
  while mix.exs resolves the Elixir half from Hex. The two halves are one
  contract: a bundle left behind renders an identical editor while quietly not
  implementing what the server now expects — no error, just events that never
  arrive. The comment at the pin cited this test for years before it existed;
  now it does.
  """
  use ExUnit.Case, async: true

  @bundle Path.join([__DIR__, "..", "..", "priv", "static", "assets", "phoenix_kit.js"])

  defp pinned_version do
    contents = File.read!(@bundle)

    case Regex.run(~r{cdn\.jsdelivr\.net/gh/[^/]+/leaf@v([0-9]+\.[0-9]+\.[0-9]+)/}, contents) do
      [_, version] -> version
      nil -> flunk("no leaf@vX.Y.Z pin found in #{@bundle}")
    end
  end

  defp locked_version do
    case File.read!(Path.join([__DIR__, "..", "..", "mix.lock"]))
         |> then(&Regex.run(~r/"leaf": \{:hex, :leaf, "([0-9]+\.[0-9]+\.[0-9]+)"/, &1)) do
      [_, version] -> version
      nil -> flunk("leaf is not locked in mix.lock")
    end
  end

  test "the CDN pin is the version the Elixir half is locked to" do
    assert pinned_version() == locked_version(),
           """
           priv/static/assets/phoenix_kit.js pins leaf@v#{pinned_version()} while \
           mix.lock resolves leaf #{locked_version()}. Browsers would run one \
           version of the editor against the other version's server half. \
           Update the LEAF_CDN constant and the lock together.
           """
  end

  test "the pinned version is one mix.exs permits" do
    assert Version.match?(pinned_version(), requirement()),
           "the pin (#{pinned_version()}) falls outside the mix.exs requirement (#{requirement()})"
  end

  test "mix.exs does not admit a leaf minor the bundle cannot serve" do
    # The floor half of this contract is easy and was always right. The
    # ceiling is the half that bites: `~> 0.5` reads as "the 0.5 line" but
    # means `>= 0.5.0 and < 1.0.0`, so a single patch-less alternative
    # silently admits every later 0.x and makes the enumeration after it
    # inert. A host is then free to resolve leaf past the tag
    # `priv/static/assets/phoenix_kit.js` serves, which is the cross-version
    # editor the pin exists to prevent — and neither the test above nor
    # `vendored_cdn_pins_test.exs` can see it, because both only ever look at
    # the version THIS project resolved.
    %Version{major: major, minor: minor} = Version.parse!(pinned_version())
    next_minor = "#{major}.#{minor + 1}.0"

    refute Version.match?(next_minor, requirement()),
           """
           mix.exs permits leaf #{next_minor}, but the browser half is frozen \
           at leaf@v#{pinned_version()} in priv/static/assets/phoenix_kit.js. \
           A host resolving #{next_minor} would run that bundle against a \
           newer server half — silently, since the editor still renders.

           Give every alternative in the requirement a patch segment \
           (`~> 0.8.0`, not `~> 0.8`) so the ceiling stops at the pinned \
           minor, and move the pin, the lock and the requirement together.
           """
  end

  defp requirement do
    File.read!(Path.join([__DIR__, "..", "..", "mix.exs"]))
    |> then(&Regex.run(~r/\{:leaf, "([^"]+)"/, &1))
    |> case do
      [_, req] -> req
      nil -> flunk("no :leaf requirement found in mix.exs")
    end
  end
end
