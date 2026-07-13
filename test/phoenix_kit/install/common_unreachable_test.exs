defmodule PhoenixKit.Install.CommonUnreachableTest do
  # async: false — mutates the :phoenix_kit repo config.
  use ExUnit.Case, async: false

  alias PhoenixKit.Install.Common

  setup do
    original = Application.get_env(:phoenix_kit, :repo)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:phoenix_kit, :repo)
        value -> Application.put_env(:phoenix_kit, :repo, value)
      end
    end)

    :ok
  end

  test "an unqueryable database reports {:unreachable, _}, never {:not_installed}" do
    # Regression: with no version marker found, the old code fell through to
    # {:not_installed} even when the DB couldn't be queried at all — and the
    # update task drives migration generation off that answer. With no repo
    # configured the install state is unknowable.
    Application.delete_env(:phoenix_kit, :repo)

    assert {:unreachable, :no_repo_configured} =
             Common.check_installation_status("some_absent_prefix")
  end
end
