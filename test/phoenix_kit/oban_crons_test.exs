defmodule PhoenixKit.ObanCronsTest do
  @moduledoc """
  Cron jobs declared by modules (`oban_crons/0`): what is collected and what is dropped,
  and what `mix phoenix_kit.install` / `mix phoenix_kit.update` write into a host's Oban
  config.

  What the host relies on: every declared worker ends up scheduled once, a schedule the
  host set is never changed, an entry the host commented out stays out, a bad declaration
  never reaches the config (Oban would refuse to boot), and two modules that disagree are
  reported rather than silently merged.
  """
  # async: false - the updater tests swap the global Mix shell and register a module.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Igniter.Test

  alias PhoenixKit.Install.ObanConfig
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.ObanCrons

  defmodule NightlyWorker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule HourlyWorker do
    use Oban.Worker, queue: :default

    @impl Oban.Worker
    def perform(_job), do: :ok
  end

  defmodule NotAWorker do
    def helper, do: :ok
  end

  defmodule AlphaModule do
    def enabled?, do: true
    def oban_crons, do: [{"0 5 * * *", NightlyWorker}, {"@hourly", HourlyWorker}]
  end

  defmodule BetaModule do
    def enabled?, do: true
    # The same entry as Alpha: a shared declaration, not a conflict.
    def oban_crons, do: [{"0 5 * * *", NightlyWorker}]
  end

  defmodule RivalModule do
    def enabled?, do: true
    # Same worker, another schedule: a conflict.
    def oban_crons, do: [{"30 6 * * *", NightlyWorker}]
  end

  defmodule BrokenModule do
    def oban_crons do
      [
        {"not a cron", NightlyWorker},
        {"0 5 * * *", Nope.DoesNotExist},
        {"0 5 * * *", NotAWorker},
        {"0 5 * * *", NightlyWorker, args: %{a: 1}},
        {"0 5 * * *", "NightlyWorker"},
        :junk,
        {"15 4 * * *", HourlyWorker}
      ]
    end
  end

  defmodule OneBadEntryModule do
    def oban_crons, do: [{"not a cron", NightlyWorker}]
  end

  defmodule NotAListModule do
    def oban_crons, do: %{"0 5 * * *" => NightlyWorker}
  end

  defmodule RaisingModule do
    def oban_crons, do: raise("boom")
  end

  defmodule SilentModule do
  end

  defmodule DefaultsModule do
    use PhoenixKit.Module

    @impl PhoenixKit.Module
    def module_key, do: "oban_crons_defaults_fake"
    @impl PhoenixKit.Module
    def module_name, do: "Oban crons defaults fake"
    @impl PhoenixKit.Module
    def enabled?, do: true
    @impl PhoenixKit.Module
    def enable_system, do: :ok
    @impl PhoenixKit.Module
    def disable_system, do: :ok
  end

  defmodule OverridingModule do
    use PhoenixKit.Module

    @impl PhoenixKit.Module
    def module_key, do: "oban_crons_overriding_fake"
    @impl PhoenixKit.Module
    def module_name, do: "Oban crons overriding fake"
    @impl PhoenixKit.Module
    def enabled?, do: true
    @impl PhoenixKit.Module
    def enable_system, do: :ok
    @impl PhoenixKit.Module
    def disable_system, do: :ok

    @impl PhoenixKit.Module
    def oban_crons, do: [{"0 5 * * *", NightlyWorker}]
  end

  defmodule SpacedModule do
    # The same schedule as Alpha's, spelled with extra blanks and a line break.
    def oban_crons, do: [{"  0  5 * *\n* ", NightlyWorker}]
  end

  # An Erlang-style module name: it has perform/1 but is not an `Elixir.` alias.
  defmodule :oban_crons_erlang_style_worker do
    def perform(_job), do: :ok
  end

  defmodule ErlangStyleModule do
    def oban_crons,
      do: [{"0 5 * * *", :oban_crons_erlang_style_worker}, {"15 4 * * *", HourlyWorker}]
  end

  describe "use PhoenixKit.Module" do
    test "oban_crons/0 defaults to no crons, can be overridden, and is optional" do
      assert DefaultsModule.oban_crons() == []
      assert OverridingModule.oban_crons() == [{"0 5 * * *", NightlyWorker}]

      assert {[{"0 5 * * *", NightlyWorker}], []} =
               ObanCrons.declared([DefaultsModule, OverridingModule])

      assert {:oban_crons, 0} in PhoenixKit.Module.behaviour_info(:optional_callbacks)
      assert {:oban_crons, 0} in PhoenixKit.Module.behaviour_info(:callbacks)
    end
  end

  describe "declared/1" do
    test "collects the entries of the modules, one per worker, in module-name order" do
      assert {[{"0 5 * * *", NightlyWorker}, {"@hourly", HourlyWorker}], []} =
               ObanCrons.declared([AlphaModule])
    end

    test "a module without the callback declares nothing" do
      assert {[], []} = ObanCrons.declared([SilentModule])
    end

    test "the same entry declared twice is one entry and no conflict" do
      assert {[{"0 5 * * *", NightlyWorker}, {"@hourly", HourlyWorker}], []} =
               ObanCrons.declared([BetaModule, AlphaModule, AlphaModule])
    end

    test "one worker with two schedules keeps the first module's and reports the conflict" do
      {entries, conflicts} = ObanCrons.declared([RivalModule, AlphaModule])

      assert {"0 5 * * *", NightlyWorker} in entries
      refute {"30 6 * * *", NightlyWorker} in entries

      assert [
               %{
                 worker: NightlyWorker,
                 kept: {"0 5 * * *", NightlyWorker},
                 kept_owner: AlphaModule,
                 ignored: {"30 6 * * *", NightlyWorker},
                 ignored_owner: RivalModule
               } = conflict
             ] = conflicts

      assert ObanCrons.describe_conflict(conflict) =~ "keeping \"0 5 * * *\""
    end

    test "drops what Oban would refuse to boot with, warns, and keeps the valid entry" do
      log =
        capture_log(fn ->
          assert {[{"15 4 * * *", HourlyWorker}], []} = ObanCrons.declared([BrokenModule])
        end)

      assert log =~ "ignoring invalid Oban cron declaration"
      assert log =~ "not a cron"
      assert log =~ "Nope.DoesNotExist"
      assert log =~ "NotAWorker"
    end

    test "schedules spelled with different blanks are one schedule, not a conflict" do
      assert {[{"0 5 * * *", NightlyWorker}, {"@hourly", HourlyWorker}], []} =
               ObanCrons.declared([AlphaModule, SpacedModule])
    end

    test "a worker whose name is not an Elixir alias is dropped, the rest kept" do
      log =
        capture_log(fn ->
          assert {[{"15 4 * * *", HourlyWorker}], []} = ObanCrons.declared([ErlangStyleModule])
        end)

      assert log =~ "ignoring invalid Oban cron declaration"
    end

    test "a callback that raises, or returns a non-list, contributes nothing" do
      log =
        capture_log(fn ->
          assert {[{"0 5 * * *", NightlyWorker}, {"@hourly", HourlyWorker}], []} =
                   ObanCrons.declared([AlphaModule, RaisingModule, NotAListModule])
        end)

      assert log =~ "RaisingModule.oban_crons/0 failed"
      assert log =~ "declared Oban crons as"
    end
  end

  describe "the updater's backfill" do
    @host """
    config :my_app, Oban,
      repo: MyApp.Repo,
      plugins: [
        {Oban.Plugins.Cron,
         crontab: [
           {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
         ]}
      ]
    """

    setup do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
      %{declared: elem(ObanCrons.declared([AlphaModule]), 0)}
    end

    test "adds the declared entries and the result parses", %{declared: declared} do
      updated = ObanConfig.ensure_module_cron_entries(@host, "my_app", declared)

      assert updated =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
      assert updated =~ ~s({"@hourly", PhoenixKit.ObanCronsTest.HourlyWorker})
      assert {:ok, _} = Code.string_to_quoted(updated)
      assert_received {:mix_shell, :info, [info]}
      assert info =~ "Adding module cron entries"
    end

    test "is idempotent", %{declared: declared} do
      once = ObanConfig.ensure_module_cron_entries(@host, "my_app", declared)

      assert ObanConfig.ensure_module_cron_entries(once, "my_app", declared) == once
    end

    test "never changes the schedule of a worker the host already scheduled", %{
      declared: declared
    } do
      host = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker},
             {"7 7 * * 7", PhoenixKit.ObanCronsTest.NightlyWorker}
           ]}
        ]
      """

      updated = ObanConfig.ensure_module_cron_entries(host, "my_app", declared)

      assert updated =~ ~s({"7 7 * * 7", PhoenixKit.ObanCronsTest.NightlyWorker})
      refute updated =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
      assert updated =~ ~s({"@hourly", PhoenixKit.ObanCronsTest.HourlyWorker})
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "leaves out an entry the host commented out (a declined entry)", %{declared: declared} do
      host = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
             # {"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker}
           ]}
        ]
      """

      updated = ObanConfig.ensure_module_cron_entries(host, "my_app", declared)

      refute updated =~ ~r/^\s*\{"0 5 \* \* \*", PhoenixKit.ObanCronsTest.NightlyWorker\}/m
      assert updated =~ "# {\"0 5 * * *\", PhoenixKit.ObanCronsTest.NightlyWorker}"
      assert updated =~ ~s({"@hourly", PhoenixKit.ObanCronsTest.HourlyWorker})
      assert_received {:mix_shell, :info, [declined]}
      assert declined =~ "commented out"
    end

    test "says nothing and changes nothing when no module declares a cron" do
      assert ObanConfig.ensure_module_cron_entries(@host, "my_app", []) == @host
      refute_received {:mix_shell, _, _}
    end

    test "reports two modules that disagree about a worker's schedule on the error channel" do
      ModuleRegistry.register(AlphaModule)
      ModuleRegistry.register(RivalModule)

      try do
        updated = ObanConfig.ensure_module_cron_entries(@host, "my_app")

        assert_received {:mix_shell, :error, [conflict]}
        assert conflict =~ "keeping \"0 5 * * *\""
        assert updated =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
        refute updated =~ "30 6 * * *"
      after
        ModuleRegistry.unregister(AlphaModule)
        ModuleRegistry.unregister(RivalModule)
      end
    end

    test "the generated crontab lines sit at the indentation of the entries around them", %{
      declared: declared
    } do
      lines = ObanConfig.generated_module_cron_lines(declared)

      assert lines ==
               ",\n       {\"0 5 * * *\", PhoenixKit.ObanCronsTest.NightlyWorker}" <>
                 ",\n       {\"@hourly\", PhoenixKit.ObanCronsTest.HourlyWorker}"

      assert ObanConfig.generated_module_cron_lines([]) == ""
    end

    test "a fresh install writes the declared entries into the config it generates" do
      ModuleRegistry.register(AlphaModule)

      try do
        content =
          test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
          |> ObanConfig.add_oban_configuration()
          |> apply_igniter!()
          |> config_content()

        assert {:ok, _} = Code.string_to_quoted(content)
        assert content =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
        assert content =~ ~s({"@hourly", PhoenixKit.ObanCronsTest.HourlyWorker})

        # same column as the core entry above it
        assert indentation(
                 content,
                 "PhoenixKit.Notifications.DigestWorker, args: %{cadence: \"weekly\"}"
               ) ==
                 indentation(content, "PhoenixKit.ObanCronsTest.NightlyWorker")

        assert indentation(content, "PhoenixKit.ObanCronsTest.HourlyWorker") ==
                 indentation(content, "PhoenixKit.ObanCronsTest.NightlyWorker")
      after
        ModuleRegistry.unregister(AlphaModule)
      end
    end

    test "a fresh install reports two modules that disagree, once" do
      ModuleRegistry.register(AlphaModule)
      ModuleRegistry.register(RivalModule)

      try do
        test_project(app_name: :my_app, files: %{"config/config.exs" => "import Config\n"})
        |> ObanConfig.add_oban_configuration()
        |> apply_igniter!()

        assert_received {:mix_shell, :error, [conflict]}
        assert conflict =~ "keeping \"0 5 * * *\""
        refute_received {:mix_shell, :error, _}
      after
        ModuleRegistry.unregister(AlphaModule)
        ModuleRegistry.unregister(RivalModule)
      end
    end

    test "an update of an existing config asks the modules once" do
      ModuleRegistry.register(OneBadEntryModule)

      try do
        log =
          capture_log(fn ->
            test_project(
              app_name: :my_app,
              files: %{"config/config.exs" => "import Config\n\n" <> @host}
            )
            |> ObanConfig.add_oban_configuration()
            |> apply_igniter!()
          end)

        assert [_once] = Regex.scan(~r/ignoring invalid Oban cron declaration/, log)
      after
        ModuleRegistry.unregister(OneBadEntryModule)
      end
    end

    test "a worker whose name is the prefix of another's is not taken for it", %{
      declared: declared
    } do
      # Alpha declares NightlyWorker; the host's comment, and a variable-driven crontab,
      # only mention NightlyWorkerPlus (a different worker).
      commented = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
             # {"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorkerPlus}
           ]}
        ]
      """

      updated = ObanConfig.ensure_module_cron_entries(commented, "my_app", declared)

      assert updated =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
      refute_received {:mix_shell, :info, ["  ℹ️  Left out" <> _]}
      assert {:ok, _} = Code.string_to_quoted(updated)

      unverified = """
      crontab = [{"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorkerPlus}]

      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [{Oban.Plugins.Cron, crontab: crontab}]
      """

      assert ObanConfig.ensure_module_cron_entries(unverified, "my_app", declared) == unverified
      messages = shell_messages()
      assert Enum.any?(messages, &(&1 =~ "Could not add worker cron entries"))
      refute Enum.any?(messages, &(&1 =~ "Already configured"))
    end

    test "update_content/2 writes a registered module's entry into a whole Oban block" do
      ModuleRegistry.register(AlphaModule)

      try do
        updated = ObanConfig.update_content(@host, "my_app")

        assert updated =~ ~s({"0 5 * * *", PhoenixKit.ObanCronsTest.NightlyWorker})
        assert {:ok, _} = Code.string_to_quoted(updated)

        # a second run adds nothing
        assert ObanConfig.update_content(updated, "my_app") == updated
      after
        ModuleRegistry.unregister(AlphaModule)
      end
    end
  end

  defp shell_messages(acc \\ []) do
    receive do
      {:mix_shell, _kind, [message]} -> shell_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp config_content(igniter) do
    igniter.rewrite |> Rewrite.source!("config/config.exs") |> Rewrite.Source.get(:content)
  end

  defp indentation(content, needle) do
    line = content |> String.split("\n") |> Enum.find(&String.contains?(&1, needle))
    byte_size(line) - byte_size(String.trim_leading(line))
  end
end
