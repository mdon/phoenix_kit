defmodule PhoenixKit.API.IdempotencyConcurrencyTest do
  @moduledoc """
  The claim rules under real concurrency: separate database sessions, real commits, no
  sandbox. The ordinary tests run the claims one after the other; these let the database
  interleave them and assert that exactly one request wins, whichever order they arrive in.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.Idempotency
  alias PhoenixKit.API.Idempotency.Record
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  @hash String.duplicate("a", 64)
  @rounds 10
  @callers 16

  setup do
    Sandbox.mode(Repo, :auto)
    cleanup()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      cleanup()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  defp cleanup, do: Repo.delete_all(from r in Record, where: like(r.scope_ref, "idem-race-%"))

  defp unique_key(round),
    do:
      "round-#{round}-" <>
        String.pad_leading(Integer.to_string(System.unique_integer([:positive])), 20, "0")

  defp concurrently(count, fun) do
    1..count
    |> Task.async_stream(fn _ -> fun.() end, max_concurrency: count, timeout: 30_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp claimed(results), do: Enum.count(results, &match?({:claimed, _}, &1))
  defp replayed(results), do: Enum.count(results, &match?({:replay, _}, &1))
  defp running(results), do: Enum.count(results, &(&1 == {:error, :in_progress}))

  test "simultaneous first claims of one key give one winner" do
    for round <- 1..@rounds do
      key = unique_key(round)

      results = concurrently(@callers, fn -> Idempotency.claim("idem-race-a", key, @hash) end)

      assert claimed(results) == 1, inspect(results)
      assert running(results) == @callers - 1, inspect(results)
      assert Repo.aggregate(from(r in Record, where: r.key == ^key), :count) == 1
    end
  end

  test "simultaneous retries of an expired lease give one takeover" do
    for round <- 1..@rounds do
      key = unique_key(round)
      t0 = DateTime.utc_now()
      {:claimed, _} = Idempotency.claim("idem-race-b", key, @hash, t0)
      retry_at = DateTime.add(t0, 200, :second)

      results =
        concurrently(@callers, fn -> Idempotency.claim("idem-race-b", key, @hash, retry_at) end)

      assert claimed(results) == 1, inspect(results)
      assert running(results) == @callers - 1, inspect(results)
    end
  end

  test "simultaneous retries of an expired stored answer give one takeover and no replay" do
    for round <- 1..@rounds do
      key = unique_key(round)
      t0 = DateTime.utc_now()
      {:claimed, claim} = Idempotency.claim("idem-race-c", key, @hash, t0)
      :ok = Idempotency.store(claim, ~s({"old":true}))
      retry_at = DateTime.add(t0, 25 * 3600, :second)

      results =
        concurrently(@callers, fn -> Idempotency.claim("idem-race-c", key, @hash, retry_at) end)

      assert claimed(results) == 1, inspect(results)
      assert replayed(results) == 0, inspect(results)
      assert running(results) == @callers - 1, inspect(results)
    end
  end

  test "a retry that meets a run which has just stored its answer does not run the request again" do
    key = unique_key(1)
    t0 = DateTime.utc_now()
    {:claimed, claim} = Idempotency.claim("idem-race-d", key, @hash, t0)
    parent = self()

    # The first run holds the row lock while it stores its answer. The retry has already
    # read the row as in_progress with an expired lease; its takeover waits for the lock.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from(r in Record, where: r.uuid == ^claim.uuid, lock: "FOR UPDATE", select: r.uuid)
          )

          send(parent, :locked)

          receive do
            :go -> :ok
          end

          Idempotency.store(claim, ~s({"finished":true}))
        end)
      end)

    assert_receive :locked, 5_000

    retry =
      Task.async(fn ->
        Idempotency.claim("idem-race-d", key, @hash, DateTime.add(t0, 200, :second))
      end)

    await_blocked_update()
    send(holder.pid, :go)

    assert {:ok, :ok} = Task.await(holder, 10_000)
    assert Task.await(retry, 10_000) == {:error, :in_progress}

    record = Repo.get!(Record, claim.uuid)
    assert record.state == "done"
    assert record.response == ~s({"finished":true})
  end

  # Polls until the retry's UPDATE is waiting on a row lock. The retry cannot have read
  # the row before it got there, so the lock holder is released only afterwards.
  defp await_blocked_update(attempts \\ 200) do
    %{rows: [[blocked]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity " <>
          "WHERE wait_event_type = 'Lock' AND query LIKE 'UPDATE%phoenix_kit_api_idempotency%'"
      )

    cond do
      blocked >= 1 ->
        :ok

      attempts == 0 ->
        flunk("the retry never reached the row lock")

      true ->
        Process.sleep(10)
        await_blocked_update(attempts - 1)
    end
  end
end
