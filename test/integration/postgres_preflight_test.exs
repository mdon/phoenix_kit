defmodule PhoenixKit.TestSupport.PostgresPreflightTest do
  @moduledoc """
  The preflight has to be right about the thing it replaces, so these assert
  against a REAL server rather than a stubbed classifier.

  The behaviour under test is not "it returns an error" — the old code did
  that too, eventually. It is that a rejected login is reported *as a rejected
  login*, *immediately*, instead of as the pool checkout timeout that reads
  like a flaky test.
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  alias PhoenixKit.Test.Repo, as: TestRepo
  alias PhoenixKit.TestSupport.PostgresPreflight

  defp base do
    config = TestRepo.config()

    [
      hostname: Keyword.get(config, :hostname, "localhost"),
      port: Keyword.get(config, :port, 5432),
      username: Keyword.fetch!(config, :username),
      password: Keyword.get(config, :password),
      database: Keyword.fetch!(config, :database)
    ]
  end

  describe "check/1" do
    test "passes against the repo the suite is already using" do
      assert :ok = PostgresPreflight.check(base())
      assert :ok = PostgresPreflight.check(TestRepo)
    end

    test "a role the server rejects is reported as such, not as a timeout" do
      opts =
        Keyword.put(
          base(),
          :username,
          "definitely_not_a_role_#{System.unique_integer([:positive])}"
        )

      {elapsed_us, result} = :timer.tc(fn -> PostgresPreflight.check(opts) end)

      assert {:error, :auth_rejected, message} = result

      # The whole point. The old path took ~4s to produce "connection not
      # available and request was dropped from queue", which is why nine repos
      # documented this as flakiness. Anything near a second means the probe
      # has fallen back into the pool.
      assert elapsed_us < 1_000_000

      assert message =~ "refused the credentials"
      assert message =~ "PGUSER"
      refute message =~ "dropped from queue"
    end

    test "a missing database is distinguished from a rejected login" do
      opts = Keyword.put(base(), :database, "no_such_db_#{System.unique_integer([:positive])}")

      assert {:error, :database_not_found, message} = PostgresPreflight.check(opts)
      assert message =~ "does not exist"
      assert message =~ "test.setup"
    end

    test "nothing listening is distinguished from both" do
      assert {:error, :unreachable, message} =
               PostgresPreflight.check(Keyword.put(base(), :port, 59_999))

      assert message =~ "No PostgreSQL server answered"
      assert message =~ "PGHOST"
    end

    test "the message names host, database and user but never the password" do
      opts =
        base()
        |> Keyword.put(:username, "nope_#{System.unique_integer([:positive])}")
        |> Keyword.put(:password, "correct-horse-battery-staple")

      assert {:error, _, message} = PostgresPreflight.check(opts)

      assert message =~ Keyword.fetch!(opts, :database)
      assert message =~ Keyword.fetch!(opts, :username)
      refute message =~ "correct-horse-battery-staple"
    end

    # Load-bearing: a repo's config carries `pool: Ecto.Adapters.SQL.Sandbox`
    # and its ownership/queue timeouts. Letting those through would rebuild the
    # very pool whose checkout timeout is the failure being diagnosed.
    test "sandbox and pool settings in the config are stripped, not honoured" do
      opts =
        base() ++
          [
            pool: Ecto.Adapters.SQL.Sandbox,
            pool_size: 25,
            ownership_timeout: 1,
            queue_target: 1,
            queue_interval: 1,
            telemetry_prefix: [:irrelevant]
          ]

      assert :ok = PostgresPreflight.check(opts)
    end

    test "an unknown repo module yields no opinion rather than a crash" do
      assert :ok = PostgresPreflight.check(NotARepo.That.Exists)
    end
  end

  describe "check!/1" do
    test "returns :ok when the connection works" do
      assert :ok = PostgresPreflight.check!(base())
    end

    test "raises with the same guidance when it does not" do
      opts = Keyword.put(base(), :username, "nope_#{System.unique_integer([:positive])}")

      assert_raise RuntimeError, ~r/refused the credentials/, fn ->
        PostgresPreflight.check!(opts)
      end
    end
  end
end
