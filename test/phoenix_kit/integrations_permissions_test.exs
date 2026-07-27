defmodule PhoenixKit.IntegrationsPermissionsTest do
  # Pure Permissions functions — no DB.
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Permissions

  test "both integration keys are registered, valid, enabled, and independent" do
    keys = Permissions.integration_keys()
    assert keys == ["integrations", "integrations_system"]

    for key <- keys do
      assert key in Permissions.all_module_keys()
      assert MapSet.member?(Permissions.enabled_module_keys(), key)
      assert Permissions.valid_module_key?(key)
      assert Permissions.feature_enabled?(key)
      # Independence: neither is a dotted sub-key, so neither implies the other
      # (no cascade in grant/revoke/set).
      assert Permissions.parent_key(key) == nil
    end
  end

  test "the keys have distinct labels/descriptions" do
    assert Permissions.module_label("integrations") == "My Integrations"
    assert Permissions.module_label("integrations_system") == "System Integrations"
    refute Permissions.module_description("integrations") == ""
    refute Permissions.module_description("integrations_system") == ""
  end
end
