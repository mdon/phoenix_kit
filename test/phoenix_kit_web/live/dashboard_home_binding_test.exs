defmodule PhoenixKitWeb.Live.DashboardHomeBindingTest do
  @moduledoc """
  Whether `/admin` hides its built-in overview, decided at MOUNT.

  The embedded admin-home view also reports this, live, as an administrator
  binds or unbinds a dashboard — but it cannot be the first answer. It renders
  its board in the same pass as the page, so a page that assumes "nothing is
  bound" paints the board and the overview stacked together until the child's
  message lands.

  DB-free: every case drives the duck-typed contract with a stand-in module,
  which is the only way to exercise it here — core has no dependency on the
  package that implements it.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Live.Dashboard

  defmodule Bound do
    def admin_home_dashboards(_scope), do: {:everyone, [%{uuid: "a"}]}
  end

  defmodule Unbound do
    def admin_home_dashboards(_scope), do: {:none, []}
  end

  defmodule NoContract do
    def something_else, do: :ok
  end

  defmodule Raises do
    def admin_home_dashboards(_scope), do: raise("boom")
  end

  defmodule Exits do
    def admin_home_dashboards(_scope), do: exit(:no_repo)
  end

  test "a bound dashboard hides the overview from the first paint" do
    assert Dashboard.home_dashboard?(Bound, nil)
  end

  test "nothing bound keeps the overview" do
    refute Dashboard.home_dashboard?(Unbound, nil)
  end

  test "a module without the contract keeps the overview" do
    refute Dashboard.home_dashboard?(NoContract, nil)
  end

  test "a module that is not there at all keeps the overview" do
    refute Dashboard.home_dashboard?(NoSuchModuleAnywhere, nil)
  end

  # An optional module must never be able to leave /admin with neither half
  # rendered — a missing repo exits rather than raises, so both are caught.
  test "a raising contract keeps the overview" do
    refute Dashboard.home_dashboard?(Raises, nil)
  end

  test "an exiting contract keeps the overview" do
    refute Dashboard.home_dashboard?(Exits, nil)
  end
end
