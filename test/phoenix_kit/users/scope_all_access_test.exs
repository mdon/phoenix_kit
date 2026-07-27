defmodule PhoenixKit.Users.ScopeAllAccessTest do
  @moduledoc """
  `Scope.holds_all_enabled_permissions?/1` — the role-agnostic "Owner-equivalent"
  predicate for the unmapped-admin-view fallback. A role granted every grantable
  permission behaves like Owner; a partial role fails closed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions

  defp scope(keys), do: %Scope{cached_permissions: MapSet.new(keys)}

  # The "operator baseline": every grantable key EXCEPT the opt-in ones. This is
  # what Owner-equivalence is measured against (see the REG-1 fix).
  defp operator_baseline do
    MapSet.difference(
      Permissions.enabled_module_keys(),
      MapSet.new(Permissions.opt_in_admin_keys())
    )
  end

  test "true when the scope holds every currently-grantable key (grant-all custom role == Owner)" do
    enabled = Permissions.enabled_module_keys()
    assert MapSet.size(enabled) > 0
    assert Scope.holds_all_enabled_permissions?(scope(enabled))

    # Owner's superset (all_module_keys, incl. disabled-module keys) also passes.
    assert Scope.holds_all_enabled_permissions?(scope(Permissions.all_module_keys()))
  end

  test "fails closed for a partial role (missing an operator key)" do
    # Drop a NON-opt-in operator key — that must fail closed.
    refute Scope.holds_all_enabled_permissions?(
             scope(MapSet.delete(operator_baseline(), "users"))
           )
  end

  test "opt-in keys are excluded — a default-Admin-shaped scope is Owner-equivalent (REG-1)" do
    operator = operator_baseline()

    # The personal `integrations` page is opt-in, so it is NOT part of the
    # baseline — a default Admin never holds it yet must still reach unmapped
    # admin views.
    refute MapSet.member?(operator, "integrations")
    assert Scope.holds_all_enabled_permissions?(scope(operator))

    # Missing ONLY the opt-in key (holding everything else enabled) still passes.
    assert Scope.holds_all_enabled_permissions?(
             scope(MapSet.delete(Permissions.enabled_module_keys(), "integrations"))
           )
  end

  test "fails closed for an empty / nil permission set (no vacuous-truth fail-open)" do
    refute Scope.holds_all_enabled_permissions?(scope([]))
    refute Scope.holds_all_enabled_permissions?(%Scope{cached_permissions: nil})
    refute Scope.holds_all_enabled_permissions?(nil)
  end
end
