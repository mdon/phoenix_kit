defmodule PhoenixKit.API.ApprovalsConcurrencyTest do
  @moduledoc """
  The per-key rules of the approval queue under real concurrency: separate database
  sessions, real commits, no sandbox. The ordinary tests run the requests one after the
  other; these let the database interleave them and assert that two simultaneous requests
  can neither both create the same approval nor both pass the cap, and that a burst of
  approvals of one key sends one notice.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Approvals.Notifier
  alias PhoenixKit.API.Canonical
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.FlowConfig
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Test.Repo

  @moduletag :integration

  @tool "raceapi.delete_items"
  @callers 12

  setup do
    Sandbox.mode(Repo, :auto)
    user = KeyTestSupport.register_user!()
    prefix = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    key =
      Repo.insert!(%Key{
        name: "approvals-race-#{prefix}",
        prefix: prefix,
        secret_hash: :crypto.strong_rand_bytes(32),
        scopes: [],
        requires_approval: true,
        user_uuid: user.uuid,
        created_by_uuid: user.uuid
      })

    actor = %Actor{
      kind: :key,
      key_uuid: key.uuid,
      key_prefix: prefix,
      user_uuid: user.uuid,
      requires_approval: true
    }

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.query!("DELETE FROM phoenix_kit_notifications WHERE metadata->>'dedupe_key' = $1", [
        "api:approvals:" <> key.uuid
      ])

      Repo.query!(
        "DELETE FROM phoenix_kit_activities " <>
          "WHERE action = 'api.approval_requested' AND metadata->>'key_prefix' = $1",
        [prefix]
      )

      Repo.delete_all(from c in Confirmation, where: c.actor_key_uuid == ^key.uuid)
      Repo.delete_all(from k in Key, where: k.uuid == ^key.uuid)
      Repo.delete_all(from u in PhoenixKit.Users.Auth.User, where: u.uuid == ^user.uuid)
      Sandbox.mode(Repo, :manual)
    end)

    %{actor: actor, key: key}
  end

  defp args(actor, ids) do
    input = %{"ids" => ids}

    %{
      actor: actor,
      tool: @tool,
      input: input,
      input_hash: Canonical.hash(@tool, input),
      preview: %{},
      fingerprint: String.duplicate("f", 64),
      context: %{}
    }
  end

  defp concurrently(count, fun) do
    1..count
    |> Task.async_stream(fun, max_concurrency: count, timeout: 60_000)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp rows(key),
    do: Repo.aggregate(from(c in Confirmation, where: c.actor_key_uuid == ^key.uuid), :count)

  test "simultaneous identical requests give one approval", %{actor: actor, key: key} do
    results = concurrently(@callers, fn _ -> Approvals.request(args(actor, ["a"])) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == 1, inspect(results)
    assert Enum.count(results, &match?({:ok, _, :existing}, &1)) == @callers - 1
    assert results |> Enum.map(fn {:ok, row, _} -> row.uuid end) |> Enum.uniq() |> length() == 1
    assert rows(key) == 1
  end

  test "simultaneous distinct requests never pass the cap", %{actor: actor, key: key} do
    max = FlowConfig.approval_pending_max()
    callers = max + 10

    results = concurrently(callers, fn n -> Approvals.request(args(actor, ["id-#{n}"])) end)

    assert Enum.count(results, &match?({:ok, _, :created}, &1)) == max, inspect(results)
    assert Enum.count(results, &(&1 == {:error, :pending_cap})) == callers - max
    assert rows(key) == max
  end

  test "a burst of approvals of one key sends one notice", %{actor: actor, key: key} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    pending =
      for n <- 1..@callers do
        %Confirmation{}
        |> Confirmation.changeset(%{
          kind: "approval",
          tool: @tool,
          input_hash: Canonical.hash(@tool, %{"ids" => ["n-#{n}"]}),
          fingerprint: String.duplicate("f", 64),
          input: %{"ids" => ["n-#{n}"]},
          actor_key_uuid: actor.key_uuid,
          preview: %{},
          status: "pending",
          expires_at: DateTime.add(now, 3600, :second)
        })
        |> Repo.insert!()
      end

    results =
      concurrently(@callers, fn n -> Notifier.notify_requested(Enum.at(pending, n - 1), now) end)

    assert Enum.count(results, &(&1 == :ok)) == 1, inspect(results)
    assert Enum.count(results, &(&1 == :throttled)) == @callers - 1

    claimed =
      Repo.aggregate(
        from(c in Confirmation,
          where: c.actor_key_uuid == ^key.uuid and not is_nil(c.notified_at)
        ),
        :count
      )

    assert claimed == 1
  end
end
