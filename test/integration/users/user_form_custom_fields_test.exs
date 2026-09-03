defmodule PhoenixKit.Integration.Users.UserFormCustomFieldsTest do
  @moduledoc """
  The two pages that render custom field definitions into editable inputs — the
  admin user edit form and the user's own `/profile/settings` — against the
  `custom_fields` values neither of them can edit.

  `custom_fields` is free-form JSONB and every field `type` describes a scalar,
  so a definition can end up pointing at a map or a list — which is exactly
  what happened on installs upgraded from a version that auto-registered the
  media browser's and the etcher's internal keys. The form used to hand the
  stored value straight to `<.input>`: `Phoenix.HTML.Safe` raises on a map (a
  500 on this page for every affected user) and flattens a list into one
  concatenated run that the next save posted back over the stored list
  (issue #780).
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.CustomFields
  alias PhoenixKit.Users.TableColumns
  alias PhoenixKit.Utils.Routes

  @line_params %{"width" => 13, "opacity" => 1, "dash" => "solid"}
  @palette ["#fca5a5", "#fdba74"]

  defp unique_email, do: "cf_form_#{System.unique_integer([:positive])}@example.com"

  defp plain_user do
    {:ok, user} = AuthCtx.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = AuthCtx.admin_confirm_user(user)
    Repo.get!(AuthCtx.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(AuthCtx.User, user.uuid)
  end

  # A stale definition of exactly the shape the old auto-registration wrote:
  # type "text", because `infer_field_type/1` answers "text" for anything it
  # does not recognise — including a map and a list.
  defp text_definition!(key) do
    {:ok, _} =
      CustomFields.add_field_definition(%{
        "key" => key,
        "label" => "Etcher Line Params",
        "type" => "text",
        "enabled" => true,
        "user_accessible" => false,
        "position" => 99
      })

    key
  end

  defp user_with_field(key, value) do
    user = plain_user()

    {:ok, updated} =
      Auth.update_user_custom_fields(user, %{key => value}, ensure_definitions: false)

    updated
  end

  defp edit_path(user), do: Routes.path("/admin/users/edit/#{user.uuid}")

  describe "a map under a field definition" do
    test "renders the page instead of raising Protocol.UndefinedError", %{conn: conn} do
      key = text_definition!("etcher_line_params_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @line_params)
      conn = log_in_user(conn, admin_user())

      # The mount itself is the assertion: before the guard, this raised
      # `Phoenix.HTML.Safe not implemented for Map` out of attribute escaping.
      {:ok, _view, html} = live(conn, edit_path(target))

      assert html =~ "Etcher Line Params"
      # Shown as JSON, the same rendering the read-only user page uses.
      assert html =~ "&quot;dash&quot;:&quot;solid&quot;"
    end

    test "carries no input name, so nothing can post the rendering back", %{conn: conn} do
      key = text_definition!("etcher_line_params_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @line_params)
      conn = log_in_user(conn, admin_user())

      {:ok, _view, html} = live(conn, edit_path(target))

      refute html =~ "user[custom_fields][#{key}]"
    end
  end

  describe "a list under a field definition" do
    test "renders joined rather than flattened into one run", %{conn: conn} do
      key = text_definition!("etcher_colors_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @palette)
      conn = log_in_user(conn, admin_user())

      {:ok, _view, html} = live(conn, edit_path(target))

      # `Phoenix.HTML.Safe` IS implemented for List, so this one never crashed —
      # it rendered as "#fca5a5#fdba74" in an editable input.
      assert html =~ "#fca5a5, #fdba74"
      refute html =~ "#fca5a5#fdba74"
      refute html =~ "user[custom_fields][#{key}]"
    end

    test "survives a save of an unrelated field", %{conn: conn} do
      # The quiet half of the bug: the flattened string sat in an input named
      # after the key, so ANY save on this page replaced the stored list with
      # it. Nothing is submitted for the key now, and the save path merges.
      key = text_definition!("etcher_colors_#{System.unique_integer([:positive])}")
      other_key = text_definition!("phone_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @palette)
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, edit_path(target))

      # Submitted through the RENDERED form, not as hand-written params: the
      # bug was that the page itself put the flattened list on the wire under
      # this key, so a payload typed here would prove nothing.
      try do
        view
        |> form("#user_form", %{
          "user" => %{
            "first_name" => "Renamed",
            "custom_fields" => %{other_key => "555-1234"}
          }
        })
        |> render_submit()
      catch
        :exit, {{:shutdown, {:redirect, _, _}}, _} -> :ok
      end

      saved = Repo.get!(AuthCtx.User, target.uuid)

      assert saved.custom_fields[key] == @palette
      # The submission itself must still land, or the assertion above is
      # satisfied just as well by a save that did nothing at all.
      assert saved.custom_fields[other_key] == "555-1234"
      assert saved.first_name == "Renamed"
    end
  end

  describe "a REQUIRED definition holding a structured value" do
    # The form deliberately submits nothing for a structured value. Validation
    # runs over the params, so an enabled definition that is never submitted
    # reads as missing — and a `required` one would block every save on the
    # page, including saves that have nothing to do with it. Worse, several
    # `validate_type/2` clauses call `to_string/1` on the value, which is the
    # very crash this PR exists to stop, moved into the save path.
    defp required_definition!(key, type) do
      {:ok, _} =
        CustomFields.add_field_definition(%{
          "key" => key,
          "label" => "Required #{type}",
          "type" => type,
          "required" => true,
          "enabled" => true,
          "user_accessible" => false,
          "position" => 97
        })

      key
    end

    test "does not block a save of an unrelated field", %{conn: conn} do
      key = required_definition!("etcher_colors_#{System.unique_integer([:positive])}", "text")
      other_key = text_definition!("phone_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @palette)
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, edit_path(target))

      try do
        view
        |> form("#user_form", %{
          "user" => %{"first_name" => "Renamed", "custom_fields" => %{other_key => "555-1234"}}
        })
        |> render_submit()
      catch
        :exit, {{:shutdown, {:redirect, _, _}}, _} -> :ok
      end

      saved = Repo.get!(AuthCtx.User, target.uuid)

      assert saved.first_name == "Renamed"
      assert saved.custom_fields[key] == @palette
    end

    test "a numeric definition does not raise on the stored map", %{conn: conn} do
      # `validate_type(%{"type" => "number"}, value)` does `to_string(value)`.
      key = required_definition!("line_params_#{System.unique_integer([:positive])}", "number")
      other_key = text_definition!("phone_#{System.unique_integer([:positive])}")
      target = user_with_field(key, @line_params)
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, edit_path(target))

      try do
        view
        |> form("#user_form", %{
          "user" => %{"first_name" => "Renamed", "custom_fields" => %{other_key => "555-1234"}}
        })
        |> render_submit()
      catch
        :exit, {{:shutdown, {:redirect, _, _}}, _} -> :ok
      end

      saved = Repo.get!(AuthCtx.User, target.uuid)

      assert saved.first_name == "Renamed"
      assert saved.custom_fields[key] == @line_params
    end
  end

  test "the users list renders a custom-field column holding one", %{conn: conn} do
    # The fourth page that makes a `custom_fields` value visible. Its cells end
    # in `truncate_text/2`, whose fallback is `to_string/1` — so a map 500d the
    # whole list and a list came out as one concatenated run. Custom-field
    # columns are not in the default set, so this needs the column switched on.
    map_key = text_definition!("etcher_line_params_#{System.unique_integer([:positive])}")
    list_key = text_definition!("etcher_colors_#{System.unique_integer([:positive])}")

    target = user_with_field(map_key, @line_params)

    {:ok, _} =
      Auth.update_user_custom_fields(target, Map.put(target.custom_fields, list_key, @palette),
        ensure_definitions: false
      )

    {:ok, _} =
      TableColumns.update_user_table_columns([
        "email",
        "custom_#{map_key}",
        "custom_#{list_key}"
      ])

    conn = log_in_user(conn, admin_user())

    {:ok, _view, html} = live(conn, Routes.path("/admin/users"))

    assert html =~ "&quot;dash&quot;:&quot;solid&quot;"
    assert html =~ "#fca5a5, #fdba74"
    refute html =~ "#fca5a5#fdba74"
  end

  test "the user's own settings page renders one read-only too", %{conn: conn} do
    # `/profile/settings` renders the user-accessible definitions through the
    # same "value straight into an input" shape. A definition auto-registered
    # before `user_accessible` existed defaults to accessible, so the crash was
    # reachable by the account holder, not only by an admin.
    key = "etcher_line_params_#{System.unique_integer([:positive])}"

    {:ok, _} =
      CustomFields.add_field_definition(%{
        "key" => key,
        "label" => "Etcher Line Params",
        "type" => "text",
        "enabled" => true,
        "user_accessible" => true,
        "position" => 99
      })

    user = plain_user()

    {:ok, user} =
      Auth.update_user_custom_fields(user, %{key => @line_params}, ensure_definitions: false)

    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, Routes.path("/profile/settings"))

    assert html =~ "&quot;dash&quot;:&quot;solid&quot;"
    refute html =~ "profile_form[user][custom_fields][#{key}]"
  end

  test "a structured value stays on the page while another field is edited", %{conn: conn} do
    # `handle_event("validate")` used to replace the whole assign with the
    # submitted params, and a field with no input submits nothing — so the
    # read-only value vanished on the first keystroke.
    key = text_definition!("etcher_line_params_#{System.unique_integer([:positive])}")
    other_key = text_definition!("phone_#{System.unique_integer([:positive])}")
    target = user_with_field(key, @line_params)
    conn = log_in_user(conn, admin_user())

    {:ok, view, _html} = live(conn, edit_path(target))

    html =
      render_change(view, "validate_user", %{
        "user" => %{"first_name" => "Typing", "custom_fields" => %{other_key => "5"}}
      })

    assert html =~ "&quot;dash&quot;:&quot;solid&quot;"
  end
end
