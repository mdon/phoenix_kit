defmodule PhoenixKitWeb.WebsiteAccessControllerTest do
  @moduledoc "The gate's pages, through the router."
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.Gate

  @gate "/phoenix_kit/access"

  setup %{conn: conn} do
    Settings.update_boolean_setting(Gate.enabled_key(), false)
    Settings.update_setting(Gate.password_key(), "")
    Settings.update_setting(Gate.link_key(), "")
    Settings.update_setting(Gate.lockout_attempts_key(), "0")
    Settings.update_boolean_setting(Gate.users_pass_key(), true)
    Settings.update_setting(Gate.keep_typed_key(), "all")
    Gate.clear_attempts()
    {:ok, conn: init_test_session(conn, %{})}
  end

  defp gate_on do
    {:ok, _} = Gate.set_password("Secret42")
    {:ok, _} = Gate.set_enabled(true)
  end

  test "gate off: the page sends the visitor home", %{conn: conn} do
    conn = get(conn, @gate)
    assert redirected_to(conn) == "/"
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    assert redirected_to(post(conn, @gate, %{"password" => "x"})) == "/"
  end

  describe "the prompt" do
    setup do
      gate_on()
      :ok
    end

    test "is a blank page with one password field", %{conn: conn} do
      conn = get(conn, @gate <> "?to=%2Fabout")
      assert conn.status == 200
      body = html_response(conn, 200)
      assert body =~ ~s(type="password")
      assert body =~ ~s(autocomplete="off")
      assert body =~ ~s(name="to" value="/about")
      assert body =~ ~s(<meta name="robots" content="noindex, nofollow")
      assert body =~ "body{display:flex", "the inline stylesheet is rendered, not escaped"
      refute body =~ "{@style}"
      refute body =~ "log in"
      refute body =~ "PhoenixKit"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "a return path must be a path on this site", %{conn: conn} do
      for bad <- [
            "//evil.example/x",
            "https://evil.example",
            "/\\evil.example",
            "/x\r\nSet-Cookie: a=b",
            "/x y",
            "evil"
          ] do
        assert html_response(get(conn, @gate <> "?to=" <> URI.encode_www_form(bad)), 200) =~
                 ~s(name="to" value="/"),
               bad
      end

      assert html_response(get(conn, @gate <> "?to=%2Fabout%3Fx%3D1"), 200) =~
               ~s(name="to" value="/about?x=1")
    end

    test "a return path naming the gate itself goes home, not round in a circle", %{conn: conn} do
      conn = conn |> init_test_session(%{}) |> Gate.unlock()
      assert redirected_to(get(conn, @gate <> "?to=" <> @gate)) == "/"
      assert redirected_to(get(conn, @gate <> "?to=" <> @gate <> "%3Fto%3D%2Fx")) == "/"
      assert redirected_to(get(conn, @gate <> "?to=" <> @gate <> "%2Fstatus")) == "/"
      assert redirected_to(get(conn, @gate <> "?to=" <> @gate <> "%23again")) == "/"
      assert redirected_to(get(conn, @gate <> "?to=%2Fx%2F..%2Fphoenix_kit%2Faccess")) == "/"
      assert redirected_to(get(conn, @gate <> "?to=%2Faccessible")) == "/accessible"
      assert redirected_to(get(conn, @gate <> "?to=%2Fabout%3Fq%3D1")) == "/about?q=1"
    end

    test "a crafted return path after the right password goes home, never off-site", %{conn: conn} do
      conn = post(conn, @gate, %{"password" => "Secret42", "to" => "/\\evil.example"})
      assert redirected_to(conn) == "/"
    end

    test "junk bytes in the user agent are recorded, not a crash", %{conn: conn} do
      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 \xff\xfe junk")
        |> post(@gate, %{"password" => "SECRET42"})

      assert redirected_to(conn) =~ @gate
      assert [%{verdict: "case", user_agent: ua}] = Gate.list_attempts()
      assert String.valid?(ua)
      assert ua =~ "junk"
    end

    test "wrong: back to the prompt with a word, the try recorded", %{conn: conn} do
      conn = post(conn, @gate, %{"password" => "SECRET42", "to" => "/about"})
      assert redirected_to(conn) == @gate <> "?to=%2Fabout"

      body = conn |> recycle() |> get(@gate <> "?to=%2Fabout") |> html_response(200)
      assert body =~ "That is not it."

      assert [%{verdict: "case", typed: "SECRET42"}] = Gate.list_attempts()
    end

    test "a map-shaped password is no password, not a 500", %{conn: conn} do
      conn = post(conn, @gate, %{"password" => %{"x" => "y"}})
      assert redirected_to(conn) == @gate
      assert [%{verdict: "empty"}] = Gate.list_attempts()
    end

    test "empty is its own word", %{conn: conn} do
      conn = post(conn, @gate, %{"password" => ""})
      body = conn |> recycle() |> get(@gate) |> html_response(200)
      assert body =~ "Type the password."
      assert [%{verdict: "empty"}] = Gate.list_attempts()
    end

    test "right: the session is unlocked and the visitor goes where they were going", %{
      conn: conn
    } do
      conn = post(conn, @gate, %{"password" => "Secret42", "to" => "/about?x=1"})
      assert redirected_to(conn) == "/about?x=1"
      assert Gate.unlocked?(conn)
      assert [%{verdict: "correct", typed: "Secret42"}] = Gate.list_attempts()

      assert redirected_to(conn |> recycle() |> get(@gate <> "?to=%2Fsomewhere")) == "/somewhere"
    end

    test "lockout: the door closes and a try while locked is recorded, not judged", %{conn: conn} do
      Settings.update_setting(Gate.lockout_attempts_key(), "2")
      Settings.update_setting(Gate.lockout_minutes_key(), "15")
      conn = post(conn, @gate, %{"password" => "nope"})
      conn = conn |> recycle() |> post(@gate, %{"password" => "nope"})

      body = conn |> recycle() |> get(@gate) |> html_response(200)
      assert body =~ "Try again in"
      assert body =~ "disabled"
      assert body =~ ~r{<meta http-equiv="refresh" content="\d+"}, "reloads when the lock ends"

      conn = conn |> recycle() |> post(@gate, %{"password" => "Secret42"})
      assert redirected_to(conn) == @gate
      refute Gate.unlocked?(conn)
      assert [%{verdict: "locked", typed: "Secret42"} | _] = Gate.list_attempts()
    end

    test "a logged-in user is let straight through", %{conn: conn} do
      {user, _} = create_admin_user()
      conn = log_in_user(conn, user)
      assert redirected_to(get(conn, @gate <> "?to=%2Fabout")) == "/about"
    end
  end

  describe "the access link" do
    setup do
      gate_on()
      {:ok, token} = Gate.regenerate_access_link()
      %{token: token}
    end

    test "opening it shows one button; the button unlocks", %{conn: conn, token: token} do
      conn = get(conn, @gate <> "/link/" <> token)
      body = html_response(conn, 200)
      assert body =~ "Open the site"
      assert body =~ ~s(method="post")
      refute Gate.unlocked?(conn), "a bare GET must not unlock"

      conn = conn |> recycle() |> post(@gate <> "/link/" <> token)
      assert redirected_to(conn) == "/"
      assert Gate.unlocked?(conn)
      assert [%{verdict: "link"}] = Gate.list_attempts()
    end

    test "a stale link is refused", %{conn: conn, token: token} do
      {:ok, _} = Gate.regenerate_access_link()
      assert html_response(get(conn, @gate <> "/link/" <> token), 404) =~ "no longer valid"
      conn = post(conn, @gate <> "/link/" <> token)
      assert conn.status == 404
      refute Gate.unlocked?(conn)
    end
  end

  test "status answers while locked, and is not for search engines either", %{conn: conn} do
    gate_on()
    conn = get(conn, @gate <> "/status")
    assert json_response(conn, 200) == %{"status" => "ok", "gate" => true}
    assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
  end
end
