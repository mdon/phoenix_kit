defmodule Mix.Tasks.PhoenixKit.DoctorCompositeFkTest do
  use PhoenixKit.DataCase, async: false

  alias Mix.Tasks.PhoenixKit.Doctor
  alias PhoenixKit.Test.Repo

  setup do
    prefix = "doctor_composite_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")

    Repo.query!(
      ~s|CREATE TABLE #{prefix}.parents ("Key" integer, tenant integer, UNIQUE (tenant, "Key"))|
    )

    Repo.query!(~s|CREATE TABLE #{prefix}.children (tenant integer, "Foreign Key" integer)|)
    Repo.query!(~s|INSERT INTO #{prefix}.parents VALUES (7, 1), (8, 2)|)
    # Sandbox rollback removes the entire fixture schema.
    %{prefix: prefix}
  end

  defp add_fk(prefix, match_type, validation \\ "") do
    Repo.query!("""
    ALTER TABLE #{prefix}.children ADD CONSTRAINT composite_fk
    FOREIGN KEY ("Foreign Key", tenant) REFERENCES #{prefix}.parents ("Key", tenant)
    MATCH #{match_type} DEFERRABLE INITIALLY DEFERRED #{validation}
    """)
  end

  test "checks all pairs in catalog order with quoted columns and MATCH SIMPLE nulls", %{
    prefix: prefix
  } do
    Repo.query!(
      "INSERT INTO #{prefix}.children VALUES (1, 7), (NULL, 99), (99, NULL), (NULL, NULL)"
    )

    add_fk(prefix, "SIMPLE")
    assert {:ok, {[fk], []}} = Doctor.discover_fk_constraints(Repo, prefix)
    assert fk.fk_cols == ["Foreign Key", "tenant"]
    assert fk.ref_cols == ["Key", "tenant"]
    assert {:pass, message} = Doctor.check_orphaned_fk_refs(prefix)
    assert message =~ "checked 1 of 1"

    # Each value exists separately, but this pair does not.
    Repo.query!("INSERT INTO #{prefix}.children VALUES (2, 7)")
    assert {:fail, message} = Doctor.check_orphaned_fk_refs(prefix)
    assert message =~ "1 orphaned row(s)"
    assert message =~ "constraint IS validated"
  end

  test "MATCH FULL counts partial nulls but exempts all-null rows", %{prefix: prefix} do
    Repo.query!(
      "INSERT INTO #{prefix}.children VALUES (1, 7), (NULL, NULL), (NULL, 7), (1, NULL)"
    )

    add_fk(prefix, "FULL", "NOT VALID")
    assert {:fail, message} = Doctor.check_orphaned_fk_refs(prefix)
    assert message =~ "2 orphaned row(s)"
    assert message =~ "NOT VALID"
  end

  test "a clean composite NOT VALID constraint remains a validation warning", %{prefix: prefix} do
    Repo.query!("INSERT INTO #{prefix}.children VALUES (1, 7)")
    add_fk(prefix, "SIMPLE", "NOT VALID")
    assert {:warn, message} = Doctor.check_orphaned_fk_refs(prefix)
    assert message =~ "never validated"
    assert message =~ "checked 1 of 1"
  end
end
