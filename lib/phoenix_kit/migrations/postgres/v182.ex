defmodule PhoenixKit.Migrations.Postgres.V182 do
  @moduledoc """
  V182: removes PhoenixKit's own internal keys from the custom user field
  definitions.

  ## What was wrong

  `custom_fields` is one free-form JSONB column shared by two very different
  kinds of value: admin-defined profile fields, and per-user state written by
  features — the media browser's view mode, the etcher's colour palette and
  stroke defaults, notification preferences, the language a user picked.

  Until every internal writer started passing `ensure_definitions: false`, the
  first write of any of those keys auto-registered a *field definition* for it,
  inferring the type from the value. `infer_field_type/1` answers `"text"` for
  anything it does not recognise, so a map (`etcher_line_params`) and a list
  (`etcher_colors`, `media_expanded_folders`) each became an admin-editable
  text field. Nothing downstream can render either one: the admin user edit
  form hands the stored value to an `<input>`, where `Phoenix.HTML.Safe` raises
  on a map — a 500 on `/admin/users/edit/:id` for every affected user — and
  silently flattens a list into one concatenated run that the next save writes
  back over the stored value.

  ## Why the code fix is not enough

  The writers were fixed, so nothing registers these keys any more. The
  definitions they already wrote are another matter: they sit in the
  `custom_user_fields_definitions` settings row, and no code path has ever
  removed one. An install upgraded from a version that registered them carries
  the broken page forward even though the code that created the rows is gone.
  This migration is what clears them.

  It removes only definitions whose key is one PhoenixKit itself writes (the
  list below, plus the `notification_channel:` family). Values in
  `phoenix_kit_users.custom_fields` are deliberately left untouched — the
  features that own them keep reading them; only the claim that they are
  admin-editable profile fields goes away.

  A host-app or module key holding a map is not enumerable here, so it is
  handled in code instead: `CustomFields.ensure_definitions_exist/1` no longer
  registers a structured value, and the edit form renders one read-only rather
  than into an input.

  ## What it does not reach

  Only `value_json` is rewritten. `save_field_definitions/1` has always written
  the definitions there; the string `value` column is a read-side backward
  compatibility path only, and parsing an arbitrary `varchar` as JSON in SQL
  would abort the whole migration on one malformed row — a much worse trade
  than leaving a shape the code fixes already keep from crashing.

  ## The settings cache

  `Settings` caches this row in ETS, and a migration writes underneath that
  cache. Nothing here can invalidate it: the chain runs in its own OS process
  (`mix phoenix_kit.update`, a release migration step), not in the node serving
  requests. An install that migrates and then restarts — the ordinary
  deployment — never sees a stale list; one that migrates a live node keeps
  serving the old definitions until the entry is evicted or the node restarts.
  Nothing breaks in the meantime, because the page-level fixes that ship with
  this version render a structured value read-only either way.

  ## down/1

  Deleted definitions cannot be reconstructed: the setting held the only copy.
  Rolling back therefore only moves the version marker. That loses nothing an
  operator wants back — a re-registered definition is exactly the broken state
  this version exists to clear, and the values themselves were never touched.
  """

  use Ecto.Migration

  # Mirrors `PhoenixKit.Users.CustomFields.internal_key?/1` as of this version.
  # Deliberately a copy: a migration is a historical record and must keep doing
  # what it did when it shipped, even after that list grows. A key added later
  # can never have been registered anyway — the writers all pass
  # `ensure_definitions: false` and `ensure_definitions_exist/1` skips internal
  # keys outright.
  @internal_keys ~w(
    activity_view_mode
    etcher_colors
    etcher_line_params
    media_expanded_folders
    media_sidebar_collapsed
    media_view_mode
    media_viewer_info_collapsed
    notification_preferences
    preferred_locale
    referral_satisfied_at
    referral_satisfied_via
    timezone_alert_zone
    users_view_mode
  )

  @internal_key_prefix "notification_channel:"

  @setting_key "custom_user_fields_definitions"

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    Enum.each(cleanup_statements(p), &execute/1)

    # Single-step runs rely on the migration stamping its own marker — the
    # runner only writes it for multi-step ranges.
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '182'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    # Nothing to reverse (see moduledoc). Rollback lands on the version that
    # precedes this one.
    execute("COMMENT ON TABLE #{p}phoenix_kit IS '181'")
  end

  # Public (and idempotent) so the suite can run the REAL statements against a
  # seeded settings row: by the time any test runs, the chain has already been
  # applied to an install that has no definitions at all, which would prove
  # nothing. `p` is the rendered prefix including the trailing dot.
  @doc false
  def cleanup_statements(p) do
    [
      # Current shape: %{"fields" => [definition, ...]}.
      """
      UPDATE #{p}phoenix_kit_settings AS s
         SET value_json = jsonb_set(
               s.value_json,
               '{fields}',
               COALESCE(
                 (
                   SELECT jsonb_agg(t.elem ORDER BY t.ord)
                     FROM jsonb_array_elements(s.value_json -> 'fields')
                          WITH ORDINALITY AS t(elem, ord)
                    WHERE NOT (#{internal_key_match("t.elem")})
                 ),
                 '[]'::jsonb
               )
             ),
             date_updated = now()
       WHERE s.key = '#{@setting_key}'
         AND jsonb_typeof(s.value_json -> 'fields') = 'array'
         AND EXISTS (
               SELECT 1
                 FROM jsonb_array_elements(s.value_json -> 'fields') AS t(elem)
                WHERE #{internal_key_match("t.elem")}
             )
      """,
      # Legacy shape: the bare list, before it was wrapped in %{"fields" => …}.
      """
      UPDATE #{p}phoenix_kit_settings AS s
         SET value_json = COALESCE(
               (
                 SELECT jsonb_agg(t.elem ORDER BY t.ord)
                   FROM jsonb_array_elements(s.value_json)
                        WITH ORDINALITY AS t(elem, ord)
                  WHERE NOT (#{internal_key_match("t.elem")})
               ),
               '[]'::jsonb
             ),
             date_updated = now()
       WHERE s.key = '#{@setting_key}'
         AND jsonb_typeof(s.value_json) = 'array'
         AND EXISTS (
               SELECT 1
                 FROM jsonb_array_elements(s.value_json) AS t(elem)
                WHERE #{internal_key_match("t.elem")}
             )
      """
    ]
  end

  # Every key is a literal from the module attribute above, so the rendered
  # array carries nothing an operator or a user could influence.
  defp internal_key_match(column) do
    keys = Enum.map_join(@internal_keys, ", ", &"'#{&1}'")

    "#{column} ->> 'key' = ANY (ARRAY[#{keys}]) OR " <>
      "#{column} ->> 'key' LIKE '#{@internal_key_prefix}%'"
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
