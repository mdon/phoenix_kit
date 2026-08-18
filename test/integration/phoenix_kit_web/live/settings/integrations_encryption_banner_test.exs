defmodule PhoenixKitWeb.Live.Settings.IntegrationsEncryptionBannerTest do
  @moduledoc """
  Encryption-status banner on the system integrations admin page.

  Kept in its own `async: false` module because it mutates the global
  `:phoenix_kit` Application env (`:integrations_encryption_key`,
  `:secret_key_base`, `:integration_encryption_enabled`) —
  `PhoenixKit.Integrations.EncryptionTest` documents why that can't safely
  share a process pool with tests that read the same config concurrently.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @list_path Routes.path("/admin/settings/integrations/website")

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "integrations_system")

    original_dedicated = Application.get_env(:phoenix_kit, :integrations_encryption_key)
    original_flat = Application.get_env(:phoenix_kit, :secret_key_base)
    original_enabled = Application.get_env(:phoenix_kit, :integration_encryption_enabled)
    original_parent = Application.get_env(:phoenix_kit, :parent_module)

    on_exit(fn ->
      restore_env(:integrations_encryption_key, original_dedicated)
      restore_env(:secret_key_base, original_flat)
      restore_env(:integration_encryption_enabled, original_enabled)
      restore_env(:parent_module, original_parent)
    end)

    %{conn: log_in_user(conn, user)}
  end

  test "shows the legacy-key warning when only secret_key_base backs encryption", %{conn: conn} do
    Application.delete_env(:phoenix_kit, :integrations_encryption_key)
    Application.put_env(:phoenix_kit, :secret_key_base, "legacy-secret-for-banner-test")
    assert Encryption.status() == :legacy_secret_key_base

    {:ok, _view, html} = live(conn, @list_path)

    assert html =~ "alert-warning"
    assert html =~ "mix phoenix_kit.integrations.rotate_key"
  end

  test "shows no encryption banner once a dedicated key is configured", %{conn: conn} do
    Application.put_env(
      :phoenix_kit,
      :integrations_encryption_key,
      "dedicated-secret-for-banner-test"
    )

    assert Encryption.status() == :dedicated

    {:ok, _view, html} = live(conn, @list_path)

    refute html =~ "Credentials are protected only by a shared application secret"
    refute html =~ "Credentials are stored in plain text"
    refute html =~ "Encryption is turned off for integration credentials"
  end

  test "shows the plaintext warning when encryption is explicitly disabled", %{conn: conn} do
    Application.put_env(:phoenix_kit, :integration_encryption_enabled, false)
    assert Encryption.status() == :disabled_explicit

    {:ok, _view, html} = live(conn, @list_path)

    assert html =~ "alert-warning"
    assert html =~ "Encryption is turned off for integration credentials"
  end

  test "shows the plaintext warning when no encryption key resolves at all", %{conn: conn} do
    # Neither a dedicated key nor a flat secret_key_base is configured, AND
    # the host endpoint lookup itself can't resolve — the exact path that
    # used to be misreported as `:disabled_no_key` for the OPPOSITE reason
    # (Endpoint not started yet because `PhoenixKit.Supervisor` runs before
    # it) when this boot check ran too early. Here the endpoint genuinely
    # can't be found, so `:disabled_no_key` is the correct, honest status.
    Application.delete_env(:phoenix_kit, :integrations_encryption_key)
    Application.delete_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :parent_module, PhoenixKit.NoSuchApp)
    assert Encryption.status() == :disabled_no_key

    {:ok, _view, html} = live(conn, @list_path)

    assert html =~ "alert-warning"
    assert html =~ "Credentials are stored in plain text"
  end

  defp restore_env(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore_env(key, value), do: Application.put_env(:phoenix_kit, key, value)
end
