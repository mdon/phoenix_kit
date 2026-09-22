defmodule PhoenixKitWeb.Components.ColumnSettingsPrefsTest do
  @moduledoc """
  A host LiveView on core's column modal and `TableColumns`: every edit in
  the modal is saved for the signed-in user at once, Reset hands the table
  back to its default, and a page with two tables routes each edit to its
  own section.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKitWeb.TableColumns

  defmodule Host do
    @moduledoc false
    use Phoenix.LiveView

    import PhoenixKitWeb.Components.Core.ColumnSettings

    def specs do
      %{
        "people" => %{
          key: "test.people",
          columns: [
            %{id: "email", label: "Email", group: "Standard fields"},
            %{id: "role", label: "Role", group: "Standard fields"},
            %{id: "custom_team", label: "Team", group: "Custom fields"}
          ],
          defaults: ~w(email)
        },
        "teams" => %{
          key: "test.teams",
          columns: [%{id: "size", label: "Size"}, %{id: "lead", label: "Lead"}],
          min: 1
        }
      }
    end

    def mount(_params, session, socket) do
      user = %{uuid: session["user_uuid"]}

      {:ok,
       Phoenix.Component.assign(socket,
         phoenix_kit_current_user: user,
         people: TableColumns.load(user, specs()["people"]),
         teams: TableColumns.load(user, specs()["teams"])
       )}
    end

    def render(assigns) do
      ~H"""
      <div id="shown-people">{Enum.join(@people, ",")}</div>
      <div id="shown-teams">{Enum.join(@teams, ",")}</div>
      <.column_settings_modal
        show={true}
        sections={[
          %{id: "people", title: "People", columns: specs()["people"].columns, selected: @people},
          %{id: "teams", title: "Teams", columns: specs()["teams"].columns, selected: @teams}
        ]}
      />
      """
    end

    def handle_event("reset_columns", params, socket) do
      socket =
        Enum.reduce(specs(), socket, fn {name, spec}, acc ->
          TableColumns.handle_event(
            "reset_columns",
            params,
            acc,
            spec,
            String.to_existing_atom(name)
          )
        end)

      {:noreply, socket}
    end

    def handle_event(event, %{"section" => section} = params, socket) do
      spec = Map.fetch!(specs(), section)

      {:noreply,
       TableColumns.handle_event(event, params, socket, spec, String.to_existing_atom(section))}
    end

    def handle_event(_event, _params, socket), do: {:noreply, socket}
  end

  setup do
    {user, _token} = create_admin_user()
    %{user: user}
  end

  defp open(conn, user),
    do: live_isolated(conn, Host, session: %{"user_uuid" => user.uuid})

  defp shown(view, table), do: view |> element("#shown-#{table}") |> render() |> text()

  defp text(html), do: html |> Floki.parse_fragment!() |> Floki.text() |> String.trim()

  test "edits are saved for the user at once, and a new page shows them", %{
    conn: conn,
    user: user
  } do
    {:ok, view, html} = open(conn, user)
    assert shown(view, "people") == "email"
    assert html =~ "Standard fields"
    assert html =~ "Custom fields"

    view |> element(~s(button[phx-value-column_id="custom_team"])) |> render_click()
    view |> element(~s(button[phx-value-column_id="role"])) |> render_click()
    assert shown(view, "people") == "email,custom_team,role"

    render_hook(view, "reorder_columns", %{
      "ordered_ids" => ~w(role email custom_team),
      "section" => "people"
    })

    view
    |> element(~s(#pk-column-settings-modal-people-selected button[phx-value-column_id="email"]))
    |> render_click()

    assert shown(view, "people") == "role,custom_team"
    assert ViewPrefs.get(user, "test.people") == %{"columns" => ~w(role custom_team)}

    {:ok, again, _html} = open(conn, user)
    assert shown(again, "people") == "role,custom_team"
  end

  test "each section's edits stay in its own table, within its minimum", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = open(conn, user)
    assert shown(view, "teams") == "size,lead"

    view
    |> element(~s(#pk-column-settings-modal-teams-selected button[phx-value-column_id="size"]))
    |> render_click()

    view
    |> element(~s(#pk-column-settings-modal-teams-selected button[phx-value-column_id="lead"]))
    |> render_click()

    # The last column stays: this table's minimum is one.
    assert shown(view, "teams") == "lead"
    assert shown(view, "people") == "email"
    assert ViewPrefs.get(user, "test.people") == %{}
  end

  test "a forged column id changes nothing", %{conn: conn, user: user} do
    {:ok, view, _html} = open(conn, user)
    render_click(view, "add_column", %{"column_id" => "password_hash", "section" => "people"})

    assert shown(view, "people") == "email"
    assert ViewPrefs.get(user, "test.people") == %{}
  end

  test "Reset hands every table back to its default and forgets the choice", %{
    conn: conn,
    user: user
  } do
    {:ok, _} = ViewPrefs.put(user, "test.people", %{"columns" => ~w(role), "sort" => "x"})
    {:ok, view, _html} = open(conn, user)
    assert shown(view, "people") == "role"

    view |> element(~s(button[phx-click="reset_columns"])) |> render_click()

    assert shown(view, "people") == "email"
    assert ViewPrefs.get(user, "test.people") == %{"sort" => "x"}
  end
end
