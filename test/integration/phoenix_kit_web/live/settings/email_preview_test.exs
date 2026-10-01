defmodule PhoenixKitWeb.Live.Settings.EmailPreviewTest do
  @moduledoc """
  The admin email preview (`/admin/settings/email-sending/preview`): the list
  of known emails, the rendered subject/HTML/text, and where each part comes
  from.

  `async: false` — the file-override case points `:template_paths` at a
  fixture directory, which is application env.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/email-sending/preview")

  setup %{conn: conn} do
    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user)}
  end

  defp at(email, locale \\ "en"),
    do: @path <> "?" <> URI.encode_query(%{"email" => email, "locale" => locale})

  defp with_template_root(files) do
    root = Path.join(System.tmp_dir!(), "pk_preview_#{System.unique_integer([:positive])}")

    for {rel, content} <- files do
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    previous = Application.get_env(:phoenix_kit, :template_paths)
    Application.put_env(:phoenix_kit, :template_paths, [root])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :template_paths, previous),
        else: Application.delete_env(:phoenix_kit, :template_paths)

      File.rm_rf!(root)
    end)

    root
  end

  test "lists every core email and previews the first by default", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    for name <- ~w(register reset_password update_email magic_link magic_link_registration
                   organization_invitation new_login_alert failed_login_alert) do
      assert has_element?(view, "#email-preview-item-#{name}")
    end

    assert has_element?(view, "#email-preview-item-register.menu-active")
    assert has_element?(view, "#email-preview-subject", "Confirm your account")
  end

  test "renders the HTML in a script-less sandboxed iframe, and the text", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("reset_password"))

    assert has_element?(view, ~s(iframe#email-preview-html[sandbox=""]))

    assert has_element?(
             view,
             ~s(iframe#email-preview-html[srcdoc*="reset-password/preview-token"])
           )

    assert has_element?(view, "#email-preview-text", "reset-password/preview-token")
    refute has_element?(view, "#email-preview-missing")
  end

  test "says each part of a default email is the built-in default", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("new_login_alert"))

    assert has_element?(view, "#email-source-subject", "Built-in default")
    assert has_element?(view, "#email-source-text", "Built-in default")
    assert has_element?(view, "#email-source-text", "used for the HTML email, text email")
    assert has_element?(view, "#email-source-markdown", "Not used")
    assert has_element?(view, "#email-source-layout", "Built-in default")
    assert has_element?(view, "#email-source-header", "Built-in default")
    assert has_element?(view, "#email-source-subject", "new_login_alert/subject.en.txt")
  end

  test "shows a host file with its path, and the group's header file", %{conn: conn} do
    root =
      with_template_root(%{
        "register/subject.txt" => "From a file\n",
        "register/markdown.md" => "[Confirm]({{confirmation_url}})",
        "register/layout.txt" => "auth",
        "_header-auth/html.html" => "<p>GROUP HEADER</p>",
        "_footer/html.html" => "  \n"
      })

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(view, "#email-preview-subject", "From a file")
    assert has_element?(view, "#email-source-subject", "Host file")

    assert has_element?(
             view,
             "#email-source-subject [data-source-path]",
             Path.join(root, "register/subject.txt")
           )

    assert has_element?(view, "#email-source-markdown", "used for the HTML email, text email")
    assert has_element?(view, "#email-source-layout-group", "auth")

    assert has_element?(
             view,
             "#email-source-header [data-source-path]",
             Path.join(root, "_header-auth/html.html")
           )

    refute has_element?(view, "#email-source-footer [data-source-path]")
    assert has_element?(view, "#email-source-footer", "Built-in default")
    assert has_element?(view, "#email-preview-ignored", Path.join(root, "_footer/html.html"))
    assert has_element?(view, ~s(iframe#email-preview-html[srcdoc*="GROUP HEADER"]))
    # the hint names the file under the configured root
    assert has_element?(view, "#email-source-html", Path.join(root, "register/html.en.html"))
  end

  test "lists a placeholder no sample binds", %{conn: conn} do
    with_template_root(%{"register/text.txt" => "Code: {{one_time_code}}"})

    {:ok, view, _html} = live(conn, at("register"))

    assert has_element?(view, "#email-preview-missing", "one_time_code")
  end

  test "choosing another email patches the URL and re-renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    view |> element("#email-preview-item-failed_login_alert") |> render_click()

    assert_patch(view, at("failed_login_alert"))
    assert has_element?(view, "#email-preview-subject", "Failed sign-in attempts")
  end

  test "choosing a language patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("register"))

    view
    |> element("#email-preview-locale-form")
    |> render_change(%{"locale" => "en"})

    assert_patch(view, at("register", "en"))
  end

  test "an unknown email or language falls back to the defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, at("no_such_email", "xx"))

    assert has_element?(view, "#email-preview-item-register.menu-active")
    assert has_element?(view, "#email-preview-subject", "Confirm your account")
  end
end
