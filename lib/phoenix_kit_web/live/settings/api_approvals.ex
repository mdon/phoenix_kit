defmodule PhoenixKitWeb.Live.Settings.ApiApprovals do
  @moduledoc """
  Settings -> API -> Pending approvals: the queue of dangerous operations from API keys
  that need a person's approval (the approval path of the dangerous-operation flow).

  Shows the approvals the person may decide (an Owner: all; the creator of a key: the
  approvals of their keys for tools they hold the permission of) and the latest decided
  ones. **Approve** runs the operation, as the key's owner, in a task of
  `PhoenixKit.TaskSupervisor` that the page awaits with `start_async/3` (a long batch
  does not freeze the page, and a page that goes away does not stop it half-way);
  **Reject** discards it. Gated by the `api` permission
  (`PhoenixKitWeb.Users.Auth`'s view map).

  ## Rights are checked on the server

  Every event re-reads the person's rights from the database
  (`PhoenixKit.API.Access.fresh_scope/1`): the scope captured at mount can be stale.
  `PhoenixKit.API.Approvals.approve/3` and `reject/3` check again that the person may
  decide *this* approval, and an approval id the person may not decide answers
  `:forbidden`, however the event was made.

  The lists reload whenever any approval changes (`{:api_approval_changed, id}` on the
  topic of `PhoenixKit.API.Approvals`).
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.API.Access
  alias PhoenixKit.API.Approvals
  alias PhoenixKit.PubSub.Manager, as: PubSub
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @recent 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: PubSub.subscribe(Approvals.topic())

    socket =
      socket
      |> assign(:page_title, gettext("Pending approvals"))
      |> assign(
        :page_subtitle,
        gettext(
          "Operations from keys that need a person's approval wait here. Nothing runs until you approve it."
        )
      )
      |> assign(:page_section, gettext("API"))
      |> assign(:page_section_path, Routes.path("/admin/settings/api"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(
        :current_path,
        Routes.path("/admin/settings/api/approvals", locale: socket.assigns.current_locale_base)
      )
      |> assign(:api_scope, socket.assigns.phoenix_kit_current_scope)
      |> assign(:busy, nil)
      |> load()

    {:ok, socket}
  end

  # ── Events ───────────────────────────────────────────────────────

  @impl true
  def handle_event("approve", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case {socket.assigns.busy, Access.fresh_scope(socket.assigns.phoenix_kit_current_scope)} do
      {nil, {:ok, scope}} ->
        {:noreply,
         socket
         |> assign(:api_scope, scope)
         |> assign(:busy, uuid)
         |> start_async(:approve, fn -> approve_detached(uuid, scope) end)}

      {nil, :error} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}

      {_busy, _scope} ->
        {:noreply, socket}
    end
  end

  def handle_event("reject", %{"uuid" => uuid}, socket) when is_binary(uuid) do
    case Access.fresh_scope(socket.assigns.phoenix_kit_current_scope) do
      {:ok, scope} ->
        socket = assign(socket, :api_scope, scope)

        case Approvals.reject(uuid, scope) do
          {:ok, _row} ->
            {:noreply,
             socket |> load() |> put_flash(:info, gettext("The approval was rejected."))}

          {:error, reason} ->
            {:noreply, socket |> load() |> put_flash(:error, error_text(reason))}
        end

      :error ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to do that."))}
    end
  end

  def handle_event(_event, _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("That action is not available."))}
  end

  @impl true
  def handle_async(:approve, {:ok, result}, socket) do
    {:noreply, socket |> assign(:busy, nil) |> reload() |> flash_result(result)}
  end

  def handle_async(:approve, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:busy, nil)
     |> reload()
     |> put_flash(:error, gettext("The approval could not be processed."))}
  end

  @impl true
  def handle_info({:api_approval_changed, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  # ── State ────────────────────────────────────────────────────────

  # Only the waiter belongs to the page. The operation runs in a supervised task that is
  # not linked to it, so a closed tab, a navigation or a dropped socket cannot stop a
  # destructive batch part-way. If the task itself crashes, `Task.await/2`
  # exits and `handle_async(:approve, {:exit, _}, _)` reports it.
  defp approve_detached(uuid, scope) do
    PhoenixKit.TaskSupervisor
    |> Task.Supervisor.async_nolink(fn -> Approvals.approve(uuid, scope) end)
    |> Task.await(:infinity)
  end

  # The lists, from the rights the page last verified.
  defp load(socket) do
    scope = socket.assigns.api_scope

    # `view` is what the template shows of the preview (totals, the first rows, how many are hidden).
    pending =
      for entry <- Approvals.list_pending(scope),
          do: Map.put(entry, :view, preview_view(entry.approval.preview))

    socket
    |> assign(:pending, pending)
    |> assign(:recent, Approvals.list_recent(scope, @recent))
  end

  # The lists, after the person's rights were read again: someone who lost `api` sees nothing.
  defp reload(socket) do
    case Access.fresh_scope(socket.assigns.phoenix_kit_current_scope) do
      {:ok, scope} -> socket |> assign(:api_scope, scope) |> load()
      :error -> socket |> assign(:pending, []) |> assign(:recent, [])
    end
  end

  defp flash_result(socket, {:ok, %{status: "executed"}}),
    do: put_flash(socket, :info, gettext("The approval was executed."))

  defp flash_result(socket, {:ok, %{status: "stale"}}),
    do:
      put_flash(
        socket,
        :error,
        gettext(
          "The values changed since the request, so nothing was written. Ask the program to try again."
        )
      )

  defp flash_result(socket, {:ok, %{status: "failed"} = row}),
    do:
      put_flash(
        socket,
        :error,
        gettext("The operation could not run: %{detail}", detail: failure_detail(row))
      )

  defp flash_result(socket, {:ok, _other}), do: socket
  defp flash_result(socket, {:error, reason}), do: put_flash(socket, :error, error_text(reason))

  defp failure_detail(%{result: %{"error" => %{"detail" => detail}}}) when is_binary(detail),
    do: detail

  defp failure_detail(_row), do: ""

  defp error_text(:not_found), do: gettext("That approval was not found.")
  defp error_text(:forbidden), do: gettext("You are not allowed to decide this approval.")
  defp error_text(:not_pending), do: gettext("That approval is no longer waiting.")
  defp error_text(:expired), do: gettext("That approval has expired.")

  # ── Template helpers ─────────────────────────────────────────────

  # What the approver sees is what is approved, so nothing is cut silently. A preview is the
  # module's own shape; by convention it has `"totals"` and `"rows"`. The totals
  # come first, at most `@preview_rows` rows follow, and `hidden` says how many were left
  # out so the page can say so. Whatever else the module put in the preview is shown as
  # `other`, in full (capped by the 1 MB limit on an approval's input and preview).
  @preview_rows 25

  defp preview_view(preview) when is_map(preview) do
    rows = if is_list(preview["rows"]), do: preview["rows"], else: []
    shown = Enum.take(rows, @preview_rows)

    other =
      case preview["rows"] do
        list when is_list(list) -> Map.delete(preview, "rows")
        _not_a_list -> preview
      end

    %{
      totals: preview["totals"],
      rows: shown,
      hidden: length(rows) - length(shown),
      other: Map.delete(other, "totals")
    }
  end

  defp preview_view(_not_a_map), do: %{totals: nil, rows: [], hidden: 0, other: %{}}

  # JSON, not Elixir terms: the approver reads the same keys an API client reads.
  defp json_text(term), do: Jason.encode!(term, pretty: true)

  defp status_label("executed"), do: gettext("Executed")
  defp status_label("failed"), do: gettext("Failed")
  defp status_label("rejected"), do: gettext("Rejected")
  defp status_label("stale"), do: gettext("Stale")
  defp status_label("expired"), do: gettext("Expired")
  defp status_label(_approved_or_executing), do: gettext("Running")

  defp status_class("executed"), do: "badge-success"
  defp status_class("failed"), do: "badge-error"
  defp status_class(status) when status in ["approved", "executing"], do: "badge-info"
  defp status_class(_other), do: "badge-ghost"
end
