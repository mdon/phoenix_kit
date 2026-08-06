defmodule PhoenixKitWeb.CoreOwnedDestinationsTest do
  @moduledoc """
  The invariant this branch exists to establish: **core never sends anyone to a
  path it does not own.**

  Three halves, all database-free:

    * the router-level facts the resolver's safety argument rests on — core does
      NOT route `/` or its locale-prefixed twin, and DOES route the three
      landings the chain can terminate at, in every locale shape;
    * behavioral tests that directly invoke the mount functions of the three
      LiveViews that gate post-auth flow and assert the computed destination
      resolves in a core-only router — the check the static scan cannot perform
      because the destination is stored in a variable before being passed to
      `redirect(to: destination)`;
    * a source-level scan proving no destination site anywhere in `lib/` still
      hardcodes a path with a literal `to: "/"` pattern. Kept as a cheap
      supplementary guard; the behavioral tests above are the primary invariant.

  `PhoenixKitWeb.Router` is a real compiled router that calls
  `phoenix_kit_routes()` (documented as "used only for development and
  testing"), so `Phoenix.Router.route_info/4` against it is the oracle for
  "does core own this path".
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.User, as: AuthUser
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Confirmation
  alias PhoenixKitWeb.Users.ConfirmationInstructions
  alias PhoenixKitWeb.Users.ReferralGate

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

  describe "LiveViews that gate post-auth flow assign routable destinations" do
    # The static scan below proves no *literal* `to: "/"` or
    # `to: Routes.path("/")` exists. These behavioral tests close the gap the
    # scan cannot see: a destination computed into a variable and then passed
    # to `redirect(to: destination)`.
    #
    # All three LiveViews call `Routes.post_auth_path/2` in `mount/3`. Without
    # `:context` that call silently returns `"/"` on any host that does not
    # declare a root route — exactly the configuration this branch handles.
    #
    # Each mount is called directly with a socket whose router is
    # `PhoenixKitWeb.Router` (which does not declare `"/"`). No database is
    # needed: none of the three mounts issue a DB query for the anonymous /
    # access-satisfied scenarios exercised here.

    defp lv_socket do
      %Phoenix.LiveView.Socket{
        router: @router,
        host_uri: URI.parse("http://localhost"),
        assigns: %{__changed__: %{}}
      }
    end

    test "Confirmation.mount assigns a destination that resolves" do
      # Anonymous mount with a probe token; `destination` is computed from
      # params/session and stored in assigns. The token's validity is irrelevant
      # here — the DB check only happens in `handle_event("confirm_account", ...)`.
      params = %{"token" => "probe_token"}

      {:ok, socket, _opts} =
        Confirmation.mount(params, %{}, lv_socket())

      destination = socket.assigns.destination

      assert resolves?(destination),
             "Confirmation.mount assigned unroutable destination #{inspect(destination)}"
    end

    test "ConfirmationInstructions.mount assigns a destination that resolves" do
      # Anonymous mount (no user in assigns): takes the `is_nil(user)` cond branch,
      # assigns `destination:` without touching the database.
      {:ok, socket} =
        ConfirmationInstructions.mount(%{}, %{}, lv_socket())

      destination = socket.assigns.destination

      assert resolves?(destination),
             "ConfirmationInstructions.mount assigned unroutable destination #{inspect(destination)}"
    end

    test "ReferralGate.mount redirects to a destination that resolves" do
      # With `referral_codes_required` unset (default false / no DB),
      # `Referrals.access_satisfied?/1` short-circuits to `true` without reading
      # any user fields, so mount takes the second cond branch and redirects to
      # `destination`. The redirect target is extracted from `socket.redirected`.
      user = %AuthUser{uuid: Ecto.UUID.generate(), email: "probe@example.com"}

      socket_with_user =
        Map.update!(lv_socket(), :assigns, &Map.put(&1, :phoenix_kit_current_user, user))

      {:ok, result} = ReferralGate.mount(%{}, %{}, socket_with_user)

      {:redirect, %{to: destination}} = result.redirected

      assert resolves?(destination),
             "ReferralGate.mount redirected to unroutable destination #{inspect(destination)}"
    end
  end

  describe "no destination site hardcodes an unowned path" do
    # Supplementary cheap guard: catches *literal* `to: "/"` patterns before
    # they are committed. The behavioral tests above are the primary invariant —
    # they catch the variable-destination pattern this scan cannot see.
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
