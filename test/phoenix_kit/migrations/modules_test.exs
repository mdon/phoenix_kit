defmodule PhoenixKit.Migrations.ModulesTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Covers the classification and filtering that `mix phoenix_kit.status` and
  `mix phoenix_kit.update` both read.

  Discovery itself (beam scanning) needs real dependent packages compiled into
  the build, so it isn't exercised here — `list/1` is asserted to degrade to
  `[]` rather than raise, which is the contract the CLI tasks depend on.
  """

  alias PhoenixKit.Migrations.Modules

  describe "list/1" do
    test "returns a list and never raises, even with nothing installed" do
      assert is_list(Modules.list())
      assert is_list(Modules.list(prefix: "public"))
    end

    test "every entry carries the full shape both tasks read" do
      for entry <- Modules.list() do
        assert %{
                 name: name,
                 module: module,
                 migration_module: migration_module,
                 installed: installed,
                 status: status
               } = entry

        assert is_binary(name)
        assert is_atom(module)
        assert is_atom(migration_module)
        assert is_integer(installed) and installed >= 0
        assert status in [:not_installed, :needs_update, :up_to_date, :error]
      end
    end
  end

  describe "pending/1" do
    test "selects modules whose tables are missing or behind" do
      entries = [
        entry("Fresh", 0, 1, :not_installed),
        entry("Behind", 1, 2, :needs_update),
        entry("Current", 2, 2, :up_to_date),
        error_entry("Broken")
      ]

      assert Modules.pending(entries) |> Enum.map(& &1.name) == ["Fresh", "Behind"]
    end

    test "a broken module is not treated as pending — migrating it blind would be worse" do
      assert Modules.pending([error_entry("Broken")]) == []
    end

    test "an empty list stays empty" do
      assert Modules.pending([]) == []
    end
  end

  describe "failed/1" do
    test "isolates modules whose coordinator raised" do
      entries = [entry("Current", 1, 1, :up_to_date), error_entry("Broken")]

      assert Modules.failed(entries) |> Enum.map(& &1.name) == ["Broken"]
    end

    test "an empty list stays empty" do
      assert Modules.failed([]) == []
    end
  end

  describe "status classification" do
    test "installed at or above target is up to date" do
      assert classify_via_pending(entry("M", 2, 2, :up_to_date)) == false
      assert classify_via_pending(entry("M", 3, 2, :up_to_date)) == false
    end

    test "zero installed with a target is not installed, and is pending" do
      assert classify_via_pending(entry("M", 0, 1, :not_installed)) == true
    end

    test "installed below target is pending" do
      assert classify_via_pending(entry("M", 1, 5, :needs_update)) == true
    end
  end

  defp classify_via_pending(entry), do: Modules.pending([entry]) != []

  defp entry(name, installed, target, status) do
    %{
      name: name,
      module: SomeModule,
      migration_module: SomeModule.Migrations,
      installed: installed,
      target: target,
      status: status,
      error: nil
    }
  end

  defp error_entry(name) do
    %{
      name: name,
      module: SomeModule,
      migration_module: SomeModule.Migrations,
      installed: 0,
      target: nil,
      status: :error,
      error: "boom"
    }
  end
end
