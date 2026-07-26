defmodule PhoenixKit.Install.ObanConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.ObanConfig

  describe "oban_block_missing_prefix?/1" do
    test "true when the Oban block lacks prefix:" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]

      config :my_app, MyAppWeb.Endpoint, url: [host: "localhost"]
      """

      assert ObanConfig.oban_block_missing_prefix?(content)
    end

    test "false when the Oban block carries prefix:" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        prefix: "companyplexus",
        queues: [default: 10]
      """

      refute ObanConfig.oban_block_missing_prefix?(content)
    end

    test "a phoenix_kit prefix entry OUTSIDE the Oban block does not satisfy the check" do
      # Regression: a whole-file `prefix:` grep is satisfied by the
      # config :phoenix_kit, prefix: line the installer itself writes,
      # silencing the warning exactly when it's needed.
      content = """
      config :phoenix_kit, prefix: "companyplexus"

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]
      """

      assert ObanConfig.oban_block_missing_prefix?(content)
    end

    test "computed prefix values count as configured" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        prefix: System.get_env("OBAN_PREFIX"),
        queues: [default: 10]
      """

      refute ObanConfig.oban_block_missing_prefix?(content)
    end

    test "false when there is no Oban block at all" do
      refute ObanConfig.oban_block_missing_prefix?("config :my_app, key: :value\n")
    end

    test "block detection stops at the next top-level config entry" do
      # prefix: in a LATER unrelated block must not count for Oban
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]

      config :other_lib, prefix: "companyplexus"
      """

      assert ObanConfig.oban_block_missing_prefix?(content)
    end

    test "a commented-out example Oban block is not a real block (no false positive)" do
      content = """
      # Example:
      # config :my_app, Oban,
      #   repo: MyApp.Repo,
      #   queues: [default: 10]

      config :my_app, MyAppWeb.Endpoint, url: [host: "localhost"]
      """

      refute ObanConfig.oban_block_missing_prefix?(content)
    end

    test "a commented block mentioning prefix: does not mask a real block lacking it" do
      # Regression: a commented-out block that happens to contain
      # `prefix:` must not satisfy the check for the genuinely active
      # Oban block below it, which lacks one.
      content = """
      # config :my_app, Oban,
      #   prefix: "example",
      #   queues: [default: 10]

      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]
      """

      assert ObanConfig.oban_block_missing_prefix?(content)
    end
  end

  describe "ensure_lifeline_plugin/2" do
    test "adds the Lifeline plugin when the plugins list has a trailing comma" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10],
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
        ]
      """

      updated = ObanConfig.ensure_lifeline_plugin(content, "my_app")

      assert updated =~ "{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}"
      # Still valid-looking: the plugin was inserted inside the same block.
      assert updated =~ ~r/plugins:\s*\[.*Oban\.Plugins\.Lifeline.*\]/s
    end

    test "adds the Lifeline plugin when the plugins list has no trailing comma" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10],
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30}
        ]
      """

      updated = ObanConfig.ensure_lifeline_plugin(content, "my_app")

      assert updated =~ "{Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}"
    end

    test "is a no-op when the Lifeline plugin is already present" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10],
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
          {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(60)}
        ]
      """

      assert ObanConfig.ensure_lifeline_plugin(content, "my_app") == content
    end

    test "a bare (no-opts) Oban.Plugins.Lifeline entry also counts as already present" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10],
        plugins: [
          Oban.Plugins.Lifeline
        ]
      """

      assert ObanConfig.ensure_lifeline_plugin(content, "my_app") == content
    end

    test "closes at the plugins-block bracket, not the Cron crontab's nested one" do
      # The real generated config always carries a Cron plugin with a
      # nested `crontab: [...]` list. A lazy match to the FIRST `]` used
      # to insert Lifeline INSIDE that list, corrupting the config
      # (review finding). The close is anchored to the `plugins:`
      # keyword's own indentation, which nested lists never share.
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 30},
          {Oban.Plugins.Cron,
           crontab: [
             {"* * * * *", PhoenixKit.ScheduledJobs.Workers.ProcessScheduledJobsWorker}
           ]}
        ]
      """

      updated = ObanConfig.ensure_lifeline_plugin(content, "my_app")

      assert updated =~ "Oban.Plugins.Lifeline"

      # Lifeline landed as a SIBLING of Cron (after its closing `]}`),
      # not inside the crontab list.
      assert updated =~ ~r/\]\}[,]?\n\s+\{Oban\.Plugins\.Lifeline/

      refute updated =~ ~r/crontab: \[[^\]]*Lifeline/s

      # Still parseable Elixir.
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "inserted entry inherits the block's own indentation" do
      content = """
      config :my_app, Oban,
          plugins: [
            {Oban.Plugins.Pruner, max_age: 60}
          ]
      """

      updated = ObanConfig.ensure_lifeline_plugin(content, "my_app")

      # plugins: at 4 spaces -> entries at 6.
      assert updated =~ "\n      {Oban.Plugins.Lifeline"
      assert {:ok, _} = Code.string_to_quoted(updated)
    end

    test "leaves content unchanged when no plugins: block can be found" do
      content = """
      config :my_app, Oban,
        repo: MyApp.Repo,
        queues: [default: 10]
      """

      assert ObanConfig.ensure_lifeline_plugin(content, "my_app") == content
    end

    test "rescue_after stays above every worker timeout PhoenixKit ships" do
      # Lifeline rescues purely by elapsed time and never checks whether the
      # node is still alive, so a rescue_after at or below a real job's
      # runtime re-runs that job concurrently with the still-live original
      # (duplicate deliveries, duplicate syncs). Any worker that declares a
      # longer timeout/1 — or a new long-running one — must move this value
      # up, not the other way around.
      content = """
      config :my_app, Oban,
        plugins: [
          {Oban.Plugins.Pruner, max_age: 60}
        ]
      """

      updated = ObanConfig.ensure_lifeline_plugin(content, "my_app")

      [rescue_after_minutes] =
        Regex.run(~r/rescue_after: :timer\.minutes\((\d+)\)/, updated, capture: :all_but_first)

      rescue_after = :timer.minutes(String.to_integer(rescue_after_minutes))

      longest_worker_timeout =
        [
          PhoenixKit.Modules.Storage.Workers.SyncFilesJob,
          PhoenixKit.Modules.Storage.ProcessFileJob,
          PhoenixKit.Modules.Sitemap.SchedulerWorker
        ]
        |> Enum.map(& &1.timeout(%Oban.Job{}))
        |> Enum.max()

      assert rescue_after > longest_worker_timeout
    end
  end
end
