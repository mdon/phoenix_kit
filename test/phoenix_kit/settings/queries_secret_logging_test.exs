defmodule PhoenixKit.Settings.QueriesSecretLoggingTest do
  @moduledoc """
  `phoenix_kit_settings` stores every setting's value in the same
  two generic columns — secrets included (`oauth_google_client_secret`,
  `aws_secret_access_key`, ...). Ecto's own SQL debug logger has no notion
  of the schema (no `redact:` field option reaches it) and would otherwise
  print the literal bound value on every insert/update, e.g.
  `UPDATE ... SET value = $1 ... [<secret>, ...]` — found doing exactly
  that on a live install.

  Destructive proof, not a confirming one: write a fake secret through the
  real `PhoenixKit.Settings.update_setting/2` path and confirm it never
  shows up in the log, at `:debug` — the level Ecto logs queries at by
  default, and the level a leak would actually surface at.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings

  @canary "leak-canary-secret-#{System.unique_integer([:positive])}"

  test "inserting a brand-new setting never leaks its value into the SQL debug log" do
    log =
      capture_log([level: :debug], fn ->
        {:ok, _} = Settings.update_setting("oauth_google_client_secret", @canary)
      end)

    refute log =~ @canary
  end

  test "updating an existing setting never leaks the new value into the SQL debug log" do
    {:ok, _} = Settings.update_setting("oauth_google_client_secret", "seed-value")

    log =
      capture_log([level: :debug], fn ->
        {:ok, _} = Settings.update_setting("oauth_google_client_secret", @canary)
      end)

    refute log =~ @canary
  end

  test "the write still actually happens — log: false only silences logging" do
    {:ok, _} = Settings.update_setting("oauth_google_client_secret", @canary)

    assert Settings.get_setting("oauth_google_client_secret") == @canary
  end
end
