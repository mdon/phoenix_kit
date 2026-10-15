defmodule PhoenixKitWeb.Live.Settings.ApiRotationTest do
  @moduledoc """
  Settings -> API: rotating a key.

  Rotation makes a new key with the same settings and keeps the old one working
  for a grace period of 0 to 24 whole hours the admin chooses. The new key is
  shown once, in the same dialog as a new key.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api")

  setup %{conn: conn} do
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.start_key_cache!()

    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")
    for key <- ["api", "media"], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)

    scope = KeyTestSupport.scope_of(admin)

    {:ok, key, token} =
      Keys.create_key(admin, scope, %{
        "name" => "Rotating",
        "scopes" => [KeyTestSupport.read_scope()]
      })

    %{conn: log_in_user(conn, admin), admin: admin, scope: scope, key: key, token: token}
  end

  defp request_rotate(view, key) do
    view
    |> element(~s(#api-key-menu-#{key.uuid} button[phx-click="request_rotate"]))
    |> render_click()
  end

  defp submit_rotate(view, hours) do
    view
    |> form("#rotate-api-key-form", %{"rotate" => %{"grace_hours" => hours}})
    |> render_submit()
  end

  defp new_token_in(html), do: html |> then(&Regex.run(~r/value="(pk_[^"]+)"/, &1)) |> List.last()

  # The page's scope is captured at mount; a plain delete sends no PubSub message,
  # so the page does not hear of it: the window the server-side re-check is for.
  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  defp capture_debug_log(fun) do
    original = Logger.level()
    Logger.configure(level: :debug)

    try do
      with_log([level: :debug], fun)
    after
      Logger.configure(level: original)
    end
  end

  test "asks for a grace period, then shows the new key once", %{
    conn: conn,
    key: key,
    token: old_token,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)

    assert has_element?(view, "#rotate-api-key-form")
    new_token = view |> submit_rotate("2") |> new_token_in()

    assert new_token != old_token
    assert has_element?(view, "#new-api-token-modal")
    refute has_element?(view, "#rotate-api-key-modal")

    # Both keys work during the grace period, and there are two rows now.
    assert {:ok, _actor} = Keys.verify(old_token, nil)
    assert {:ok, actor} = Keys.verify(new_token, nil)
    assert actor.scopes == [KeyTestSupport.read_scope()]
    assert length(Keys.list_keys(scope)) == 2
  end

  test "the old key is marked as ending during the grace period", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)
    submit_rotate(view, "2")

    assert has_element?(view, "#api-key-#{key.uuid}", "Ending")
  end

  test "a grace period of 0 stops the old key at once", %{conn: conn, key: key, token: old_token} do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)
    submit_rotate(view, "0")

    assert {:error, :revoked} = Keys.verify(old_token, nil)
    assert has_element?(view, "#api-key-#{key.uuid}", "Revoked")
  end

  test "the new key is dismissed like any new key and leaves no trace", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)
    token = view |> submit_rotate("1") |> new_token_in()

    assert :sys.get_state(view.pid).socket.assigns.new_token.value == token

    view |> element("#new-api-token-done") |> render_click()

    assert :sys.get_state(view.pid).socket.assigns.new_token == nil
    refute render(view) =~ token
  end

  test "the new key's token never reaches the logs", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)

    {token, log} =
      capture_debug_log(fn ->
        request_rotate(view, key)
        token = view |> submit_rotate("1") |> new_token_in()
        view |> element("#new-api-token-done") |> render_click()
        token
      end)

    [_pk, _prefix, secret] = String.split(token, "_", parts: 3)

    assert log =~ "confirm_rotate"
    refute log =~ token
    refute log =~ secret
  end

  test "cancelling leaves the key alone", %{conn: conn, key: key, scope: scope} do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)

    view |> element(~s(#rotate-api-key-modal button[phx-click="cancel_rotate"])) |> render_click()
    render_click(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

    refute has_element?(view, "#rotate-api-key-modal")
    assert length(Keys.list_keys(scope)) == 1
  end

  test "a replayed confirm_rotate rotates once and keeps the new token", %{
    conn: conn,
    key: key,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)
    token = view |> submit_rotate("1") |> new_token_in()

    # The dialog is closed and the new token waits to be dismissed: same event again.
    html = render_submit(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

    assert html =~ "That action is not available."
    assert length(Keys.list_keys(scope)) == 2
    assert :sys.get_state(view.pid).socket.assigns.new_token.value == token
  end

  test "confirm_rotate after the person lost api rotates nothing", %{conn: conn, key: key} do
    {:ok, view, _html} = live(conn, @path)
    request_rotate(view, key)

    drop_api_silently!()
    # Not vacuous: the page has not heard of it, its scope still says api.
    assert Scope.can?(:sys.get_state(view.pid).socket.assigns.phoenix_kit_current_scope, "api")

    html = submit_rotate(view, "1")

    assert html =~ "You are not allowed to do that."
    assert Repo.aggregate(Key, :count) == 1
    assert Keys.get_key(key.uuid).revoked_at == nil
    assert :sys.get_state(view.pid).socket.assigns.new_token == nil
  end

  describe "forged input" do
    for hours <- ["25", "99", "-1", "abc", "1.5", ""] do
      test "a grace period of #{inspect(hours)} is refused and rotates nothing", %{
        conn: conn,
        key: key,
        scope: scope,
        token: token
      } do
        {:ok, view, _html} = live(conn, @path)
        request_rotate(view, key)

        render_submit(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => unquote(hours)}})

        assert has_element?(view, "#rotate-api-key-error")
        assert has_element?(view, "#rotate-api-key-form")
        assert length(Keys.list_keys(scope)) == 1
        assert Keys.get_key(key.uuid).revoked_at == nil
        assert {:ok, _actor} = Keys.verify(token, nil)
      end
    end

    test "a key made by someone else cannot be rotated", %{conn: conn, scope: scope} do
      {other, _token} = create_admin_user()

      {:ok, theirs, their_token} =
        Keys.create_key(other, KeyTestSupport.scope_of(other), %{"name" => "Theirs"})

      {:ok, view, _html} = live(conn, @path)

      html = render_click(view, "request_rotate", %{"uuid" => theirs.uuid})
      assert html =~ "That key was not found."

      render_submit(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

      assert length(Keys.list_keys(scope)) == 1
      assert Keys.get_key(theirs.uuid).revoked_at == nil
      assert {:ok, _actor} = Keys.verify(their_token, nil)
    end

    test "a confirm without a request rotates nothing and does not crash", %{
      conn: conn,
      scope: scope
    } do
      {:ok, view, _html} = live(conn, @path)

      html = render_submit(view, "confirm_rotate", %{"rotate" => %{"grace_hours" => "1"}})

      assert html =~ "That key was not found."
      assert length(Keys.list_keys(scope)) == 1
    end

    test "a revoked key has no rotate action", %{conn: conn, key: key} do
      {:ok, _} = Keys.revoke(key, nil)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#api-key-menu-#{key.uuid}")
    end
  end
end
