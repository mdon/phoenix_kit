defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationFormSecretMaskingTest do
  @moduledoc """
  D011: the PERSONAL integration setup form
  (`/admin/settings/integrations/:uuid`) shares `setup_field/1` with the
  system form, but has its own render call site and its own duplicate
  save-side "empty password = keep existing" logic (`setup_attrs/2`) — so it
  needs its own proof the fix landed here too, not just on the system form.

  Uses `telegram` — personal-offered, single `:password` field (`bot_token`).
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/integrations/new")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()

    # Personal integrations are gated by the "integrations" key (independent
    # of the system form's "integrations_system") — same auto-grant-runs-at-
    # boot-not-here situation as `integrations_test.exs`.
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations")

    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  defp seed_telegram(user, secret) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("telegram", "my bot", user.uuid, owner: {:user, user.uuid})

    {:ok, _} =
      Integrations.save_setup(uuid, %{"bot_token" => secret}, user.uuid,
        owner: {:user, user.uuid}
      )

    uuid
  end

  describe "editing a personal connection with a saved secret" do
    setup :setup_admin

    test "the saved bot token never appears in the rendered HTML", %{conn: conn, user: user} do
      secret = "telegram-token-#{System.unique_integer([:positive])}"
      uuid = seed_telegram(user, secret)

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      refute html =~ secret
    end

    test "the operator sees the S009 'already configured' placeholder instead of the token",
         %{conn: conn, user: user} do
      secret = "telegram-token-#{System.unique_integer([:positive])}"
      uuid = seed_telegram(user, secret)

      {:ok, _view, html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      assert html =~ "A secret is already configured — leave blank to keep the current value"
      assert html =~ ~s(name="bot_token" id="field-bot_token" value="")
    end
  end

  describe "a failed dry-run test on /new preserves what the operator typed" do
    setup :setup_admin

    test "the just-typed token is NOT swallowed by masking when the test fails", %{conn: conn} do
      typed_token = "just-typed-token-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, @new_path)

      view
      |> element(~s(button[phx-value-provider="telegram"]))
      |> render_click()

      html =
        view
        |> element(~s(form[phx-submit="save_new"]))
        |> render_submit(%{"_intent" => "test", "bot_token" => typed_token})

      assert html =~ typed_token
    end
  end
end
