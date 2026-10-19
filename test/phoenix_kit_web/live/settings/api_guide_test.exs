defmodule PhoenixKitWeb.Live.Settings.ApiGuideTest do
  @moduledoc """
  Settings -> API -> Guide: who may open it, what it says about the endpoints, the
  client snippets (decoded, not matched as text, so a broken file shows), the tools
  grouped by module, and the table of errors.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.API.MCP.Shape
  alias PhoenixKit.API.Problem
  alias PhoenixKit.Test.ApiFlowHarness
  alias PhoenixKit.Test.ApiFlowTools
  alias PhoenixKit.Test.ApiHarness
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api/guide")

  setup %{conn: conn} do
    ApiFlowHarness.setup_flow()
    KeyTestSupport.register_fake_module!()
    KeyTestSupport.put_setting("project_title", "Acme Print")

    {admin, _token} = create_admin_user()
    {:ok, _} = Permissions.grant_permission(Roles.get_role_by_name("Admin").uuid, "api")

    %{conn: log_in_user(conn, admin)}
  end

  # The text of one element, entities decoded: what a person would copy.
  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
  end

  defp base, do: Routes.base_url()

  describe "who may open the page" do
    test "an Admin without api is refused" do
      {admin, _token} = create_admin_user()
      :ok = Permissions.revoke_permission(Roles.get_role_by_name("Admin").uuid, "api")

      result = live(log_in_user(build_conn(), admin), @path)

      assert match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)
    end

    test "a role that holds only api opens it" do
      {user, role} = KeyTestSupport.user_with([])
      assert Permissions.get_permissions_for_role(role.uuid) == ["api"]

      assert {:ok, view, _html} = live(log_in_user(build_conn(), user), @path)
      assert has_element?(view, "#api-guide-page")
    end
  end

  describe "Settings -> API" do
    test "links to the guide", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/api"))

      assert has_element?(view, "#api-guide-card")
      assert has_element?(view, ~s(#api-guide-link[href="#{@path}"]))
    end
  end

  describe "status" do
    test "says which sides are on and links to the switches", %{conn: conn} do
      ApiHarness.switch(:admin, true)
      ApiHarness.switch(:public, false)

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, ~s(#guide-status-admin[data-enabled="true"]))
      assert has_element?(view, ~s(#guide-status-public[data-enabled="false"]))

      assert has_element?(
               view,
               ~s(#guide-switches-link[href="#{Routes.path("/admin/settings/api")}"])
             )
    end
  end

  describe "endpoints" do
    test "are built from the base URL and the configured prefix", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-base-url") == base()
      assert text(view, "#guide-rest-url") == base() <> Routes.path("/api/admin/v1")
      assert text(view, "#guide-mcp-url") == base() <> Routes.path("/mcp/admin")

      assert text(view, "#guide-openapi-url") ==
               base() <> Routes.path("/api/admin/v1") <> "/openapi.json"

      assert text(view, "#guide-rest-url") =~ "/phoenix_kit/api/admin/v1"
      assert has_element?(view, "#guide-domains-note")
    end

    test "name the headers and keep credentials out of URLs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for header <- ["Authorization", "Idempotency-Key", "RateLimit-Remaining", "Retry-After"] do
        assert has_element?(view, "#guide-headers code", header)
      end
    end
  end

  describe "client snippets" do
    test "Claude Code: the header comes after the URL, the key is a placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      command = text(view, "#guide-claude-code-command")

      assert command ==
               "claude mcp add --transport http acme-print-admin " <>
                 "'#{base()}#{Routes.path("/mcp/admin")}' --header 'Authorization: Bearer <your key>'"

      {url_at, _} = :binary.match(command, "/mcp/admin")
      {header_at, _} = :binary.match(command, "--header")
      assert url_at < header_at
      refute has_element?(view, "#guide-claude-code-command", "--scope")
    end

    test "Cursor: user-level file, url and headers", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-cursor-file") == "~/.cursor/mcp.json"

      assert %{
               "mcpServers" => %{
                 "acme-print-admin" => %{
                   "url" => url,
                   "headers" => %{"Authorization" => "Bearer <your key>"}
                 }
               }
             } = view |> text("#guide-cursor-config") |> Jason.decode!()

      assert url == base() <> Routes.path("/mcp/admin")
    end

    test "VS Code: asks for the key through inputs instead of storing it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert %{
               "inputs" => [
                 %{
                   "type" => "promptString",
                   "id" => "acme-print-admin-key",
                   "description" => "API key",
                   "password" => true
                 }
               ],
               "servers" => %{
                 "acme-print-admin" => %{
                   "type" => "http",
                   "url" => url,
                   "headers" => %{"Authorization" => "Bearer ${input:acme-print-admin-key}"}
                 }
               }
             } = view |> text("#guide-vscode-config") |> Jason.decode!()

      assert url == base() <> Routes.path("/mcp/admin")
    end

    test "no snippet or sentence on the page holds a real key", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-key-warning")
      refute render(view) =~ ~r/\bpk_[0-9a-f]{8}_/
    end

    test "the server name is the slug of the project title plus -admin", %{conn: conn} do
      KeyTestSupport.put_setting(
        "project_title",
        "Café Déco — Prints & Frames, the very long name"
      )

      {:ok, view, _html} = live(conn, @path)

      name = Regex.run(~r/--transport http (\S+) /, text(view, "#guide-claude-code-command"))
      assert [_, name] = name
      assert name =~ ~r/\A[a-z0-9-]+-admin\z/
      assert String.starts_with?(name, "cafe-deco")
      assert byte_size(name) <= 32 + byte_size("-admin")
    end

    test "a title cut at a word break leaves no dangling dash", %{conn: conn} do
      KeyTestSupport.put_setting("project_title", "abcdefghij abcdefghij abcdefghi xyz")
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-claude-code-command") =~
               "--transport http abcdefghij-abcdefghij-abcdefghi-admin '"
    end

    test "a title with nothing to slug falls back to shop", %{conn: conn} do
      KeyTestSupport.put_setting("project_title", "日本語")
      {:ok, view, _html} = live(conn, @path)

      assert text(view, "#guide-claude-code-command") =~ "--transport http shop-admin '"
    end
  end

  describe "tools" do
    test "are grouped by module, with scope, title and flags", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-tools-group-api_flow_tools", "API flow test tools")
      assert has_element?(view, "#guide-tools-group-apikeytest", "API key test module")
      assert has_element?(view, "#guide-tools-group-core", "Core")

      assert has_element?(view, "#guide-tool-system-get_identity")
      assert has_element?(view, "#guide-tools-group-core #guide-tool-system-get_identity")

      assert has_element?(
               view,
               "#guide-tools-group-api_flow_tools #guide-tool-flowkit-delete_items",
               "flowkit.items:delete"
             )

      assert has_element?(view, "#guide-tool-apikeytest-list_things", "List_things")
    end

    test "core's own tools come first, the modules follow by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert ids(view, "#guide-tools > .card-body > div[id^=guide-tools-group-]") == [
               "guide-tools-group-core",
               "guide-tools-group-api_flow_tools",
               "guide-tools-group-apikeytest",
               "guide-tools-group-api_test_tools"
             ]
    end

    test "show the MCP name beside the dotted one", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#guide-tool-flowkit-read_items", "flowkit.read_items")
      assert has_element?(view, "#guide-tool-flowkit-read_items", "flowkit_read_items")
    end

    test "mark writes and the tools that may ask for confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tool-flowkit-read_items .guide-tool-writes")
      assert has_element?(view, "#guide-tool-flowkit-touch_item .guide-tool-writes")
      refute has_element?(view, "#guide-tool-flowkit-touch_item .guide-tool-confirm")
      assert has_element?(view, "#guide-tool-flowkit-delete_items .guide-tool-writes")
      assert has_element?(view, "#guide-tool-flowkit-delete_items .guide-tool-confirm")
      assert has_element?(view, "#guide-tool-flowkit-set_values .guide-tool-confirm")
    end

    test "list no public tool", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tool-flowkit-mint_cart")
      refute has_element?(view, "#guide-tool-apikeytest-public_thing")
    end

    test "a module that is switched off is not listed", %{conn: conn} do
      ApiFlowTools.set_enabled(false)
      {:ok, view, _html} = live(conn, @path)

      refute has_element?(view, "#guide-tools-group-api_flow_tools")
      refute has_element?(view, "#guide-tool-flowkit-read_items")
      assert has_element?(view, "#guide-tools-note")
    end
  end

  describe "dangerous operations" do
    test "name the control fields and link to the approvals page", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      for field <- ["dry_run", "confirm_token", "idempotency_key"] do
        assert has_element?(view, "#guide-danger code", field)
      end

      assert has_element?(
               view,
               ~s(#guide-approvals-link[href="#{Routes.path("/admin/settings/api/approvals")}"])
             )
    end
  end

  describe "errors" do
    test "one row per code, by status then code, with the advice", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      rows = ids(view, "#guide-errors tbody tr")

      assert length(rows) == map_size(Problem.statuses())
      assert length(Enum.uniq(rows)) == length(rows)

      first_ten =
        ~w(invalid_json token_in_url unauthorized forbidden ip_not_allowed origin_not_allowed cart_not_found module_disabled not_found method_not_allowed)

      assert Enum.take(rows, 10) == Enum.map(first_ten, &"guide-error-#{&1}")

      assert List.last(rows) == "guide-error-internal_error"

      for {code, status} <- Problem.statuses() do
        row = "#guide-error-#{code}"
        assert has_element?(view, row, Integer.to_string(status))
        assert has_element?(view, row, Atom.to_string(code))
        assert text(view, row) =~ Shape.advice(code)
      end
    end
  end
end
