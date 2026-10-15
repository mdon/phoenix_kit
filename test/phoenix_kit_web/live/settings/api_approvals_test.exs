defmodule PhoenixKitWeb.Live.Settings.ApiApprovalsTest do
  @moduledoc """
  Settings -> API -> Pending approvals: who sees what, approving and rejecting from the
  page, the outcomes the page reports, live updates, and the server-side re-checks of a
  forged or stale event.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.API.Approvals
  alias PhoenixKit.API.Confirm
  alias PhoenixKit.API.Confirm.Confirmation
  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.KeyTestSupport
  alias PhoenixKit.Test.ApiFlowHarness
  alias PhoenixKit.Test.ApiFlowStore
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RolePermission
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  @path Routes.path("/admin/settings/api/approvals")
  @delete "flowkit.delete_items"

  setup %{conn: conn} do
    ApiFlowHarness.setup_flow()

    # Approving runs the operation in a task of this supervisor, so a closed page cannot stop it; the app
    # starts it, the test environment does not.
    start_supervised!({Task.Supervisor, name: PhoenixKit.TaskSupervisor})
    owner = Auth.get_user_by_email("seed-owner@phoenixkit.test")
    %{conn: log_in_user(conn, owner), agent: ApiFlowHarness.agent()}
  end

  # An Admin who holds `api` and the tool permissions, with a key of their own that
  # needs approval: a person who is not the Owner and may decide only their own keys.
  defp admin_with_key do
    {admin, _token} = create_admin_user()
    role = Roles.get_role_by_name("Admin")
    for key <- ["api", "settings", "dashboard"], do: Permissions.grant_permission(role.uuid, key)

    {:ok, key, _token} =
      Keys.create_key(admin, KeyTestSupport.scope_of(admin), %{
        "name" => "Admin's agent",
        "scopes" => ApiFlowHarness.scopes(),
        "requires_approval" => true
      })

    {:ok, actor} = Confirm.live_actor(key.uuid)
    %{admin: admin, key: key, agent: %{actor: actor}}
  end

  defp pending!(agent, ids \\ ["a", "b"]) do
    {:ok, row, :created} = ApiFlowHarness.queue(agent, @delete, %{"ids" => ids})
    row
  end

  defp reload(row), do: Repo.get!(Confirmation, row.uuid)

  # The page's scope is captured at mount; a plain delete sends no PubSub message, so the
  # page does not hear of it: the window the server-side re-check is for.
  defp drop_api_silently! do
    role = Roles.get_role_by_name("Admin")

    {1, _} =
      Repo.delete_all(
        from(rp in RolePermission, where: rp.role_uuid == ^role.uuid and rp.module_key == "api")
      )

    :ok
  end

  describe "the list" do
    test "an Owner sees every pending approval with its key, tool and preview", %{
      conn: conn,
      agent: agent
    } do
      row = pending!(agent)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-approvals-page")
      assert has_element?(view, "#approval-#{row.uuid}", @delete)
      assert has_element?(view, "#approval-#{row.uuid}", agent.key.prefix)
      assert has_element?(view, "#approval-preview-#{row.uuid}", "delete")
      assert has_element?(view, "#approve-#{row.uuid}")
      assert has_element?(view, "#reject-#{row.uuid}")
      refute has_element?(view, "#approvals-empty")
    end

    test "a short preview shows the totals and every row, and Approve asks once", %{
      conn: conn,
      agent: agent
    } do
      row = pending!(agent)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#approval-totals-#{row.uuid}", "2")
      assert has_element?(view, "#approval-rows-#{row.uuid}")
      refute has_element?(view, "#approval-truncated-#{row.uuid}")
      refute has_element?(view, "#approve-#{row.uuid}[data-confirm]")
    end

    test "a long preview is cut visibly: totals first, 25 rows, a notice with the rest, a second confirmation",
         %{conn: conn, agent: agent} do
      row = pending!(agent, Enum.map(1..30, &"item-#{&1}"))
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#approval-totals-#{row.uuid}", "30")
      assert has_element?(view, "#approval-truncated-#{row.uuid}", "5")
      assert has_element?(view, "#approve-#{row.uuid}[data-confirm]")

      assert view
             |> element("#approval-rows-#{row.uuid}")
             |> render()
             |> String.split("item-")
             |> length() == 26
    end

    test "says so when nothing waits", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#approvals-empty")
    end

    test "an approval queued while the page is open appears", %{conn: conn, agent: agent} do
      {:ok, view, _html} = live(conn, @path)
      assert has_element?(view, "#approvals-empty")

      row = pending!(agent)
      _ = :sys.get_state(view.pid)

      assert has_element?(view, "#approval-#{row.uuid}")
      refute has_element?(view, "#approvals-empty")
    end

    test "the creator of a key sees the approvals of their keys only", %{agent: other_agent} do
      mine = admin_with_key()
      pending!(other_agent, ["a"])
      my_row = pending!(mine.agent, ["b"])

      conn = log_in_user(build_conn(), mine.admin)
      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#approval-#{my_row.uuid}")
      assert view |> render() |> String.split(~s(id="approval-preview-)) |> length() == 2
    end

    test "decided approvals are listed as recent", %{conn: conn, agent: agent} do
      row = pending!(agent)
      owner_scope = KeyTestSupport.scope_of(KeyTestSupport.owner_user())
      {:ok, _} = Approvals.reject(row.uuid, owner_scope)

      {:ok, view, _html} = live(conn, @path)

      assert has_element?(view, "#api-approvals-recent")
      assert has_element?(view, "#recent-#{row.uuid}", "Rejected")
      refute has_element?(view, "#approval-#{row.uuid}")
    end
  end

  describe "approving" do
    test "runs the operation and moves the approval to the recent list", %{
      conn: conn,
      agent: agent
    } do
      row = pending!(agent)
      {:ok, view, _html} = live(conn, @path)

      view |> element("#approve-#{row.uuid}") |> render_click()
      html = render_async(view)

      assert html =~ "executed"
      assert reload(row).status == "executed"
      assert ApiFlowStore.items() == %{"c" => 300}
      refute has_element?(view, "#approval-#{row.uuid}")
      assert has_element?(view, "#recent-#{row.uuid}", "Executed")
    end

    test "says what happened when the values changed", %{conn: conn, agent: agent} do
      row = pending!(agent)
      ApiFlowStore.put("a", 999)
      {:ok, view, _html} = live(conn, @path)

      view |> element("#approve-#{row.uuid}") |> render_click()
      html = render_async(view)

      assert html =~ "nothing was written"
      assert reload(row).status == "stale"
      assert ApiFlowStore.items()["a"] == 999
    end

    test "says why the operation could not run", %{conn: conn, agent: agent} do
      {:ok, row, :created} =
        ApiFlowHarness.queue(agent, "flowkit.progress_write", %{"fail" => true})

      {:ok, view, _html} = live(conn, @path)

      view |> element("#approve-#{row.uuid}") |> render_click()
      html = render_async(view)

      assert html =~ "could not run"
      assert html =~ "Two lines are short."
      assert reload(row).status == "failed"
    end

    test "an approval someone else decided meanwhile is reported, not run twice", %{
      conn: conn,
      agent: agent
    } do
      row = pending!(agent)
      {:ok, view, _html} = live(conn, @path)
      {:ok, _} = Approvals.reject(row.uuid, KeyTestSupport.scope_of(KeyTestSupport.owner_user()))

      html = render_hook(view, "approve", %{"uuid" => row.uuid})
      _ = render_async(view)

      assert reload(row).status == "rejected"
      assert ApiFlowStore.items() == %{"a" => 100, "b" => 200, "c" => 300}
      assert is_binary(html)
      assert render(view) =~ "no longer waiting"
    end

    test "an operation already running still finishes when the page goes away", %{
      conn: conn,
      agent: agent
    } do
      # The handler stops at `hold` and tells this test, so the page can be killed in the
      # middle of the operation (a closed tab, a dropped socket, a deploy of the page).
      ApiFlowStore.set_gate(self())

      {:ok, row, :created} =
        ApiFlowHarness.queue(agent, "flowkit.progress_write", %{"hold" => true})

      {:ok, view, _html} = live(conn, @path)
      Process.flag(:trap_exit, true)

      view |> element("#approve-#{row.uuid}") |> render_click()
      assert_receive {:held, worker}, 5_000
      assert reload(row).status == "executing"
      worker_ref = Process.monitor(worker)

      page = view.pid
      # Let the page finish reloading after the approval's change broadcasts: a process killed
      # in the middle of a sandboxed query takes the shared test connection down with it.
      _ = :sys.get_state(page)
      page_ref = Process.monitor(page)
      Process.exit(page, :kill)
      assert_receive {:DOWN, ^page_ref, :process, ^page, :killed}, 5_000

      # The page is gone and the operation is still waiting at its gate, not killed with it.
      refute_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 300
      assert reload(row).status == "executing"

      send(worker, :release)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000

      done = reload(row)
      assert done.status == "executed"
      assert done.result["done"] == 2
    end
  end

  describe "rejecting" do
    test "discards the approval at once", %{conn: conn, agent: agent} do
      row = pending!(agent)
      {:ok, view, _html} = live(conn, @path)

      view |> element("#reject-#{row.uuid}") |> render_click()

      assert reload(row).status == "rejected"
      assert ApiFlowStore.items() == %{"a" => 100, "b" => 200, "c" => 300}
      refute has_element?(view, "#approval-#{row.uuid}")
      assert render(view) =~ "rejected"
    end
  end

  describe "server-side checks" do
    test "a forged approve of an approval the person may not decide changes nothing", %{
      agent: other_agent
    } do
      theirs = pending!(other_agent)
      mine = admin_with_key()
      {:ok, view, _html} = live(log_in_user(build_conn(), mine.admin), @path)

      html = render_hook(view, "approve", %{"uuid" => theirs.uuid})
      _ = render_async(view)

      assert html =~ "not allowed" or render(view) =~ "not allowed"
      assert reload(theirs).status == "pending"
      assert ApiFlowStore.items() == %{"a" => 100, "b" => 200, "c" => 300}
    end

    test "a forged reject of an unknown id is reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      assert render_hook(view, "reject", %{"uuid" => UUIDv7.generate()}) =~ "not found"
    end

    test "an event nobody defined is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      assert render_hook(view, "nope", %{}) =~ "not available"
    end

    test "a person who lost api since the page opened cannot decide", %{agent: _agent} do
      mine = admin_with_key()
      row = pending!(mine.agent)
      {:ok, view, _html} = live(log_in_user(build_conn(), mine.admin), @path)
      drop_api_silently!()

      html = render_hook(view, "reject", %{"uuid" => row.uuid})

      assert html =~ "not allowed"
      assert reload(row).status == "pending"
    end

    test "a person who lost api since the page opened cannot approve either", %{agent: _agent} do
      mine = admin_with_key()
      row = pending!(mine.agent)
      {:ok, view, _html} = live(log_in_user(build_conn(), mine.admin), @path)
      drop_api_silently!()

      html = render_hook(view, "approve", %{"uuid" => row.uuid})
      _ = render_async(view)

      assert html =~ "not allowed"
      assert reload(row).status == "pending"
      assert ApiFlowStore.items() == %{"a" => 100, "b" => 200, "c" => 300}
    end
  end

  describe "who may open the page" do
    test "an Admin without api is refused", %{} do
      {admin, _token} = create_admin_user()
      result = live(log_in_user(build_conn(), admin), @path)

      assert match?({:error, {kind, _}} when kind in [:redirect, :live_redirect], result)
    end

    test "an Admin who was granted api opens it", %{} do
      {admin, _token} = create_admin_user()
      {:ok, _} = Permissions.grant_permission(Roles.get_role_by_name("Admin").uuid, "api")

      assert {:ok, view, _html} = live(log_in_user(build_conn(), admin), @path)
      assert has_element?(view, "#api-approvals-page")
    end
  end
end
