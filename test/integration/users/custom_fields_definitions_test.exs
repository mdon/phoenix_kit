defmodule PhoenixKit.Integration.Users.CustomFieldsDefinitionsTest do
  @moduledoc """
  What `ensure_definitions_exist/1` is allowed to auto-register.

  It runs on every `update_user_custom_fields/3` that does not opt out, so it
  is the door through which a value that no field `type` can represent used to
  become an admin-editable text field — and the admin user edit form then 500d
  on a map and flattened a list into one run it wrote back on the next save
  (issue #780).
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields

  defp create_user do
    {:ok, user} =
      Auth.register_user(%{
        email: "cfdef_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp definition_keys, do: Enum.map(CustomFields.list_field_definitions(), & &1["key"])

  describe "ensure_definitions_exist/1" do
    test "a scalar under an unseen key still registers, inferring its type" do
      # The behaviour the skips must not take down with them.
      user = create_user()
      key = "department_#{System.unique_integer([:positive])}"

      {:ok, _} = Auth.update_user_custom_fields(user, %{key => "Engineering"})

      assert %{"type" => "text", "enabled" => true, "user_accessible" => false} =
               CustomFields.get_field_definition(key)
    end

    test "a map value registers nothing" do
      user = create_user()
      key = "line_params_#{System.unique_integer([:positive])}"

      {:ok, updated} =
        Auth.update_user_custom_fields(user, %{
          key => %{"width" => 13, "opacity" => 1, "dash" => "solid"}
        })

      refute key in definition_keys()

      # The VALUE is still stored — only the claim that it is an editable
      # profile field is refused.
      assert updated.custom_fields[key] == %{"width" => 13, "opacity" => 1, "dash" => "solid"}
    end

    test "a list value registers nothing" do
      user = create_user()
      key = "palette_#{System.unique_integer([:positive])}"

      {:ok, updated} = Auth.update_user_custom_fields(user, %{key => ["#fca5a5", "#fdba74"]})

      refute key in definition_keys()
      assert updated.custom_fields[key] == ["#fca5a5", "#fdba74"]
    end

    test "a structured value does not block the scalar keys written beside it" do
      # The skip is per key, not per call: one map in the map must not cost the
      # host app the definition for the field it actually asked for.
      user = create_user()
      scalar_key = "phone_#{System.unique_integer([:positive])}"
      structured_key = "prefs_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.update_user_custom_fields(user, %{
          scalar_key => "555-1234",
          structured_key => %{"a" => 1}
        })

      assert scalar_key in definition_keys()
      refute structured_key in definition_keys()
    end

    test "an admin save on a user holding a structured value does not register it" do
      # The path that made this bug reachable on a FRESH install, not only on an
      # upgraded one. The etcher writes `etcher_line_params` with
      # `ensure_definitions: false`, so no definition is created there — but the
      # admin form saves through `Auth.update_user_fields/2`, whose
      # `maybe_update_custom_fields/2` merges the submitted keys over the user's
      # WHOLE stored map and hands the result to `update_user_custom_fields/3`
      # with default opts. So every key the user already had, including the map
      # the etcher had quietly stored, went through auto-registration again on
      # the next unrelated save — and the page 500d from then on.
      user = create_user()
      structured_key = "etcher_line_params_#{System.unique_integer([:positive])}"
      scalar_key = "phone_#{System.unique_integer([:positive])}"

      {:ok, user} =
        Auth.update_user_custom_fields(user, %{structured_key => %{"width" => 2}},
          ensure_definitions: false
        )

      {:ok, saved} = Auth.update_user_fields(user, %{scalar_key => "555-1234"})

      keys = definition_keys()

      refute structured_key in keys
      # The submitted field still registers, so this is not passing by doing
      # nothing at all.
      assert scalar_key in keys
      assert saved.custom_fields[structured_key] == %{"width" => 2}
    end

    test "PhoenixKit's own internal keys register nothing, even scalar ones" do
      # Every internal writer passes `ensure_definitions: false`; this is what
      # holds when one forgets, here or in a host app.
      user = create_user()

      {:ok, _} =
        Auth.update_user_custom_fields(user, %{
          "preferred_locale" => "en-GB",
          "users_view_mode" => "cards",
          "media_sidebar_collapsed" => true
        })

      keys = definition_keys()

      refute "preferred_locale" in keys
      refute "users_view_mode" in keys
      refute "media_sidebar_collapsed" in keys
    end
  end
end
