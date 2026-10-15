defmodule PhoenixKit.API.AuthBeforeAuthTest do
  @moduledoc """
  The `:before_auth` hook of `PhoenixKit.API.Auth`: where it runs in the
  order of the checks, what it can refuse, and that a refusal costs no key
  lookup. Plug level, real keys, real rate limiter.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.API.KeyTestSupport, only: [wait_for_window_room: 0]
  import PhoenixKit.Test.ApiHarness

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Problem
  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.AllowedAddresses
  alias PhoenixKit.WebsiteAccess.Gate

  defmodule Hook do
    @moduledoc false

    def note(conn) do
      send(self(), {:hook_called, conn.assigns[:phoenix_kit_api_request_id]})
      conn
    end

    def refuse(conn) do
      send(self(), {:hook_called, conn.assigns[:phoenix_kit_api_request_id]})
      Problem.send(conn, :origin_not_allowed, "Not from here.", %{})
    end

    def crash(_conn), do: raise("hook bug")
    def junk(_conn), do: :not_a_conn
  end

  setup do
    setup_api()
    {owner, _role} = user_with(["dashboard"])
    {_key, token} = issue_key(owner, ["testkit.items:read"])
    %{token: token}
  end

  defp admin(conn, fun),
    do: Auth.call(conn, Auth.init(audience: :admin, before_auth: {Hook, fun}))

  defp public(conn, fun),
    do: Auth.call(conn, Auth.init(audience: :public, before_auth: {Hook, fun}))

  describe "init/1" do
    test "without a hook it returns what it always did" do
      assert [audience: :admin] = Auth.init(audience: :admin)
      assert [audience: :public] = Auth.init(audience: :public)
    end

    test "with a hook it keeps it" do
      assert [audience: :admin, before_auth: {Hook, :note}] =
               Auth.init(audience: :admin, before_auth: {Hook, :note})
    end

    test "refuses a hook that is not {module, function}" do
      for bad <- [:nope, {"Mod", :f}, {Hook, "f"}, {Hook, :f, 1}, nil] do
        assert_raise ArgumentError, fn -> Auth.init(audience: :admin, before_auth: bad) end
      end
    end
  end

  describe "where the hook runs" do
    test "after the request id is assigned, before the key is verified", %{token: token} do
      conn = :post |> api_conn("/", token: token) |> admin(:note)

      assert_received {:hook_called, request_id}
      assert is_binary(request_id)
      refute conn.halted
      assert %Actor{kind: :key} = conn.assigns.phoenix_kit_api_actor
      assert conn.assigns.phoenix_kit_api_request_id == request_id
    end

    test "for the public audience too" do
      conn = :post |> api_conn("/") |> public(:note)

      assert_received {:hook_called, _}
      assert %Actor{kind: :anonymous} = conn.assigns.phoenix_kit_api_actor
    end

    test "not when the API switch is off: the request is a bare 404", %{token: token} do
      switch(:admin, false)
      conn = :post |> api_conn("/", token: token) |> admin(:refuse)

      assert conn.status == 404
      refute_received {:hook_called, _}
    end

    test "not when a credential is in the URL", %{token: token} do
      conn = :post |> api_conn("/?token=abc", token: token) |> admin(:refuse)

      assert conn.status == 400
      assert JSON.decode!(conn.resp_body)["code"] == "token_in_url"
      refute_received {:hook_called, _}
    end

    test "not while the website password gate hides the public API" do
      start_supervised!(
        Supervisor.child_spec({PhoenixKit.Cache, name: :settings}, id: :settings_cache)
      )

      {:ok, _} = Gate.set_password("Secret42")
      {:ok, _} = Gate.set_enabled(true)
      {:ok, _} = Settings.update_setting(AllowedAddresses.key(), "")

      conn = :post |> api_conn("/") |> public(:refuse)

      assert conn.status == 404
      refute_received {:hook_called, _}
    end
  end

  describe "what the hook can do" do
    test "a halted conn ends the request: no key is verified, no actor is assigned", %{
      token: token
    } do
      conn = :post |> api_conn("/", token: token) |> admin(:refuse)

      assert conn.halted
      assert conn.status == 403

      assert %{"code" => "origin_not_allowed", "request_id" => request_id} =
               JSON.decode!(conn.resp_body)

      assert request_id == conn.assigns.phoenix_kit_api_request_id
      refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
    end

    test "a refusal is not charged to the failed-authentication bucket" do
      wait_for_window_room()
      ip = unique_ip()

      for _ <- 1..25 do
        conn = :post |> api_conn("/", token: "pk_00000000_wrong", ip: ip) |> admin(:refuse)
        assert conn.status == 403
      end

      assert :ok = RateLimit.check_preauth(ip)
    end

    test "control: without the hook the same requests do fill the bucket" do
      wait_for_window_room()
      ip = unique_ip()

      for _ <- 1..25 do
        :post
        |> api_conn("/", token: "pk_00000000_wrong", ip: ip)
        |> Auth.call(Auth.init(audience: :admin))
      end

      assert {:error, retry_after} = RateLimit.check_preauth(ip)
      assert retry_after > 0
    end

    test "a hook that raises answers 500 internal_error, authenticates nobody and only its class is logged",
         %{token: token} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:conn, :post |> api_conn("/", token: token) |> admin(:crash)})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      assert JSON.decode!(conn.resp_body)["code"] == "internal_error"
      refute Map.has_key?(conn.assigns, :phoenix_kit_api_actor)
      assert log =~ "raised ** (RuntimeError)"
      refute log =~ "hook bug"
      refute log =~ token
    end

    test "a hook that returns something else than a conn is a 500, not a crash of the request process",
         %{
           token: token
         } do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:conn, :post |> api_conn("/", token: token) |> admin(:junk)})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      assert log =~ "returned an atom"
    end
  end
end
