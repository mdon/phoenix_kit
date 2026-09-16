defmodule PhoenixKit.Migrations.Postgres.V191Test do
  @moduledoc """
  V191's `created_by_uuid` backfill, run against seeded activity entries.

  By the time any test runs the chain has already applied V191, so the
  column exists and the DDL statements are no-ops (`IF NOT EXISTS` /
  existence-checked). The backfill `UPDATE` is what is exercised: the
  migration exposes its statements via `up_statements/1` and this suite runs
  the REAL SQL against rows it seeds first.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Migrations.Postgres.V191
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp user! do
    email = "v191_#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{email: email, password: "ValidPassword123!"})
    user
  end

  defp created_activity!(actor, created, metadata) do
    %Entry{}
    |> Entry.changeset(%{
      action: "user.created",
      module: "users",
      mode: "manual",
      actor_uuid: actor && actor.uuid,
      resource_type: "user",
      resource_uuid: created.uuid,
      target_uuid: created.uuid,
      metadata: metadata
    })
    |> Repo.insert!()
  end

  defp run_up, do: Enum.each(V191.up_statements("public"), &Repo.query!/1)

  defp created_by(user), do: Repo.get!(Auth.User, user.uuid).created_by_uuid

  test "backfills the admin from a manual user.created entry" do
    admin = user!()
    created = user!()
    created_activity!(admin, created, %{"method" => "manual"})

    run_up()

    assert created_by(created) == admin.uuid
  end

  test "ignores entries that are not manual creations or have no actor" do
    admin = user!()
    not_manual = user!()
    no_actor = user!()
    created_activity!(admin, not_manual, %{"method" => "registration"})
    created_activity!(nil, no_actor, %{"method" => "manual"})

    run_up()

    assert created_by(not_manual) == nil
    assert created_by(no_actor) == nil
  end

  test "never overwrites a value already recorded" do
    admin = user!()
    other = user!()

    {:ok, created} =
      Auth.admin_create_user(
        %{
          "email" => "v191_kept_#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        },
        admin
      )

    created_activity!(other, created, %{"method" => "manual"})

    run_up()

    assert created_by(created) == admin.uuid
  end

  test "stamps the version marker" do
    run_up()

    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    assert marker == "191"
  end
end
