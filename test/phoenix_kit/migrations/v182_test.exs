defmodule PhoenixKit.Migrations.Postgres.V182Test do
  @moduledoc """
  V182's data cleanup, run against a seeded definitions row.

  `V182.up/1` can't be invoked outside an `Ecto.Migrator` runner (same
  constraint as V174Test and friends), and by the time any test runs the chain
  has already been applied — to an install that has no custom field definitions
  at all, which proves nothing. So the migration exposes its statements via
  `cleanup_statements/1` (up/1 executes exactly that list), and this suite runs
  the REAL SQL against a settings row shaped like the one found in the wild:
  seven internal keys auto-registered as `text` fields by a version that
  predates `ensure_definitions: false` (issue #780).
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Migrations.Postgres.V182
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.CustomFields

  @setting_key "custom_user_fields_definitions"

  defp run_cleanup do
    Enum.map(V182.cleanup_statements("public."), &Repo.query!(&1))
  end

  defp definition(key, position) do
    %{
      "key" => key,
      "label" => key,
      "type" => "text",
      "required" => false,
      "position" => position,
      "enabled" => true,
      "user_accessible" => false,
      "validation" => %{},
      "default" => "",
      "options" => []
    }
  end

  defp seed_definitions!(keys) do
    definitions = keys |> Enum.with_index(1) |> Enum.map(fn {k, i} -> definition(k, i) end)
    {:ok, _} = CustomFields.save_field_definitions(definitions)
    :ok
  end

  # Read past the settings cache and past `list_field_definitions/0`'s own
  # shape handling — the point is what is left in the column.
  defp stored_value_json do
    %{rows: [[value_json]]} =
      Repo.query!("SELECT value_json FROM public.phoenix_kit_settings WHERE key = $1", [
        @setting_key
      ])

    value_json
  end

  defp stored_keys do
    case stored_value_json() do
      %{"fields" => fields} -> Enum.map(fields, & &1["key"])
      fields when is_list(fields) -> Enum.map(fields, & &1["key"])
    end
  end

  defp stored_date_updated do
    %{rows: [[date_updated]]} =
      Repo.query!("SELECT date_updated FROM public.phoenix_kit_settings WHERE key = $1", [
        @setting_key
      ])

    date_updated
  end

  describe "the wrapped %{\"fields\" => [...]} shape" do
    test "drops every internal key and keeps every admin-defined one" do
      seed_definitions!([
        "phone",
        "media_view_mode",
        "etcher_colors",
        "etcher_line_params",
        "media_expanded_folders",
        "media_sidebar_collapsed",
        "media_viewer_info_collapsed",
        "users_view_mode",
        "department"
      ])

      run_cleanup()

      assert stored_keys() == ["phone", "department"]
    end

    test "keeps the surviving definitions in their stored order" do
      seed_definitions!(["a_field", "preferred_locale", "b_field", "users_view_mode", "c_field"])

      run_cleanup()

      assert stored_keys() == ["a_field", "b_field", "c_field"]
    end

    test "a row made entirely of internal keys becomes an empty list, not null" do
      seed_definitions!(["notification_preferences", "timezone_alert_zone"])

      run_cleanup()

      assert stored_value_json() == %{"fields" => []}
    end

    test "every notification channel config key goes, whatever the channel" do
      seed_definitions!(["notification_channel:telegram", "notification_channel:email", "phone"])

      run_cleanup()

      assert stored_keys() == ["phone"]
    end

    test "a row with nothing to clean is not touched at all" do
      seed_definitions!(["phone", "department"])
      before = stored_date_updated()

      run_cleanup()

      assert stored_keys() == ["phone", "department"]
      # The `EXISTS` guard, pinned: an unaffected install's row must not even
      # get a new timestamp out of this migration.
      assert stored_date_updated() == before
    end

    test "an element with no usable key is kept, not swept away with the internal ones" do
      # `->> 'key'` answers NULL for an element that is not an object, or an
      # object with no `key`, and `NOT (NULL)` is NULL — which a WHERE clause
      # drops. Without the explicit NULL arm the row would be deleted silently,
      # and `down/1` cannot put it back: the setting held the only copy.
      {:ok, _} =
        CustomFields.save_field_definitions([
          definition("phone", 1),
          "junk",
          %{"label" => "no key at all", "type" => "text"},
          %{"key" => nil, "label" => "null key"},
          definition("etcher_line_params", 2)
        ])

      run_cleanup()

      %{"fields" => fields} = stored_value_json()

      assert "junk" in fields
      assert %{"label" => "no key at all", "type" => "text"} in fields
      assert %{"key" => nil, "label" => "null key"} in fields
      assert Enum.any?(fields, &(is_map(&1) and &1["key"] == "phone"))
      # The internal key it was mixed with is still gone.
      refute Enum.any?(fields, &(is_map(&1) and &1["key"] == "etcher_line_params"))
    end

    test "the channel prefix's own underscores are not LIKE wildcards" do
      # `_` matches any single character in LIKE, so the unescaped pattern
      # `notification_channel:%` also matched keys nobody meant.
      # Unescaped, `notification_channel:%` matches this key: each `_` stands in
      # for the `x`. Seeded through `save_field_definitions/1` because
      # `validate_field_key/1` would refuse the colon, which is also why no such
      # definition can exist in the first place — the escape is hygiene, and
      # this is what proves it is actually applied.
      seed_definitions!(["notificationxchannel:x", "phone", "etcher_colors"])

      run_cleanup()

      assert "notificationxchannel:x" in stored_keys()
      refute "etcher_colors" in stored_keys()
    end

    test "is idempotent" do
      seed_definitions!(["phone", "etcher_line_params"])

      run_cleanup()
      first = stored_value_json()
      run_cleanup()

      assert stored_value_json() == first
    end
  end

  describe "the legacy bare-list shape" do
    setup do
      seed_definitions!(["phone", "etcher_line_params", "media_view_mode"])

      # Unwrap it back to what the setting held before the list was wrapped in
      # %{"fields" => …}: the migration has to reach both shapes.
      Repo.query!(
        "UPDATE public.phoenix_kit_settings SET value_json = value_json -> 'fields' WHERE key = $1",
        [@setting_key]
      )

      assert is_list(stored_value_json())
      :ok
    end

    test "drops the internal keys and leaves a bare list behind" do
      run_cleanup()

      assert stored_keys() == ["phone"]
      assert is_list(stored_value_json())
    end
  end

  test "a settings row that is not the definitions row is never rewritten" do
    # Both statements are keyed on `custom_user_fields_definitions`; this is
    # what says so. `time_zone` is seeded by the baseline migration.
    %{rows: [[before]]} =
      Repo.query!("SELECT value FROM public.phoenix_kit_settings WHERE key = 'time_zone'")

    seed_definitions!(["etcher_line_params"])
    run_cleanup()

    %{rows: [[after_cleanup]]} =
      Repo.query!("SELECT value FROM public.phoenix_kit_settings WHERE key = 'time_zone'")

    assert after_cleanup == before
  end
end
