defmodule PhoenixKitWeb.Plugs.WebsiteAccessTest do
  @moduledoc """
  The browser-pipeline chain: allowed addresses → redirect → gate →
  maintenance, each a no-op when off.
  """
  use PhoenixKit.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Redirect}
  alias PhoenixKitWeb.Plugs.WebsiteAccess, as: AccessPlug

  @gate "/phoenix_kit/access"

  setup do
    Settings.update_boolean_setting(Gate.enabled_key(), false)
    Settings.update_setting(Gate.password_key(), "")
    Settings.update_boolean_setting(Gate.users_pass_key(), true)
    Settings.update_boolean_setting(Redirect.enabled_key(), false)
    Settings.update_setting(Redirect.url_key(), "")
    Settings.update_setting(Redirect.scope_key(), "everyone")
    Settings.update_setting(AllowedAddresses.key(), "")
    Settings.update_boolean_setting("maintenance_enabled", false)
    Settings.update_setting("maintenance_scheduled_start", "")
    Settings.update_setting("maintenance_scheduled_end", "")
    Crawlers.update_no_index(false)
    Gate.clear_attempts()
    :ok
  end

  defp request(method \\ :get, path), do: conn(method, path) |> init_test_session(%{})

  defp run(conn), do: AccessPlug.call(conn, [])

  defp gate_on do
    {:ok, _} = Gate.set_password("Secret42")
    {:ok, _} = Gate.set_enabled(true)
  end

  defp logged_in(conn) do
    email = "gate_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "TestPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    put_session(conn, :user_token, Auth.generate_user_session_token(user))
  end

  test "everything off: nothing happens" do
    conn = request("/about") |> run()
    refute conn.halted
    assert conn.status == nil
  end

  describe "the gate" do
    setup do
      gate_on()
      :ok
    end

    test "a locked session is sent to the gate page with where it was going" do
      conn = request("/about?x=1") |> run()
      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == [@gate <> "?to=%2Fabout%3Fx%3D1"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end

    test "a POST from a locked session is sent to the gate without a return path" do
      conn = request(:post, "/comments") |> run()
      assert conn.status == 302
      assert get_resp_header(conn, "location") == [@gate]
    end

    test "an unlocked session passes" do
      conn = request("/about") |> Gate.unlock() |> run()
      refute conn.halted
    end

    test "a relock locks it again" do
      conn = request("/about") |> Gate.unlock()
      {:ok, _} = Gate.relock_everyone()
      assert run(conn).halted
    end

    test "only the gate's own pages pass; a routed path under /assets/ is a page" do
      for path <- [@gate, @gate <> "/link/abc", @gate <> "/status"] do
        refute request(path) |> run() |> Map.get(:halted), path
      end

      for path <- ["/assets/app.css", "/favicon-admin", "/robots.txt/private"] do
        assert request(path) |> run() |> Map.get(:halted), path
      end
    end

    test "a logged-in user passes and gets stamped; not when the setting is off" do
      conn = request("/about") |> logged_in() |> run()
      refute conn.halted
      assert Gate.unlocked?(conn), "the next request costs nothing"

      {:ok, _} = Gate.set_users_pass(false)
      conn = request("/about") |> logged_in() |> run()
      assert conn.halted
    end

    test "an allowed address passes without a password; the session remembers the address, not an unlock" do
      Settings.update_setting(AllowedAddresses.key(), "203.0.113.7")
      conn = %{request("/about") | remote_ip: {203, 0, 113, 7}} |> run()
      refute conn.halted
      refute Gate.unlocked?(conn), "no global unlock for an address"
      assert get_session(conn, AccessPlug.allowed_session_key()) == "203.0.113.7"

      # the same session from anywhere else is gated again, and forgets the address
      elsewhere = %{request("/about") | remote_ip: {198, 51, 100, 9}}
      elsewhere = put_session(elsewhere, AccessPlug.allowed_session_key(), "203.0.113.7")
      elsewhere = run(elsewhere)
      assert elsewhere.halted
      assert get_session(elsewhere, AccessPlug.allowed_session_key()) == nil

      # the gate's own page is exempt from the chain, not from the bookkeeping
      prompt = %{request(AccessPlug.gate_path()) | remote_ip: {198, 51, 100, 9}}
      prompt = put_session(prompt, AccessPlug.allowed_session_key(), "203.0.113.7")
      prompt = run(prompt)
      refute prompt.halted
      assert get_session(prompt, AccessPlug.allowed_session_key()) == nil
    end

    test "the gate comes before maintenance" do
      {:ok, _} = Maintenance.set_active(true)
      conn = request("/about") |> run()
      assert conn.status == 302, "the maintenance page is behind the gate too"
    end
  end

  describe "the redirect" do
    setup do
      Settings.update_boolean_setting(Redirect.enabled_key(), true)
      Settings.update_setting(Redirect.url_key(), "https://www.prod.example")
      :ok
    end

    test "a public GET is sent to production, same path and query" do
      conn = request("/about?x=1") |> run()
      assert conn.halted
      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["https://www.prod.example/about?x=1"]
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "HEAD too; POST, admin paths and logged-in users stay" do
      assert request(:head, "/about") |> run() |> Map.get(:status) == 302
      refute request(:post, "/about") |> run() |> Map.get(:halted)
      refute request("/phoenix_kit/admin/settings") |> run() |> Map.get(:halted)
      refute request("/about") |> logged_in() |> run() |> Map.get(:halted)
    end

    test "the redirect comes before the gate, so the public never sees the prompt" do
      gate_on()
      conn = request("/about") |> run()
      assert get_resp_header(conn, "location") == ["https://www.prod.example/about"]
    end

    test "a production URL pointing back at this host does not loop, proxy or not" do
      # behind nginx the app sees http on :4000 while the visitor used https
      conn = %{request("/about") | host: "WWW.prod.example", scheme: :http, port: 4000} |> run()
      refute conn.halted

      conn = %{request("/about") | host: "www.prod.example", scheme: :https, port: 443} |> run()
      refute conn.halted
    end

    test "the same host on two explicit ports is two sites" do
      Settings.update_setting(Redirect.url_key(), "http://localhost:4001")
      conn = %{request("/about") | host: "localhost", scheme: :http, port: 4000} |> run()
      assert get_resp_header(conn, "location") == ["http://localhost:4001/about"]

      conn = %{request("/about") | host: "localhost", scheme: :http, port: 4001} |> run()
      refute conn.halted, "same explicit port: a loop"
    end

    test "crawlers only" do
      Settings.update_setting(Redirect.scope_key(), "crawlers")
      refute request("/about") |> run() |> Map.get(:halted)

      bot = request("/about") |> put_req_header("user-agent", "Googlebot/2.1") |> run()
      assert bot.status == 302
    end

    test "an allowed address is not redirected" do
      Settings.update_setting(AllowedAddresses.key(), "203.0.113.7")
      conn = %{request("/about") | remote_ip: {203, 0, 113, 7}} |> run()
      refute conn.halted
    end
  end

  test "the response body is passed through untouched — nothing is injected any more" do
    body = "<html><head></head><body class=\"x\"><p>hi</p></body></html>"

    conn =
      request("/about")
      |> run()
      |> put_resp_content_type("text/html")
      |> send_resp(200, body)

    assert conn.resp_body == body
  end

  # The header rides a before_send callback that the plug registers on two
  # different branches — the allowed-address one and the everyone-else one —
  # and the gate sets the same header itself before halting. Both branches
  # and the overlap, so a rewiring of that callback cannot quietly drop it.
  test "the noindex header rides the allowed-address branch, and the gate's bounce carries it once" do
    Crawlers.update_no_index(true)
    Settings.update_setting(AllowedAddresses.key(), "203.0.113.7")

    conn =
      %{request("/about") | remote_ip: {203, 0, 113, 7}}
      |> run()
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html></html>")

    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"],
           "an allowed address skips the gate, not the header"

    Settings.update_setting(AllowedAddresses.key(), "")
    gate_on()
    conn = request("/about") |> run()

    assert conn.status == 302

    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"],
           "the gate sets it too — one value, not two"
  end

  test "hide from search engines adds the header to every page, a redirect and the closed page too" do
    Crawlers.update_no_index(true)

    conn =
      request("/about")
      |> run()
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html></html>")

    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]

    Settings.update_boolean_setting(Redirect.enabled_key(), true)
    Settings.update_setting(Redirect.url_key(), "https://www.prod.example")
    conn = request("/about") |> run()
    assert conn.status == 302
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    Settings.update_boolean_setting(Redirect.enabled_key(), false)

    {:ok, _} = Maintenance.set_active(true)
    conn = request("/about") |> run()
    assert conn.status == 503
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    {:ok, _} = Maintenance.set_active(false)

    Crawlers.update_no_index(false)

    conn =
      request("/about")
      |> run()
      |> put_resp_content_type("text/html")
      |> send_resp(200, "<html></html>")

    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "maintenance still answers 503 for the public" do
    {:ok, _} = Maintenance.set_active(true)
    conn = request("/about") |> run()
    assert conn.halted
    assert conn.status == 503
  end
end
