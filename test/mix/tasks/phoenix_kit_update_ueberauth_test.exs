defmodule Mix.Tasks.PhoenixKit.Update.UeberauthConfigTest do
  @moduledoc """
  I103, finding 2 (MEDIUM): `fix_ueberauth_providers_config/2` used to build
  its regex candidate from `content` the CALLER
  (`validate_and_fix_ueberauth_config/1`) had already read off disk, then
  unconditionally overwrite the Igniter buffer with it. On a real `mix
  phoenix_kit.update` run, `BasicConfiguration.add_basic_config/1` and
  `PrefixConfig.add_prefix_configuration/2` both write to
  `config/config.exs` earlier in the SAME pipeline — Igniter never flushes
  those writes to disk before this step runs, so the stale-content-based
  overwrite silently discarded them.

  Reproduced here the same way as `PhoenixKit.Install.BootHookTest`: an
  Igniter "probe" — stage an edit to config/config.exs, then run the fixed
  function, and confirm the earlier edit survives.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  alias Mix.Tasks.PhoenixKit.Update

  @config_file "config/config.exs"

  @initial_content """
  import Config

  config :ueberauth, Ueberauth,
    providers: []
  """

  defp config_content(igniter) do
    igniter.rewrite |> Rewrite.source!(@config_file) |> Rewrite.Source.get(:content)
  end

  # Stands in for `PrefixConfig.add_prefix_configuration/2` (or
  # `BasicConfiguration.add_basic_config/1`): an earlier step in the SAME
  # pipeline run staging an edit to the SAME file.
  defp stage_prefix_backfill(igniter) do
    Igniter.update_file(igniter, @config_file, fn source ->
      content = Rewrite.Source.get(source, :content)
      updated = content <> "\nconfig :phoenix_kit, prefix: \"acme\"\n"
      Rewrite.Source.update(source, :content, updated)
    end)
  end

  test "does not discard an earlier step's edit to config/config.exs" do
    igniter =
      test_project(files: %{@config_file => @initial_content})
      |> stage_prefix_backfill()
      |> Update.fix_ueberauth_providers_config()
      |> apply_igniter!()

    content = config_content(igniter)

    assert content =~ ~r/config :phoenix_kit, prefix: "acme"/,
           "the earlier step's prefix backfill was discarded:\n#{content}"

    assert content =~ "providers: %{}",
           "the ueberauth fix itself did not land:\n#{content}"

    refute content =~ "providers: []"
  end

  test "rolls back instead of reporting success when the match isn't a real config call" do
    # The regex has no notion of strings — it matches the same text whether
    # it names a real `config :ueberauth, Ueberauth, providers: []` call or
    # just happens to appear inside a string literal. The replacement still
    # produces syntactically valid Elixir either way (a string's contents
    # don't affect parse validity), so only the semantic check —
    # confirming a REAL `config(:ueberauth, Ueberauth, providers: %{})` call
    # exists in the AST — catches this and rolls back instead of reporting
    # success over nothing.
    weird = ~s(some_string = "config :ueberauth, Ueberauth, providers: []"\n)

    igniter =
      test_project(files: %{@config_file => weird})
      |> Update.fix_ueberauth_providers_config()
      |> apply_igniter!()

    assert config_content(igniter) == weird
  end
end
