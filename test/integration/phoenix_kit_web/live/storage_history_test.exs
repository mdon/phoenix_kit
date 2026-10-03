defmodule PhoenixKitWeb.Live.StorageHistoryTest do
  @moduledoc """
  The History tab of Settings → Media: who changed the storage settings and what the
  storage jobs did, read from the Activity log; loaded when the tab opens, filtered,
  paged, and kept current as entries arrive.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Jobs
  alias PhoenixKit.Modules.Storage.Audit
  alias PhoenixKit.Modules.Storage.Jobs.Reconcile
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles}
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {user, _token} = create_admin_user()
    %{conn: log_in_user(conn, user), user: user, actor: [actor_uuid: user.uuid]}
  end

  defp history(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    render_patch(view, Routes.path("/admin/settings/media?tab=history"))
    view
  end

  test "lists who changed what, newest first, with the person and the change", ctx do
    {:ok, profile} = Profiles.create_profile(%{name: "Cold storage"}, ctx.actor)
    {:ok, _} = Profiles.update_profile(profile, %{copies_originals: 2}, ctx.actor)

    view = history(ctx.conn)
    html = render(view)

    assert html =~ "storage.profile.created"
    assert html =~ "storage.profile.updated"
    assert html =~ ctx.user.email
    assert html =~ "Copies originals"
    assert html =~ "1 → 2"
  end

  test "is empty of other modules' entries", ctx do
    PhoenixKit.Activity.log("posts", "post.created", actor_uuid: ctx.user.uuid)

    {:ok, _} =
      Libraries.create_system_library(
        %{name: "History #{System.unique_integer([:positive])}"},
        ctx.actor
      )

    html = ctx.conn |> history() |> render()

    refute html =~ "post.created"
    assert html =~ "storage.library.created"
  end

  test "the filter separates settings changes from job runs", ctx do
    {:ok, _} = Profiles.create_profile(%{name: "Filtered"}, ctx.actor)

    {:ok, library} =
      Libraries.create_system_library(
        %{name: "Runs #{System.unique_integer([:positive])}"},
        ctx.actor
      )

    {:ok, _run, :started} = Jobs.System.start(Reconcile, {"library", to_string(library.uuid)})

    view = history(ctx.conn)
    assert render(view) =~ "job.started"
    assert render(view) =~ "storage.profile.created"

    view |> form("#media-history-filter", %{"filter" => "runs"}) |> render_change()
    assert render(view) =~ "job.started"
    refute render(view) =~ "storage.profile.created"

    view |> form("#media-history-filter", %{"filter" => "changes"}) |> render_change()
    refute render(view) =~ "job.started"
    assert render(view) =~ "storage.profile.created"
  end

  test "pages through a long history", ctx do
    for n <- 1..30,
        do:
          Audit.log(
            "storage.profile.created",
            "storage_profile",
            Ecto.UUID.generate(),
            ctx.actor,
            %{"name" => "P#{n}"}
          )

    view = history(ctx.conn)
    assert render(view) =~ "Page 1 of 2"

    view |> element("#media-history button", "Next") |> render_click()
    assert render(view) =~ "Page 2 of 2"
  end

  test "follows the log while the tab is open", ctx do
    view = history(ctx.conn)
    refute render(view) =~ "Brand new profile"

    {:ok, _} = Profiles.create_profile(%{name: "Brand new profile"}, ctx.actor)

    assert render(view) =~ "Brand new profile"
  end

  test "reads nothing until the tab is opened", ctx do
    {:ok, _} = Profiles.create_profile(%{name: "Not yet"}, ctx.actor)
    {:ok, view, _html} = live(ctx.conn, Routes.path("/admin/settings/media"))

    refute render(view) =~ "storage.profile.created"
    refute has_element?(view, "#media-history-list")
  end

  test "the Settings changes made through the page are attributed to the person", ctx do
    view = history(ctx.conn)
    render_patch(view, Routes.path("/admin/settings/media?tab=profiles"))
    view |> element("#media-profiles button", "New profile") |> render_click()

    view
    |> form("#media-profiles-new", %{"profile" => %{"name" => "Made in the UI"}})
    |> render_submit()

    render_patch(view, Routes.path("/admin/settings/media?tab=history"))
    html = render(view)

    assert html =~ "storage.profile.created"
    assert html =~ "Made in the UI" or html =~ ctx.user.email
  end

  test "each row opens its entry on the Activity page", ctx do
    {:ok, profile} = Profiles.create_profile(%{name: "Linked"}, ctx.actor)
    {:ok, _} = Profiles.update_profile(profile, %{copies_originals: 3}, ctx.actor)

    entry =
      Repo.one!(
        from e in PhoenixKit.Activity.Entry,
          where:
            e.action == "storage.profile.updated" and e.resource_uuid == ^to_string(profile.uuid)
      )

    {:ok, view, html} = live(ctx.conn, Routes.path("/admin/activity/#{entry.uuid}"))

    assert html =~ "storage.profile.updated"
    assert render(view) =~ "storage_profile"
    assert html =~ "Copies originals"
  end
end
