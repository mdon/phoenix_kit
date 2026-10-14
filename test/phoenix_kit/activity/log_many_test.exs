defmodule PhoenixKit.Activity.LogManyTest do
  @moduledoc """
  `Activity.log_many/2`: a batch of entries in one INSERT with one broadcast.
  Entries are read back from the database; the INSERT count is counted from
  the repo's telemetry.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Test.Fixtures

  setup do
    PubSub.subscribe(Activity.pubsub_topic())
    %{user: Fixtures.user_fixture()}
  end

  defp entry(n, extra \\ %{}) do
    Map.merge(%{action: "widget.bulk_created", module: "widgets", metadata: %{"n" => n}}, extra)
  end

  defp stored(%Entry{uuid: uuid}), do: Repo.get!(Entry, uuid)

  # The INSERT statements run on the activities table while `fun` runs.
  defp count_inserts(fun) do
    counter = :counters.new(1, [])
    test_pid = self()
    handler = "log-many-inserts-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:phoenix_kit, :test, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test_pid and metadata.query =~ ~s(INSERT INTO "phoenix_kit_activities") do
          :counters.add(counter, 1, 1)
        end
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {result, :counters.get(counter, 1)}
  end

  describe "storing" do
    test "inserts every entry with one INSERT, in input order", %{user: user} do
      attrs =
        for n <- 1..40 do
          entry(n, %{
            actor_uuid: user.uuid,
            resource_type: "widget",
            resource_uuid: UUIDv7.generate(),
            mode: "auto"
          })
        end

      {{:ok, entries}, inserts} = count_inserts(fn -> Activity.log_many(attrs) end)

      assert inserts == 1
      assert length(entries) == 40
      assert Enum.map(entries, & &1.metadata["n"]) == Enum.to_list(1..40)

      # Strictly increasing, so the Activity page lists them as given.
      times = Enum.map(entries, & &1.inserted_at)
      assert times == Enum.sort(times, DateTime)
      assert length(Enum.uniq(times)) == 40

      for {entry, attr} <- Enum.zip(entries, attrs) do
        row = stored(entry)
        assert row.uuid == entry.uuid
        assert row.action == "widget.bulk_created"
        assert row.module == "widgets"
        assert row.mode == "auto"
        assert row.actor_uuid == user.uuid
        assert row.resource_type == "widget"
        assert row.resource_uuid == attr.resource_uuid
        assert row.metadata == attr.metadata
        refute row.permanent
      end
    end

    test "a missing metadata is an empty map, as with log/1" do
      assert {:ok, [entry]} = Activity.log_many([%{action: "widget.touched"}])
      assert stored(entry).metadata == %{}
    end

    test "permanent is taken only as the atom key with true" do
      assert {:ok, [kept, string_key, falsy]} =
               Activity.log_many([
                 entry(1, %{permanent: true}),
                 %{"action" => "widget.bulk_created", "permanent" => true},
                 entry(3, %{permanent: "true"})
               ])

      assert stored(kept).permanent
      refute stored(string_key).permanent
      refute stored(falsy).permanent
    end

    test "an empty list stores nothing and costs no query" do
      {result, inserts} = count_inserts(fn -> Activity.log_many([]) end)

      assert result == {:ok, []}
      assert inserts == 0
      refute_received {:activity_logged, _}
    end

    test "opts default to none" do
      assert {:ok, [_]} = Activity.log_many([entry(1)], [])
    end
  end

  describe "invalid entries" do
    test "are dropped and reported at error level; the rest are stored" do
      attrs = [
        entry(1),
        %{module: "widgets"},
        entry(3, %{action: String.duplicate("a", 101)}),
        entry(4, %{module: String.duplicate("m", 51)}),
        entry(5, %{metadata: "not a map"}),
        :not_a_map,
        Map.put(entry(7), "permanent", true),
        entry(8)
      ]

      # `level: :error` captures nothing below error: a drop logged as a
      # warning would leave the log empty here.
      log =
        capture_log([level: :error], fn ->
          assert {:ok, entries} = Activity.log_many(attrs)
          send(self(), {:entries, entries})
        end)

      assert_received {:entries, entries}
      assert Enum.map(entries, & &1.metadata["n"]) == [1, 8]

      for index <- [1, 2, 3, 4, 5, 6] do
        assert log =~ "dropped entry #{index}"
      end

      assert log =~ "not a map"
      assert log =~ "mixed keys"
      refute log =~ "dropped entry 0"
      refute log =~ "dropped entry 7"
    end

    test "the log names positions and reasons, never a value of the entry" do
      secret = "SECRET-PAYLOAD-4711"

      attrs = [
        entry(1, %{metadata: secret}),
        secret,
        {:tuple, secret},
        Map.put(entry(4, %{metadata: %{"token" => secret}}), "permanent", secret),
        entry(5, %{action: String.duplicate(secret, 10)}),
        %{module: secret},
        entry(7)
      ]

      log =
        capture_log([level: :error], fn ->
          assert {:ok, [_still_valid]} = Activity.log_many(attrs)
        end)

      for index <- 0..5 do
        assert log =~ "dropped entry #{index}"
      end

      refute log =~ secret
    end

    test "the drops of one call make ONE error line: the count, and the reasons" do
      attrs = [entry(0), %{}, entry(2), :not_a_map, %{module: "x"}]

      log = capture_log([level: :error], fn -> Activity.log_many(attrs) end)

      assert [line] = String.split(log, "\n", trim: true)
      assert line =~ "Activity.log_many dropped 3 of 5 entries: "
      assert line =~ "dropped entry 1: "
      assert line =~ "dropped entry 3: not a map"
      assert line =~ "dropped entry 4: "
    end

    test "a flood of invalid entries is one line that spells out the first twenty" do
      log = capture_log([level: :error], fn -> Activity.log_many(List.duplicate(%{}, 30)) end)

      assert [line] = String.split(log, "\n", trim: true)
      assert line =~ "dropped 30 of 30 entries"
      assert line =~ "dropped entry 19: "
      refute line =~ "dropped entry 20: "
      assert line =~ "; and 10 more"
    end

    test "a valid batch logs no error line" do
      assert capture_log([level: :error], fn -> Activity.log_many([entry(1), entry(2)]) end) == ""
    end

    test "all invalid: nothing stored, nothing announced" do
      {log, inserts} =
        count_inserts(fn ->
          capture_log([level: :error], fn ->
            send(self(), {:result, Activity.log_many([%{}, %{module: "x"}])})
          end)
        end)

      assert_received {:result, {:ok, []}}
      assert log =~ "dropped entry 0"
      assert log =~ "dropped entry 1"
      assert inserts == 0
      refute_received {:activity_logged, _}
    end
  end

  describe "the broadcast" do
    test "is ONE {:activity_logged, entry} message, carrying the last entry" do
      assert {:ok, entries} = Activity.log_many(for n <- 1..5, do: entry(n))
      last = List.last(entries)

      assert_receive {:activity_logged, %Entry{uuid: uuid}}
      assert uuid == last.uuid
      refute_receive {:activity_logged, _}, 100
    end

    test "broadcast: false stores and announces nothing" do
      assert {:ok, [_, _]} = Activity.log_many([entry(1), entry(2)], broadcast: false)

      refute_receive {:activity_logged, _}, 100
    end

    test "Activity.broadcast/1 announces a quiet batch afterwards" do
      {:ok, entries} = Activity.log_many([entry(1), entry(2)], broadcast: false)

      assert :ok = Activity.broadcast(List.last(entries))
      assert_receive {:activity_logged, %Entry{}}
    end
  end

  describe "never raises into the caller" do
    test "a value the database cannot take fails the whole batch, and nothing is stored" do
      log =
        capture_log(fn ->
          result =
            Activity.log_many([
              entry(1),
              entry(2, %{metadata: %{"bad" => {"SECRET-DB-4711", :tuple}}})
            ])

          send(self(), {:result, result})
        end)

      assert_received {:result, {:error, error}}
      assert is_exception(error)
      assert log =~ "Activity logging error"
      refute log =~ "SECRET-DB-4711"

      assert Repo.aggregate(from(e in Entry, where: e.action == "widget.bulk_created"), :count) ==
               0

      refute_received {:activity_logged, _}
    end

    test "over the batch cap is refused before any work" do
      {result, inserts} =
        count_inserts(fn -> Activity.log_many(List.duplicate(entry(1), 1_001)) end)

      assert result == {:error, :too_many_entries}
      assert inserts == 0
    end

    test "the cap itself is accepted" do
      assert {:ok, entries} = Activity.log_many(List.duplicate(entry(1), 1_000))
      assert length(entries) == 1_000
    end
  end

  describe "repo failures" do
    defmodule FailingRepo do
      @moduledoc false
      def insert_all(_schema, _rows, _opts), do: fail(Process.get(:log_many_failure))

      defp fail(:raise), do: raise("boom")
      defp fail(:exit), do: exit(:pool_down)
      defp fail(:throw), do: throw(:thrown)
    end

    setup do
      previous = Application.get_env(:phoenix_kit, :repo)
      Application.put_env(:phoenix_kit, :repo, FailingRepo)
      on_exit(fn -> Application.put_env(:phoenix_kit, :repo, previous) end)
    end

    for kind <- [:raise, :exit, :throw] do
      test "a #{kind} from the repo comes back as {:error, _}" do
        Process.put(:log_many_failure, unquote(kind))

        capture_log(fn -> send(self(), {:result, Activity.log_many([entry(1)])}) end)

        assert_received {:result, {:error, _reason}}
        refute_received {:activity_logged, _}
      end
    end
  end
end
