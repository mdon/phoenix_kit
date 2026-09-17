defmodule Mix.Tasks.PhoenixKit.Update.NoStartOptionTest do
  @moduledoc """
  `mix phoenix_kit.update --no-start` exists to break a deadlock a
  column-adding release creates on a host whose supervision tree queries at
  init: the freshly compiled schema module selects a column the database has
  not got, so `Mix.Task.run("app.start")` — which the full update needs —
  brings the boot down with Postgres 42703, and the updater that would add the
  column never runs.

  The flag is declared in TWO places that must agree: Igniter's `info/2`
  schema and the `OptionParser.parse/2` switches inside the `run/1` override.
  Miss either and the flag is swallowed (Igniter errors on an unknown switch;
  OptionParser silently drops it and the task takes the app-starting path —
  the very path the flag exists to avoid). Nothing else checks that pair.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Update

  @task_source "lib/mix/tasks/phoenix_kit.update.ex"

  describe "the --no-start switch is declared where the task reads options" do
    test "info/2 declares it, so Igniter accepts the flag" do
      %Igniter.Mix.Task.Info{schema: schema} = Update.info(["--no-start"], nil)

      assert schema[:no_start] == :boolean
    end

    test "the run/1 OptionParser declares it, so the flag is not silently dropped" do
      # run/1 parses argv itself before Igniter ever sees it; an undeclared
      # switch there parses as `{[], ["--no-start"], []}` and the task falls
      # through to the app-starting branch.
      source = File.read!(@task_source)

      [_, switches_block] =
        Regex.run(~r/OptionParser\.parse\(argv,\s*switches:\s*\[(.*?)\]/s, source)

      assert switches_block =~ "no_start: :boolean"
    end
  end

  describe "discoverability" do
    test "--help documents the flag and the error that sends you to it" do
      help =
        ExUnit.CaptureIO.capture_io(fn ->
          Update.run(["--help"])
        end)

      assert help =~ "--no-start"
      # The symptom, not just the flag: 42703 is what a host operator sees.
      assert help =~ "does not exist"
    end
  end
end
