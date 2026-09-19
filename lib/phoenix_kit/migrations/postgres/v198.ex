defmodule PhoenixKit.Migrations.Postgres.V198 do
  @moduledoc """
  V198: withholds the secret-named setting values the settings history has
  already recorded.

  The settings history writes a permanent `setting.changed` activity entry
  for every settings write, with the value before and after — except for
  secrets, whose values it withholds. After V194 it recognised a secret by
  the restricted-key list and by an integration row's module. That list only
  names the keys core knows: a module's own `…_api_key`, `…_webhook_secret`
  or `…_token` written through the ordinary writers was withheld from the
  change broadcast (`PhoenixKit.Settings.Events.secret_key?/2`, which also
  reads the key's NAME) and then stored in the history in plain text — in an
  entry that is never pruned and that the admin Activity page shows to anyone
  who can open it.

  The writer now applies the same name test. This migration withholds what it
  already wrote, exactly as a restricted setting is recorded: `from` and `to`
  become null and `restricted` true. The rest of each entry — who, when,
  which key — stays, so the history still says that the setting changed.

  An entry is withheld when its key, lower-cased, contains one of the
  fragments the writer tests for: `secret`, `password`, `passwd`, `token`,
  `private_key`, `api_key`, `apikey`, `credential`, `webhook`. The list is
  frozen here as it stood when this version shipped; a fragment added to the
  writer later needs a version of its own to reach entries already written.

  Re-runnable: an entry already restricted is left alone.

  ## down/1

  Moves the version marker back and nothing else. The withheld values are
  gone on purpose; restoring them is the defect this version removes.
  """

  use Ecto.Migration

  @fragments ~w(secret password passwd token private_key api_key apikey credential webhook)

  def up(opts) do
    opts |> Map.get(:prefix, "public") |> prefix_str() |> up_statements() |> Enum.each(&execute/1)
  end

  def down(opts) do
    opts
    |> Map.get(:prefix, "public")
    |> prefix_str()
    |> down_statements()
    |> Enum.each(&execute/1)
  end

  @doc false
  # The exact statements `up/1` runs, exposed so the migration test can run the
  # real SQL against seeded entries (a migration's `up/1` cannot run outside an
  # Ecto.Migrator runner). `p` is the schema prefix with its trailing dot.
  def up_statements(p) do
    [
      """
      UPDATE #{p}phoenix_kit_activities AS a
      SET metadata = a.metadata || '{"from": null, "to": null, "restricted": true}'::jsonb
      WHERE a.action = 'setting.changed'
        AND (a.metadata ->> 'restricted') IS DISTINCT FROM 'true'
        AND lower(a.metadata ->> 'key') ~ '#{Enum.join(@fragments, "|")}'
      """,
      "COMMENT ON TABLE #{p}phoenix_kit IS '198'"
    ]
  end

  @doc false
  def down_statements(p) do
    ["COMMENT ON TABLE #{p}phoenix_kit IS '197'"]
  end

  @doc false
  def fragments, do: @fragments

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
