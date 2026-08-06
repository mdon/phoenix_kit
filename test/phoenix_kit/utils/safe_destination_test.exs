defmodule PhoenixKit.Utils.SafeDestinationTest do
  @moduledoc """
  Unit coverage for `Routes.safe_destination/2`, `Routes.routable?/2` and
  `Routes.main_page_path/0`.

  Deliberately plain `ExUnit.Case`: `PhoenixKit.DataCase` / `ConnCase` stamp
  `@moduletag :integration`, which auto-excludes them when no PostgreSQL is
  reachable — exactly the runs where this file is most valuable. Nothing here
  needs a database: `Scope` structs are built by hand, routers are compiled
  inline, and settings reads fall back to their supplied default when the DB is
  unreachable.
  """
  use ExUnit.Case, async: true

  # The chain reads settings (`main_page_path`, `after_login_path`). With no
  # database that short-circuits to nil and this file needs nothing; with one
  # reachable it becomes a real query from a process owning no sandbox
  # connection, which raises rather than returning a miss.
  #
  # `test_repo_available` is the flag test_helper.exs already sets. The repo
  # PROCESS starts even with no database — only its connections fail — so
  # `Process.whereis/1` answers the wrong question and made every test here hang
  # on a checkout that could never succeed.
  setup do
    if Application.get_env(:phoenix_kit, :test_repo_available, false) do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(PhoenixKit.Test.Repo)
    end

    :ok
  end

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  # `after_login_path` and `main_page_path` sit at the TAIL of their chains, so
  # most assertions never reach them; the ones that exhaust the chain read an
  # unset setting and get `nil`. Both hold with no database.

  # Never dispatched — `routable?/2` only asks the router whether a route
  # matches, so the plug just has to exist.
  defmodule FakeController do
    def init(opts), do: opts
    def call(conn, _opts), do: conn
  end

  defmodule HostRouter do
    use Phoenix.Router

    get "/", PhoenixKit.Utils.SafeDestinationTest.FakeController, :home
    get "/shop", PhoenixKit.Utils.SafeDestinationTest.FakeController, :shop
  end

  defmodule EmptyRouter do
    use Phoenix.Router
  end

  # The real core router — mounts `phoenix_kit_routes()`, so it is the oracle
  # for "does core own this path".
  @core PhoenixKitWeb.Router

  defp conn_for(router, host \\ "localhost") do
    %Plug.Conn{private: %{phoenix_router: router}, host: host}
  end

  defp socket_for(router) do
    %Phoenix.LiveView.Socket{router: router, host_uri: URI.parse("http://localhost")}
  end

  defp anonymous, do: Scope.for_user(nil)

  defp scope(roles, permissions \\ []) do
    %Scope{
      user: nil,
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  defp owner, do: scope(["Owner"])
  defp admin, do: scope(["Admin"])
  # A Client is a plain User who holds `client_portal` — they pass
  # `can_access_admin_area?/1` and the host routes them onward from `/admin`.
  defp client, do: scope(["User"], ["client_portal"])
  defp plain_user, do: scope(["User"])

  describe "routable?/2" do
    test "reads the router off a conn" do
      assert Routes.routable?(conn_for(HostRouter), "/shop")
      refute Routes.routable?(conn_for(HostRouter), "/nope")
    end

    test "reads the router off a socket" do
      assert Routes.routable?(socket_for(HostRouter), "/shop")
      refute Routes.routable?(socket_for(HostRouter), "/nope")
    end

    test "strips query and fragment before probing segments" do
      assert Routes.routable?(conn_for(HostRouter), "/shop?tab=1")
      assert Routes.routable?(conn_for(HostRouter), "/shop#top")
    end

    test "fails closed when the router cannot be determined" do
      refute Routes.routable?(nil, "/shop")
      refute Routes.routable?(%Plug.Conn{private: %{}, host: "localhost"}, "/shop")
      refute Routes.routable?(%Phoenix.LiveView.Socket{}, "/shop")
    end

    test "fails closed on a non-binary path" do
      refute Routes.routable?(conn_for(HostRouter), nil)
      refute Routes.routable?(conn_for(HostRouter), :shop)
    end

    test "core routes its own landings but not the locale-prefixed root" do
      assert Routes.routable?(conn_for(@core), Routes.path("/dashboard"))
      assert Routes.routable?(conn_for(@core), Routes.path("/users/log-in"))
      assert Routes.routable?(conn_for(@core), Routes.path("/admin"))

      # The shipped bug, at the router level.
      refute Routes.routable?(conn_for(@core), Routes.path("/"))
      refute Routes.routable?(conn_for(@core), "/")
    end
  end

  describe "safe_destination/2 — authenticated" do
    test "an admin-area visitor lands on /admin" do
      for s <- [owner(), admin(), client()] do
        assert Scope.can_access_admin_area?(s)
        assert Routes.safe_destination(conn_for(@core), scope: s) == Routes.path("/admin")
      end
    end

    test "a plain user lands on /dashboard" do
      refute Scope.can_access_admin_area?(plain_user())

      assert Routes.safe_destination(conn_for(@core), scope: plain_user()) ==
               Routes.path("/dashboard")
    end

    test "an explicit return_to wins over the role branch" do
      assert Routes.safe_destination(conn_for(@core),
               scope: owner(),
               return_to: Routes.path("/dashboard")
             ) == Routes.path("/dashboard")
    end

    test "a return_to keeps its query string" do
      target = Routes.path("/dashboard") <> "?tab=1"

      assert Routes.safe_destination(conn_for(@core), scope: owner(), return_to: target) == target
    end

    test "an unroutable return_to is skipped, not served" do
      assert Routes.safe_destination(conn_for(@core), scope: owner(), return_to: "/no/such/page") ==
               Routes.path("/admin")
    end

    test "skip_admin suppresses the /admin step — the admin-area guard case" do
      result = Routes.safe_destination(conn_for(@core), scope: owner(), skip_admin: true)

      assert result == Routes.path("/dashboard")
      refute result =~ "/admin"
    end

    test "skip_admin is a no-op for a non-admin" do
      assert Routes.safe_destination(conn_for(@core), scope: plain_user(), skip_admin: true) ==
               Routes.path("/dashboard")
    end

    test "the host's own \"/\" is used when the host actually declares it" do
      # HostRouter routes `/` and nothing core owns, so every earlier candidate
      # is skipped and the home page — the destination these sites had before
      # this branch — is still reached.
      assert Routes.safe_destination(conn_for(HostRouter), scope: owner()) == "/"
      assert Routes.safe_destination(conn_for(HostRouter), scope: plain_user()) == "/"
    end

    test "falls back to the core-owned terminal when nothing else resolves" do
      # EmptyRouter has no routes at all — not even `/` — so every candidate is
      # skipped.
      #
      # `EmptyRouter` never called `phoenix_kit_routes()`, so core's own landings
      # do not resolve there either. The terminal is PROBED, so it does not hand
      # back a path this router cannot serve — it exhausts every arm, logs the
      # misconfiguration, and returns the last one.
      #
      # This used to assert `/admin` came back, which pinned the defect the
      # probe removed: a router without that route was handed it regardless.
      refute Routes.safe_destination(conn_for(EmptyRouter), scope: owner()) ==
               Routes.path("/admin")

      # Not `/dashboard` either, and this is the case that matters most: a host
      # setting `user_dashboard_enabled: false` compiles that route out, and the
      # unprobed terminal used to hand it back anyway. `EmptyRouter` stands in
      # for any router that does not declare it.
      refute Routes.safe_destination(conn_for(EmptyRouter), scope: plain_user()) ==
               Routes.path("/dashboard")

      # Whatever comes back, it is never an auth page for a signed-in visitor:
      # that page bounces them out through `post_auth_path/2`, which re-enters
      # the resolver, so it is a loop rather than a fallback.
      for s <- [owner(), plain_user()] do
        refute Routes.auth_page?(Routes.safe_destination(conn_for(EmptyRouter), scope: s))
      end
    end

    test "an undeterminable router falls through to the last arm, not to a dead core path" do
      # `routable?/2` fails closed with no router, so no arm can be proven — the
      # resolver logs and returns its last one rather than asserting a core path
      # it cannot verify.
      for s <- [plain_user(), owner()] do
        result = Routes.safe_destination(nil, scope: s)

        refute result == Routes.path("/dashboard")
        refute result == Routes.path("/admin")
        refute Routes.auth_page?(result)
      end
    end

    test "no authenticated input terminates on an auth page" do
      for ctx <- [nil, conn_for(EmptyRouter), conn_for(@core), conn_for(HostRouter)],
          s <- [owner(), admin(), client(), plain_user()],
          skip <- [true, false] do
        result = Routes.safe_destination(ctx, scope: s, skip_admin: skip)

        refute Routes.auth_page?(result),
               "authenticated visitor sent to #{result} (skip_admin=#{skip})"
      end
    end
  end

  describe "safe_destination/2 — anonymous" do
    test "no scope and an anonymous scope behave identically" do
      # `Scope.for_user(nil)` is a STRUCT, not nil — testing `is_nil` instead of
      # `Scope.authenticated?/1` would route it down the authenticated chain.
      assert Routes.safe_destination(conn_for(@core), scope: nil) ==
               Routes.path("/users/log-in")

      assert Routes.safe_destination(conn_for(@core), scope: anonymous()) ==
               Routes.path("/users/log-in")

      assert Routes.safe_destination(conn_for(@core)) == Routes.path("/users/log-in")
    end

    test "return_to is ignored for an anonymous visitor" do
      assert Routes.safe_destination(conn_for(@core),
               scope: nil,
               return_to: Routes.path("/dashboard")
             ) == Routes.path("/users/log-in")
    end

    test "never selects the locale-prefixed root" do
      refute Routes.safe_destination(conn_for(@core), scope: nil) == Routes.path("/")
      refute Routes.safe_destination(conn_for(@core), scope: nil) == "/"
    end

    test "lands on the site home when the host declares one" do
      # The pre-branch behaviour for a logged-out visitor, restored: `/` is a
      # candidate like any other, selected exactly where it resolves.
      assert Routes.safe_destination(conn_for(HostRouter), scope: nil) == "/"
      assert Routes.safe_destination(socket_for(HostRouter), scope: anonymous()) == "/"
    end
  end

  describe "open-redirect guard" do
    @hostile [
      "https://evil.example",
      "//evil.example",
      "/\\evil.example",
      "/\t/evil.example",
      "/ok\r\nX-Injected: 1",
      "evil.example",
      "",
      nil,
      :not_a_path
    ]

    test "a hostile return_to never survives the chain" do
      for candidate <- @hostile, s <- [owner(), plain_user()] do
        result = Routes.safe_destination(conn_for(@core), scope: s, return_to: candidate)

        refute result == candidate
        assert Routes.local_path?(result)
      end
    end

    test "an auth page is never selected as a return_to" do
      for candidate <- ["/users/log-out", "/et/users/register/", "/users/log-in"] do
        result = Routes.safe_destination(conn_for(@core), scope: owner(), return_to: candidate)
        refute result == candidate
      end
    end
  end

  describe "main_page_path/0" do
    test "is nil when the setting is unset (no database in this suite)" do
      assert Routes.main_page_path() == nil
    end
  end

  describe "THE INVARIANT" do
    # Stated as what is actually guaranteed, which is NOT "never `/`": `/` is a
    # legitimate destination on a host that declares one, and refusing it there
    # would regress every install that never had the locale-prefixed-root bug.
    # What core promises is that it never emits a path nobody has shown to
    # exist — every result is either PROVEN routable in the caller's own router
    # or one of the three landings core declares itself.
    test "every result is either proven routable or a core-owned terminal" do
      scopes = [nil, anonymous(), owner(), admin(), client(), plain_user()]
      return_tos = [nil, "/shop", "https://evil.example", "//evil", "/\t/evil", "/users/log-out"]

      contexts = [
        nil,
        conn_for(@core),
        socket_for(@core),
        conn_for(HostRouter),
        conn_for(EmptyRouter)
      ]

      # `EmptyRouter` declares nothing at all, so on it every arm of the
      # terminal legitimately fails to resolve and the resolver logs and returns
      # the last one. That host cannot be served by anything; it is kept in the
      # matrix to prove the resolver does not crash there, and excluded from the
      # routability assertion below by asking the router, not by naming paths.
      routerless = fn ctx -> not Routes.routable?(ctx, Routes.path("/users/log-in")) end

      for s <- scopes, rt <- return_tos, skip <- [true, false], ctx <- contexts do
        result = Routes.safe_destination(ctx, scope: s, return_to: rt, skip_admin: skip)

        context = "scope=#{inspect(s && s.cached_roles)} return_to=#{inspect(rt)} skip=#{skip}"

        assert Routes.local_path?(result), context
        # The locale-prefixed root — the shipped bug — is never synthesized.
        refute result == Routes.path("/"), context

        # A bare `/` only ever comes back from a router that declares it — or
        # from a host where NOTHING core owns resolves, which is the logged
        # degenerate case the terminal probe surfaces rather than papering over.
        if result == "/" and not routerless.(ctx) do
          assert Routes.routable?(ctx, "/"), context
        end

        # An auth page is only ever the ANONYMOUS terminal; sending a signed-in
        # visitor there just bounces them off it again.
        if Routes.auth_page?(result) do
          assert result == Routes.path("/users/log-in"), context
          refute Scope.authenticated?(s), context
        end

        # No waiver for terminals. They used to be exempt here, which is exactly
        # why an unroutable `/dashboard` terminal passed this test while 404ing
        # in production. The only exemption is a host that declares no routes at
        # all, and it is decided by asking the router.
        unless routerless.(ctx) do
          assert Routes.routable?(ctx, result),
                 "unroutable destination #{inspect(result)} for #{context}"
        end
      end
    end
  end
end
