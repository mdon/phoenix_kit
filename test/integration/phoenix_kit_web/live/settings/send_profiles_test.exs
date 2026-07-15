defmodule PhoenixKitWeb.Live.Settings.SendProfilesTest do
  @moduledoc """
  Smoke tests for the Send Profiles admin LiveViews
  (`/admin/settings/email-sending/profiles`) — list, create, edit, and
  the per-provider advanced fields.

  Auth + sandbox plumbing comes from `PhoenixKitWeb.ConnCase`.
  """

  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Email.SendProfiles
  alias PhoenixKit.Integrations
  alias PhoenixKit.Utils.Routes

  @list_path Routes.path("/admin/settings/email-sending/profiles")
  @new_path Routes.path("/admin/settings/email-sending/profiles/new")

  defp setup_admin(%{conn: conn}) do
    {user, _token} = create_admin_user()
    conn = log_in_user(conn, user)
    %{conn: conn, user: user}
  end

  defp seed_smtp(name \\ "default") do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("smtp", name)

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "host" => "smtp.example.com",
        "port" => "587",
        "username" => "user",
        "password" => "pw"
      })

    uuid
  end

  defp seed_aws_ses(name) do
    {:ok, %{uuid: uuid}} = Integrations.add_connection("aws_ses", name)

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "access_key" => "AKIA_T",
        "secret_key" => "S",
        "aws_region" => "eu-central-1"
      })

    uuid
  end

  # ---------------------------------------------------------------------------
  # List page
  # ---------------------------------------------------------------------------

  describe "list page" do
    setup :setup_admin

    test "renders the empty state when no send profiles exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "No send profiles yet"
    end

    test "lists an existing send profile", %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp"
        })

      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "Marketing"
      assert html =~ "/admin/settings/email-sending/profiles/#{profile.uuid}/edit"
    end

    test "marks the default profile with a badge", %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp"
        })

      {:ok, _} = SendProfiles.set_default_send_profile(profile)

      {:ok, _view, html} = live(conn, @list_path)
      assert html =~ "Default"
    end

    test "make_default sets the clicked profile as the service-wide default",
         %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp"
        })

      {:ok, view, _html} = live(conn, @list_path)

      # Both the desktop table and the mobile card render a "make_default"
      # button with the same phx-value-uuid — scope to the desktop table.
      view
      |> element(
        ~s(div.hidden.md\\:block button[phx-click="make_default"][phx-value-uuid="#{profile.uuid}"])
      )
      |> render_click()

      assert SendProfiles.get_default_send_profile().uuid == profile.uuid
    end

    test "confirming delete removes the send profile", %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp"
        })

      {:ok, view, _html} = live(conn, @list_path)

      # Both the desktop table and the mobile card render a "show_confirm"
      # delete button with the same phx-value-uuid — scope to the desktop table.
      view
      |> element(
        ~s(div.hidden.md\\:block button[phx-click="show_confirm"][phx-value-uuid="#{profile.uuid}"])
      )
      |> render_click()

      html =
        view
        |> element("button[phx-click=\"confirm_action\"]")
        |> render_click()

      refute html =~ "Marketing"
      assert SendProfiles.get_send_profile(profile.uuid) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # /new — create flow
  # ---------------------------------------------------------------------------

  describe "/new flow" do
    setup :setup_admin

    test "renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, @new_path)
      assert html =~ "New send profile"
    end

    test "offers connected integrations grouped by provider", %{conn: conn} do
      seed_smtp("relay-a")

      {:ok, _view, html} = live(conn, @new_path)
      assert html =~ "relay-a"
    end

    test "submitting with a valid integration creates the profile and redirects",
         %{conn: conn} do
      uuid = seed_smtp("relay-a")

      {:ok, view, _html} = live(conn, @new_path)

      {:error, {:live_redirect, %{to: target}}} =
        view
        |> element("form")
        |> render_submit(%{
          "send_profile" => %{
            "name" => "Transactional",
            "integration_uuid" => uuid,
            "from_email" => "noreply@acme.com"
          }
        })

      assert target == @list_path

      [profile] = SendProfiles.list_send_profiles()
      assert profile.name == "Transactional"
      # provider_kind is derived server-side from the chosen integration,
      # never taken from client params.
      assert profile.provider_kind == "smtp"
    end

    test "the aws_ses advanced fields render once an SES integration is chosen",
         %{conn: conn} do
      uuid = seed_aws_ses("ses-primary")

      {:ok, view, _html} = live(conn, @new_path)

      html =
        view
        |> element("form")
        |> render_change(%{
          "send_profile" => %{"name" => "Bulk", "integration_uuid" => uuid}
        })

      assert html =~ "Configuration set"
    end

    test "a missing required field surfaces a validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, @new_path)

      html =
        view
        |> element("form")
        |> render_submit(%{"send_profile" => %{"name" => ""}})

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end
  end

  # ---------------------------------------------------------------------------
  # /:uuid/edit — edit flow
  # ---------------------------------------------------------------------------

  describe "edit flow" do
    setup :setup_admin

    test "renders the existing values", %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp",
          from_name: "Acme Marketing"
        })

      {:ok, _view, html} =
        live(conn, Routes.path("/admin/settings/email-sending/profiles/#{profile.uuid}/edit"))

      assert html =~ ~s(value="Marketing")
      assert html =~ ~s(value="Acme Marketing")
    end

    test "saving updates the profile and redirects to the list", %{conn: conn} do
      uuid = seed_smtp()

      {:ok, profile} =
        SendProfiles.create_send_profile(%{
          name: "Marketing",
          integration_uuid: uuid,
          provider_kind: "smtp"
        })

      {:ok, view, _html} =
        live(conn, Routes.path("/admin/settings/email-sending/profiles/#{profile.uuid}/edit"))

      {:error, {:live_redirect, %{to: target}}} =
        view
        |> element("form")
        |> render_submit(%{
          "send_profile" => %{
            "name" => "Marketing Updated",
            "integration_uuid" => uuid
          }
        })

      assert target == @list_path
      assert SendProfiles.get_send_profile!(profile.uuid).name == "Marketing Updated"
    end

    test "an unknown uuid redirects to the list with an error flash", %{conn: conn} do
      ghost = "00000000-0000-7000-8000-000000000000"

      conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> Phoenix.Controller.fetch_flash()

      {:error, {:live_redirect, %{to: target}}} =
        live(conn, Routes.path("/admin/settings/email-sending/profiles/#{ghost}/edit"))

      assert target == @list_path
    end
  end
end
