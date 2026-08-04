defmodule PhoenixKit.Migrations.ExpectedSchema.ResolverTest do
  # `async: false` — Application env is process-global; this file mutates
  # `:phoenix_kit, :expected_schema_module` (a key nothing else in the suite
  # touches) across several tests and restores it every time, but there is
  # no upside to letting its own test cases interleave with each other.
  use ExUnit.Case, async: false

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver

  setup do
    Application.delete_env(:phoenix_kit, :expected_schema_module)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :expected_schema_module) end)
  end

  describe "default_module/0" do
    test "names the real (not-yet-generated) manifest module" do
      assert Resolver.default_module() == PhoenixKit.Migrations.ExpectedSchema
    end
  end

  describe "not_generated_message/0" do
    test "is a stable, non-empty, human-readable string" do
      message = Resolver.not_generated_message()

      assert is_binary(message)
      assert message =~ "not generated"
    end
  end

  describe "resolve/0 without an override" do
    test "returns {:error, :not_generated} — the real manifest does not exist in this repo yet" do
      # This is P2's central degrade-gracefully case (task hard rules): once
      # P3's squash PR generates `PhoenixKit.Migrations.ExpectedSchema` for
      # real, this specific assertion starts failing — that is expected and
      # correct; replace it with an {:ok, ...} assertion at that point rather
      # than deleting the test (resolve/0's default-path behavior still
      # deserves coverage against the real module).
      refute Code.ensure_loaded?(PhoenixKit.Migrations.ExpectedSchema)
      assert Resolver.resolve() == {:error, :not_generated}
    end
  end

  describe "resolve/0 with an override" do
    test "returns {:ok, module} when pointed at a conformant fixture" do
      Application.put_env(
        :phoenix_kit,
        :expected_schema_module,
        PhoenixKit.Test.FixtureExpectedSchema
      )

      assert Resolver.resolve() == {:ok, PhoenixKit.Test.FixtureExpectedSchema}
    end

    test "returns {:error, :not_generated} for a loaded module that does not implement the contract" do
      Application.put_env(:phoenix_kit, :expected_schema_module, Enum)

      assert Resolver.resolve() == {:error, :not_generated}
    end

    test "returns {:error, :not_generated} for a module that does not exist at all" do
      Application.put_env(
        :phoenix_kit,
        :expected_schema_module,
        PhoenixKit.Migrations.ExpectedSchema.NoSuchModule
      )

      assert Resolver.resolve() == {:error, :not_generated}
    end

    test "clearing the override reverts to the default resolution" do
      Application.put_env(
        :phoenix_kit,
        :expected_schema_module,
        PhoenixKit.Test.FixtureExpectedSchema
      )

      assert Resolver.resolve() == {:ok, PhoenixKit.Test.FixtureExpectedSchema}

      Application.delete_env(:phoenix_kit, :expected_schema_module)
      assert Resolver.resolve() == {:error, :not_generated}
    end
  end
end
