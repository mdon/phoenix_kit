defmodule PhoenixKit.API.FlowWorkersTest do
  @moduledoc "The three Oban workers of the dangerous-operation flow, run as Oban runs them."
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiFlowHarness

  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Confirm.ExpiryWorker
  alias PhoenixKit.API.Confirm.PruneWorker, as: ConfirmPruneWorker
  alias PhoenixKit.API.Idempotency
  alias PhoenixKit.API.Idempotency.PruneWorker, as: IdempotencyPruneWorker
  alias PhoenixKit.API.Idempotency.Record

  setup do
    setup_flow()
    %{agent: agent()}
  end

  test "the idempotency worker deletes expired records only" do
    now = DateTime.utc_now()

    {:claimed, old} =
      Idempotency.claim(
        "scope",
        "old-key-0123456789ab",
        String.duplicate("a", 64),
        DateTime.add(now, -48 * 3600, :second)
      )

    {:claimed, fresh} =
      Idempotency.claim("scope", "new-key-0123456789ab", String.duplicate("a", 64), now)

    assert :ok = IdempotencyPruneWorker.perform(%Oban.Job{})

    assert Repo.get(Record, old.uuid) == nil
    assert Repo.get(Record, fresh.uuid)
  end

  test "the expiry worker expires what ran out and fails what was left running", %{agent: agent} do
    t0 = DateTime.utc_now()
    # `Approvals.request/2` expires the old pending rows of the key it queues for, so the
    # second approval goes to another key: `waiting` must still be pending (and past its
    # time) when the worker runs, or the first half of this test would prove nothing.
    {:ok, waiting, :created} =
      queue(agent, "flowkit.delete_items", %{"ids" => ["a"]},
        now: DateTime.add(t0, -80 * 3600, :second)
      )

    assert Repo.get!(Confirmation, waiting.uuid).status == "pending"
    {:ok, stuck, :created} = queue(agent(), "flowkit.delete_items", %{"ids" => ["b"]})
    old = DateTime.add(t0, -1800, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(c in Confirmation, where: c.uuid == ^stuck.uuid),
      set: [status: "executing", updated_at: old]
    )

    assert :ok = ExpiryWorker.perform(%Oban.Job{})

    assert Repo.get!(Confirmation, waiting.uuid).status == "expired"
    assert Repo.get!(Confirmation, stuck.uuid).status == "failed"
  end

  test "the confirmation prune worker deletes old codes", %{agent: agent} do
    t0 = DateTime.utc_now()

    {:ok, issued} =
      Confirm.issue_token(
        agent.actor,
        "flowkit.delete_items",
        String.duplicate("1", 64),
        %{},
        String.duplicate("f", 64),
        DateTime.add(t0, -40 * 86_400, :second)
      )

    assert :ok = ConfirmPruneWorker.perform(%Oban.Job{})

    assert Repo.get(Confirmation, issued.row.uuid) == nil
  end
end
