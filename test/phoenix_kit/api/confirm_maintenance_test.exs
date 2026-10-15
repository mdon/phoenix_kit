defmodule PhoenixKit.API.ConfirmMaintenanceTest do
  @moduledoc """
  `Confirm.expire_due/1`, `sweep_stuck/2` and `prune/1`: what the cron workers do to the
  confirmation table, with the clock as a parameter.
  """
  use PhoenixKit.DataCase, async: false

  import PhoenixKit.Test.ApiFlowHarness

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.PubSub.Manager, as: PubSub

  @delete "flowkit.delete_items"

  setup do
    setup_flow()
    %{agent: agent()}
  end

  defp later(time, seconds), do: DateTime.add(time, seconds, :second)
  defp days(time, n), do: later(time, n * 86_400)
  defp row!(row), do: Repo.get!(Confirmation, row.uuid)

  defp set!(row, changes),
    do: Repo.update_all(from(c in Confirmation, where: c.uuid == ^row.uuid), set: changes)

  defp pending!(agent, id \\ "a", opts \\ []) do
    {:ok, row, :created} = queue(agent, @delete, %{"ids" => [id]}, opts)
    row
  end

  defp code!(agent, now) do
    {:ok, issued} =
      Confirm.issue_token(
        agent.actor,
        @delete,
        String.duplicate("1", 64),
        %{},
        String.duplicate("f", 64),
        now
      )

    issued.row
  end

  describe "expire_due/1" do
    test "expires pending approvals and unused codes whose time has passed, and clears the input",
         %{agent: agent} do
      t0 = DateTime.utc_now()
      approval = pending!(agent, "a", now: t0)
      code = code!(agent, t0)

      assert %{approvals: 0, tokens: 0} = Confirm.expire_due(later(t0, 60))

      assert %{approvals: 1, tokens: 1} = Confirm.expire_due(later(t0, 73 * 3600))

      assert %Confirmation{status: "expired", input: nil} = row!(approval)
      assert %Confirmation{status: "expired"} = row!(code)
    end

    test "leaves used codes and decided approvals alone", %{agent: agent} do
      t0 = DateTime.utc_now()
      used = code!(agent, t0)
      approved = pending!(agent, "b", now: t0)
      set!(used, status: "used")
      set!(approved, status: "executed")

      assert %{approvals: 0, tokens: 0} = Confirm.expire_due(later(t0, 100 * 3600))

      assert row!(used).status == "used"
      assert row!(approved).status == "executed"
    end

    test "announces the change to the approvals page", %{agent: agent} do
      t0 = DateTime.utc_now()
      pending!(agent, "a", now: t0)
      PubSub.subscribe("phoenix_kit:api:approvals")

      Confirm.expire_due(later(t0, 73 * 3600))

      assert_receive {:api_approval_changed, _}
    end
  end

  describe "sweep_stuck/2" do
    test "fails an approval left executing, keeping its partial results", %{agent: agent} do
      row = pending!(agent)
      old = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)

      set!(row,
        status: "executing",
        result: %{"partial" => %{"done" => 3}},
        updated_at: old,
        input: nil
      )

      assert Confirm.sweep_stuck() == 1

      swept = row!(row)
      assert swept.status == "failed"
      assert swept.input == nil
      assert swept.result["partial"] == %{"done" => 3}
      assert swept.result["error"]["code"] == "interrupted"
      assert swept.result["error"]["detail"] =~ "stopped"

      assert [entry] =
               Repo.all(
                 from(e in Entry,
                   where: e.action == "api.approval_finished" and e.resource_uuid == ^row.uuid
                 )
               )

      assert entry.metadata["status"] == "failed"
      assert entry.metadata["error_code"] == "interrupted"
    end

    test "fails an approval left approved, which never started", %{agent: agent} do
      row = pending!(agent)
      old = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)
      set!(row, status: "approved", updated_at: old)

      assert Confirm.sweep_stuck() == 1
      assert row!(row).status == "failed"
      assert row!(row).result["error"]["code"] == "interrupted"
      assert row!(row).input == nil
    end

    test "leaves a recent one alone, and one that reported progress a moment ago", %{agent: agent} do
      recent = pending!(agent, "a")
      busy = pending!(agent, "b")
      set!(recent, status: "executing")
      set!(busy, status: "executing", result: %{"partial" => %{"done" => 1}})

      assert Confirm.sweep_stuck() == 0
      assert row!(recent).status == "executing"
      assert row!(busy).status == "executing"
    end

    test "the staleness is a parameter, and pending or decided approvals are never swept", %{
      agent: agent
    } do
      stuck = pending!(agent, "a")
      waiting = pending!(agent, "b")
      done = pending!(agent, "c")
      old = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
      set!(stuck, status: "executing", updated_at: old)
      set!(waiting, updated_at: old)
      set!(done, status: "executed", updated_at: old)

      assert Confirm.sweep_stuck(DateTime.utc_now(), 60) == 1
      assert row!(waiting).status == "pending"
      assert row!(done).status == "executed"
    end

    test "a second sweep finds nothing", %{agent: agent} do
      row = pending!(agent)

      set!(row,
        status: "executing",
        updated_at: DateTime.add(DateTime.utc_now(), -1800, :second) |> DateTime.truncate(:second)
      )

      assert Confirm.sweep_stuck() == 1
      assert Confirm.sweep_stuck() == 0
    end
  end

  describe "prune/1" do
    test "deletes used codes 30 days after they ran out and decided approvals 30 days after their last change",
         %{agent: agent} do
      t0 = DateTime.utc_now()
      old_code = code!(agent, days(t0, -40))
      young_code = code!(agent, days(t0, -10))
      set!(old_code, status: "used")
      set!(young_code, status: "used")
      old_done = pending!(agent, "a")
      young_done = pending!(agent, "b")
      set!(old_done, status: "executed", updated_at: days(t0, -40) |> DateTime.truncate(:second))

      set!(young_done,
        status: "executed",
        updated_at: days(t0, -10) |> DateTime.truncate(:second)
      )

      assert Confirm.prune(t0) == 2

      assert Repo.get(Confirmation, old_code.uuid) == nil
      assert Repo.get(Confirmation, old_done.uuid) == nil
      assert Repo.get(Confirmation, young_code.uuid)
      assert Repo.get(Confirmation, young_done.uuid)
    end

    test "a code that was never used goes an hour after it ran out, not a month", %{agent: agent} do
      t0 = DateTime.utc_now()
      # Oldest first: a live code of the same call is handed out again (issue_token/6), so each
      # one must already have run out when the next is issued.
      marked_expired = code!(agent, DateTime.add(t0, -3 * 3600, :second))
      set!(marked_expired, status: "expired")
      long_gone = code!(agent, DateTime.add(t0, -2 * 3600, :second))
      just_ran_out = code!(agent, DateTime.add(t0, -30 * 60, :second))
      live = code!(agent, t0)

      assert Confirm.prune(t0) == 2

      assert Repo.get(Confirmation, long_gone.uuid) == nil
      assert Repo.get(Confirmation, marked_expired.uuid) == nil
      assert Repo.get(Confirmation, just_ran_out.uuid)
      assert Repo.get(Confirmation, live.uuid)
    end

    test "a used code is kept after an hour", %{agent: agent} do
      t0 = DateTime.utc_now()
      used = code!(agent, DateTime.add(t0, -2 * 3600, :second))
      set!(used, status: "used")

      assert Confirm.prune(t0) == 0
      assert Repo.get(Confirmation, used.uuid)
    end

    test "never deletes an approval that is waiting or running, however old", %{agent: agent} do
      t0 = DateTime.utc_now()
      ancient = days(t0, -400) |> DateTime.truncate(:second)
      pending = pending!(agent, "a")
      approved = pending!(agent, "b")
      running = pending!(agent, "c")
      set!(pending, updated_at: ancient)
      set!(approved, status: "approved", updated_at: ancient)
      set!(running, status: "executing", updated_at: ancient)

      assert Confirm.prune(t0) == 0
      assert Repo.aggregate(Confirmation, :count) == 3
    end

    test "rejected, stale, failed and expired approvals go too", %{agent: agent} do
      t0 = DateTime.utc_now()
      ancient = days(t0, -400) |> DateTime.truncate(:second)

      for {id, status} <- [{"a", "rejected"}, {"b", "stale"}, {"c", "failed"}, {"d", "expired"}] do
        set!(pending!(agent, id), status: status, updated_at: ancient)
      end

      assert Confirm.prune(t0) == 4
    end
  end
end
