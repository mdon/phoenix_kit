defmodule PhoenixKitWeb.Live.Integrations.MyIntegrationFormUnverifiedTest do
  @moduledoc """
  Same gap as `IntegrationFormUnverifiedTest`, on the PERSONAL integration
  form (`/admin/settings/integrations/:uuid`) — it has its own duplicate
  case sites (`save_new` dry-run, `handle_info(:do_validate, _)`) that
  needed their own proof the fix landed here too, not just on the system
  form. See that module's doc for the full incident.

  Exercises the REAL public path — no shim, no synthetic `:unverified`
  value handed in by the test. Reuses the same fixture provider (also
  scoped `:personal`) and drives the actual LiveView events:

    - dry-run test on the `:new` page (`_intent=test` submit)  -> `validate_credentials/2`
    - "Test Connection" click on the `:edit` page               -> `validate_connection/3`
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/integrations/new")
  @provider_key "fixture_unverified"

  defmodule FixtureProvider do
    @moduledoc false
    def integration_providers do
      [
        %{
          key: "fixture_unverified",
          name: "Fixture Unverified",
          description: "Test-only provider with no connection check",
          icon: "hero-beaker",
          auth_type: :credentials,
          oauth_config: nil,
          setup_fields: [
            %{
              key: "api_secret",
              label: "API Secret",
              type: :password,
              required: true,
              placeholder: "...",
              help: nil,
              options: nil
            }
          ],
          capabilities: [],
          scopes: [:system, :personal]
        }
      ]
    end
  end

  setup do
    ModuleRegistry.register(FixtureProvider)
    Providers.clear_cache()

    on_exit(fn ->
      ModuleRegistry.unregister(FixtureProvider)
      Providers.clear_cache()
    end)

    :ok
  end

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()

    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations")

    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "dry-run test — validate_credentials/2 (pre-save, no row exists)" do
    setup :setup_admin

    test "an unverified provider shows the warning, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      view |> render_click("select_provider", %{"provider" => @provider_key})

      html =
        render_submit(view, "save_new", %{
          "_intent" => "test",
          "api_secret" => "whatever"
        })

      assert html =~ "Not tested — this provider has no connection check"
      refute html =~ "Connection works"
      # The tone matters as much as the text: :warning, not the green
      # :info a real success gets or the red :error a real failure gets.
      assert html =~ "alert-warning"
      refute html =~ "alert-error"
    end
  end

  describe "Test Connection click — validate_connection/3 (post-save)" do
    setup :setup_admin

    test "an unverified provider is saved as configured, not crashed", %{
      conn: conn,
      user: user
    } do
      {:ok, %{uuid: uuid}} =
        PhoenixKit.Integrations.add_connection(@provider_key, "fixture conn", user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, _} =
        PhoenixKit.Integrations.save_setup(uuid, %{"api_secret" => "whatever"}, user.uuid,
          owner: {:user, user.uuid}
        )

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/integrations/#{uuid}"))

      view |> render_click("validate_connection")

      # `handle_info(:do_validate, _)` runs as a self-message after the
      # click's `handle_event` reply — a second synchronous render forces
      # the LiveView's mailbox forward past it (or surfaces the crash, if
      # the fix regresses).
      html = render(view)

      assert html =~ "Not tested — this provider has no connection check"
      refute html =~ "Connection works"
      assert html =~ "alert-warning"
      refute html =~ "alert-error"

      {:ok, data} = PhoenixKit.Integrations.get_integration(uuid)
      assert data["status"] == "configured"
    end
  end
end
