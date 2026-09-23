defmodule PhoenixKitWeb.Integration.Users.UsersTableColumnsTest do
  @moduledoc """
  The Users table's columns are each admin's own: the live modal saves a
  change at once, another admin keeps the site's default, and Reset hands
  the table back to it.
  """
  use PhoenixKitWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.{CustomFields, TableColumns, ViewPrefs}
  alias PhoenixKit.Utils.Routes

  defp headers(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("table thead th")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
    |> Enum.reject(&(&1 == ""))
  end

  defp open(conn, user), do: live(log_in_user(conn, user), Routes.path("/admin/users"))

  test "an admin's column choice is theirs alone, and Reset follows the site's default", %{
    conn: conn
  } do
    {admin, _} = create_admin_user()
    {other, _} = create_admin_user()

    {:ok, view, _html} = open(conn, admin)
    refute "Username" in headers(view)

    view |> element(~s(button[phx-click="show_column_modal"])) |> render_click()

    view
    |> element(~s(button[phx-click="add_column"][phx-value-column_id="username"]))
    |> render_click()

    assert "Username" in headers(view)
    assert "username" in ViewPrefs.get(admin, "users")["columns"]

    {:ok, other_view, _html} = open(build_conn(), other)
    refute "Username" in headers(other_view)

    # The site's default is what an admin who has not chosen sees.
    {:ok, _} = TableColumns.update_user_table_columns(["email", "username"])
    {:ok, other_view, _html} = open(build_conn(), other)
    assert "Username" in headers(other_view)
    refute "Status" in headers(other_view)

    # The admin with a choice keeps it; Reset puts them on the site's default.
    {:ok, view, _html} = open(conn, admin)
    assert "Status" in headers(view)
    render_click(view, "reset_columns", %{})
    refute "Status" in headers(view)
    assert ViewPrefs.get(admin, "users") == %{}
  end

  test "the modal groups standard and custom fields, and a forged column is ignored", %{
    conn: conn
  } do
    {admin, _} = create_admin_user()
    {:ok, view, _html} = open(conn, admin)

    html = view |> element(~s(button[phx-click="show_column_modal"])) |> render_click()
    assert html =~ "Standard fields"

    render_click(view, "add_column", %{"column_id" => "hashed_password"})
    assert ViewPrefs.get(admin, "users") == %{}
  end

  test "a custom field added while the page is open is offered at once", %{conn: conn} do
    {admin, _} = create_admin_user()
    {:ok, view, _html} = open(conn, admin)
    key = "sweep_#{System.unique_integer([:positive])}"

    {:ok, _} =
      CustomFields.add_field_definition(%{"key" => key, "label" => "Shoe size", "type" => "text"})

    CustomFields.Events.broadcast_fields_changed()

    html = view |> element(~s(button[phx-click="show_column_modal"])) |> render_click()
    assert html =~ "Shoe size"
  end
end
