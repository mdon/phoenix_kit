defmodule PhoenixKit.Migrations.Postgres.HelpersTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Postgres.Helpers

  describe "validate_prefix!/1" do
    test "accepts conventional lower-case identifiers" do
      assert :ok = Helpers.validate_prefix!("public")
      assert :ok = Helpers.validate_prefix!("auth")
      assert :ok = Helpers.validate_prefix!("companyplexus")
      assert :ok = Helpers.validate_prefix!("my_app_2")
      assert :ok = Helpers.validate_prefix!("_private")
    end

    test "rejects identifiers that need quoting" do
      for bad <- ["MyApp", "my-app", "1schema", "sp ace", "we\"ird", ""] do
        assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
          Helpers.validate_prefix!(bad)
        end
      end
    end

    test "rejects SQL-injection shaped prefixes" do
      assert_raise ArgumentError, fn ->
        Helpers.validate_prefix!("public; DROP TABLE phoenix_kit_users;--")
      end
    end

    test "rejects non-binary values" do
      assert_raise ArgumentError, ~r/expected a string/, fn ->
        Helpers.validate_prefix!(nil)
      end

      assert_raise ArgumentError, ~r/expected a string/, fn ->
        Helpers.validate_prefix!(:auth)
      end
    end
  end

  describe "qualify_table/2" do
    test "qualifies with the prefix" do
      assert Helpers.qualify_table("phoenix_kit_users", "auth") == "auth.phoenix_kit_users"
    end

    test "nil prefix qualifies explicitly as public" do
      assert Helpers.qualify_table("phoenix_kit_users", nil) == "public.phoenix_kit_users"
    end
  end

  describe "uuid_v7_call/1" do
    test "always schema-qualifies the function call" do
      assert Helpers.uuid_v7_call("auth") == "auth.uuid_generate_v7()"
      assert Helpers.uuid_v7_call("public") == "public.uuid_generate_v7()"
      assert Helpers.uuid_v7_call(nil) == "public.uuid_generate_v7()"
    end
  end
end
