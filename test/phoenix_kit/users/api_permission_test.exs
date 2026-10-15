defmodule PhoenixKit.Users.ApiPermissionTest do
  @moduledoc """
  The `api` permission (API keys, service users, Settings → API) as a key: a core
  section, always enabled, and opt-in for Admin. The database side (the boot sweep, Owner,
  an explicit grant) is in `test/integration/users/api_permission_test.exs`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Permissions

  test "api is a core section key, known everywhere a key must be known" do
    assert "api" in Permissions.core_section_keys()
    assert "api" in Permissions.all_module_keys()
    assert MapSet.member?(Permissions.enabled_module_keys(), "api")
    assert Permissions.valid_module_key?("api")
    assert Permissions.feature_enabled?("api")
  end

  test "api is neither a feature module key nor a sub-permission" do
    refute "api" in Permissions.feature_module_keys()
    assert Permissions.parent_key("api") == nil
  end

  test "api is opt-in for Admin and excluded from the operator baseline" do
    assert "api" in Permissions.opt_in_admin_keys()
    assert "api" in Permissions.admin_baseline_exclusions()
    # the personal integrations page stays opt-in as well
    assert "integrations" in Permissions.opt_in_admin_keys()
  end

  test "auto_grant_to_admin_roles/1 refuses api at the chokepoint, without touching the database" do
    assert :ok = Permissions.auto_grant_to_admin_roles("api")
  end

  test "api has a label, an icon and a description" do
    assert Permissions.module_label("api") == "API keys"
    assert Permissions.module_icon("api") =~ "hero-"
    refute Permissions.module_description("api") == ""
  end
end
