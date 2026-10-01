defmodule PhoenixKit.TestSupport.PostgresPreflightClassifyTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.TestSupport.PostgresPreflight

  defp pgbouncer(message),
    do: %Postgrex.Error{
      postgres: %{code: :protocol_violation, pg_code: "08P01", message: message}
    }

  describe "a PgBouncer 08P01" do
    test "for an unknown role is a credentials problem, not an unreachable server" do
      assert {:auth_rejected, "no such user"} =
               PostgresPreflight.classify(pgbouncer("no such user"))
    end

    test "for a failed password is a credentials problem" do
      assert {:auth_rejected, _} =
               PostgresPreflight.classify(pgbouncer("password authentication failed"))
    end

    test "for a database it has no entry for is a missing database" do
      assert {:database_not_found, _} =
               PostgresPreflight.classify(pgbouncer("no such database: app_test"))
    end

    test "with any other message is a protocol violation, still not unreachable" do
      assert {:protocol_violation, _} =
               PostgresPreflight.classify(pgbouncer("unsupported startup parameter"))
    end
  end

  test "other 08 codes still mean nothing answered" do
    error = %Postgrex.Error{postgres: %{code: :connection_failure, pg_code: "08006"}}
    assert {:unreachable, _} = PostgresPreflight.classify(error)
  end
end
