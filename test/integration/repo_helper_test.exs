defmodule PhoenixKit.Integration.RepoHelperTest do
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.RepoHelper

  describe "get_pk_column/1" do
    test "returns 'uuid' for shipped tables (regression test for #517)" do
      assert RepoHelper.get_pk_column("phoenix_kit_users") == "uuid"
      assert RepoHelper.get_pk_column("phoenix_kit_settings") == "uuid"
      assert RepoHelper.get_pk_column("phoenix_kit_users_tokens") == "uuid"
    end

    test "raises ArgumentError for a non-existent table" do
      assert_raise ArgumentError, ~r/no primary key found/, fn ->
        RepoHelper.get_pk_column("phoenix_kit_definitely_not_a_real_table")
      end
    end
  end
end
