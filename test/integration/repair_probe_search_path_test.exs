defmodule PhoenixKit.Migrations.Repair.ProbeSearchPathTest do
  @moduledoc """
  `Probe.snapshot/2` sets `search_path = ''` for its catalog queries. It must
  never leave a connection changed: behind PgBouncer a session-level SET and
  its RESET landed on different server connections, and the one left at ''
  broke a host app's pages until every pooled connection was reset.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Repair.Probe
  alias PhoenixKit.Test.Repo

  test "the caller's own search_path is exactly as it was afterwards" do
    custom = "pg_catalog, public"
    Repo.query!("SET search_path TO #{custom}", [])

    assert %{tables: _} = Probe.snapshot(Repo, "public")

    %{rows: [[after_path]]} = Repo.query!("SHOW search_path", [])
    assert after_path == custom
  end
end
