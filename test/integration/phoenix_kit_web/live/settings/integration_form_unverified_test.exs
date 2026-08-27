defmodule PhoenixKitWeb.Live.Settings.IntegrationFormUnverifiedTest do
  @moduledoc """
  Review on PR #754 found that `IntegrationForm` never learned about the
  `:unverified` result `Integrations.validate_credentials/2` and
  `Integrations.validate_connection/3` can now return — every call site
  here pattern-matched only `:ok` / `{:ok, _}` / `{:error, _}`, so a
  provider with no way to check a connection would crash the LiveView
  with a `CaseClauseError` instead of showing "Not tested". That's worse
  than the original bug (a false "connected"): a crash instead of a lie.

  Exercises the REAL public path end to end — no shim, no synthetic
  `:unverified` value handed in by the test. Registers a fixture provider
  shaped exactly like Shopify (`auth_type: :credentials`, no `validation`
  map, so `do_validate/2`'s catch-all is the one actually hit — see
  `PhoenixKit.Integrations.integrations_test.exs` for the do_validate/2
  clause-level coverage via the test-only shim) and drives the actual
  LiveView events a click sends, on both call sites:

    - dry-run test (pre-save)  -> `test_credentials_dry_run/2` -> `validate_credentials/2`
    - Test Connection (post-save, auto-fired by `apply_save_outcome/2`) -> `validate_connection/3`
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @new_path Routes.path("/admin/settings/integrations/website/new")
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
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")

    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  describe "dry-run test — validate_credentials/2 (pre-save, no row exists)" do
    setup :setup_admin

    test "an unverified provider shows the warning, not a crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      view |> render_click("select_provider", %{"provider" => @provider_key})

      html =
        render_submit(view, "save_form", %{
          "_intent" => "test",
          "api_secret" => "whatever"
        })

      assert html =~ "Not tested — this provider has no connection check"
      refute html =~ "Connection verified"
      refute html =~ "Test failed"
    end
  end

  describe "Test Connection after save — validate_connection/3 (post-save, auto-fired)" do
    setup :setup_admin

    test "an unverified provider is saved as configured, not crashed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      view |> render_click("select_provider", %{"provider" => @provider_key})

      render_submit(view, "save_form", %{
        "name" => "fixture conn",
        "api_secret" => "whatever"
      })

      # `apply_save_outcome/2` auto-fires `:do_test_connection` as a
      # self-message when the just-saved status is "configured" — it
      # hasn't been processed yet when `render_submit/3` returns. A
      # second synchronous render forces the LiveView's mailbox forward
      # past it (or surfaces the crash, if the fix regresses).
      html = render(view)

      assert html =~ "Not tested — this provider has no connection check"
      refute html =~ "Connection verified"
      refute html =~ "Test failed"
    end
  end
end
