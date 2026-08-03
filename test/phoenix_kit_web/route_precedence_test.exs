defmodule PhoenixKitWeb.RoutePrecedenceTest do
  @moduledoc """
  Guards the declaration order of the PhoenixKit LiveView surfaces.

  `:locale` is an ordinary path segment. Phoenix.Router has no segment
  constraints — `Phoenix.Router.Scope.push/2` reads only :path, :alias,
  :as, :host, :private, :assigns, :log and :trailing_slash, and silently
  discards anything else — so a `locale: ~r/.../` option on a scope looks
  like a guard, compiles without a warning, and does nothing. The public
  surface therefore contains routes of the shape `/<prefix>/:locale/<lit>`
  that match ANY first segment.

  While the public surface was emitted before the admin one, a module that
  put a public page at `/shop` and its admin page at `/admin/shop` (which
  `phoenix_kit_ecommerce` does) had its admin page swallowed:
  `/<prefix>/admin/shop` bound to `/<prefix>/:locale/shop` with
  `locale = "admin"`. Root-mounted installs were bounced to the public
  storefront; prefixed installs redirected to themselves forever.

  These tests pin the fix from both directions — the mechanism in
  isolation, and the invariant on the real router.
  """
  use ExUnit.Case, async: true

  defmodule DummyController do
    @moduledoc false
    use Phoenix.Controller, formats: []
    def admin_shop(conn, _), do: conn
    def public_shop(conn, _), do: conn
  end

  # The fixed order: the literal-segment admin route is declared first.
  defmodule AdminFirstRouter do
    @moduledoc false
    use Phoenix.Router

    scope "/phoenix_kit" do
      get "/admin/shop", DummyController, :admin_shop
    end

    scope "/phoenix_kit/:locale" do
      get "/shop", DummyController, :public_shop
    end
  end

  # The broken order that shipped. Kept so the failure mode is executable
  # rather than folklore: if someone "tidies" the emission order in
  # `PhoenixKitWeb.Integration.phoenix_kit_routes/0`, the contrast between
  # these two routers is the explanation.
  defmodule PublicFirstRouter do
    @moduledoc false
    use Phoenix.Router

    scope "/phoenix_kit/:locale" do
      get "/shop", DummyController, :public_shop
    end

    scope "/phoenix_kit" do
      get "/admin/shop", DummyController, :admin_shop
    end
  end

  defp info(router, path), do: Phoenix.Router.route_info(router, "GET", path, "localhost")

  describe "the mechanism, in isolation" do
    test "a bogus :locale scope constraint is accepted and ignored by Phoenix" do
      # If Phoenix ever grows real segment constraints this test fails and
      # the whole workaround can be revisited. Until then: `:locale`
      # matches "admin" just as happily as it matches "en".
      assert %{path_params: %{"locale" => "admin"}} =
               info(PublicFirstRouter, "/phoenix_kit/admin/shop")
    end

    test "admin-first: the literal route wins over the same-arity :locale route" do
      assert %{plug_opts: :admin_shop} = info(AdminFirstRouter, "/phoenix_kit/admin/shop")
    end

    test "admin-first does not steal genuinely localized public URLs" do
      assert %{plug_opts: :public_shop, path_params: %{"locale" => "en"}} =
               info(AdminFirstRouter, "/phoenix_kit/en/shop")

      assert %{plug_opts: :public_shop, path_params: %{"locale" => "et"}} =
               info(AdminFirstRouter, "/phoenix_kit/et/shop")
    end

    test "public-first: reproduces the original bug" do
      assert %{plug_opts: :public_shop} = info(PublicFirstRouter, "/phoenix_kit/admin/shop")
    end
  end

  describe "the real router" do
    defp live_session_name(route) do
      case route.metadata[:phoenix_live_view] do
        {_view, _action, _opts, %{name: name}} -> name
        _ -> nil
      end
    end

    defp first_index_of_session(routes, session) do
      Enum.find_index(routes, &(live_session_name(&1) == session))
    end

    test "the admin surface is declared before the public surface" do
      routes = PhoenixKitWeb.Router.__routes__()

      admin_at = first_index_of_session(routes, :phoenix_kit_admin)
      public_at = first_index_of_session(routes, :phoenix_kit_public)

      assert is_integer(admin_at), "no :phoenix_kit_admin live_session routes found"
      assert is_integer(public_at), "no :phoenix_kit_public live_session routes found"

      assert admin_at < public_at, """
      The admin LiveView surface must be emitted BEFORE the public one in
      PhoenixKitWeb.Integration.phoenix_kit_routes/0.

      The public surface owns `/<prefix>/:locale/<literal>` routes, and
      `:locale` matches any segment — so with public first, admin pages
      whose first path segment collides with a public page's name become
      unreachable. See this module's @moduledoc.

        first admin route:  index #{admin_at}
        first public route: index #{public_at}
      """
    end

    test "no fully-literal route is shadowed by an earlier route" do
      routes = PhoenixKitWeb.Router.__routes__()

      literal? = fn path ->
        path
        |> String.split("/", trim: true)
        |> Enum.all?(&(not String.starts_with?(&1, [":", "*"])))
      end

      shadowed =
        for route <- routes,
            route.verb == :get,
            literal?.(route.path),
            resolved =
              Phoenix.Router.route_info(PhoenixKitWeb.Router, "GET", route.path, "localhost"),
            is_map(resolved),
            resolved.route != route.path do
          {route.path, resolved.route, resolved.path_params}
        end

      assert shadowed == [], """
      These declared routes do not resolve to themselves — an earlier
      route is swallowing them:

      #{Enum.map_join(shadowed, "\n", fn {declared, actual, params} -> "  #{declared}\n    -> #{actual}  #{inspect(params)}" end)}
      """
    end
  end
end
