defmodule PhoenixKitWeb.Test.AdminEditProbeLive do
  @moduledoc """
  Stand-in for a plugin or host LiveView whose public page has an admin
  counterpart: it renders through `{PhoenixKitWeb.Layouts, :admin}` (the layout
  plugin views get) and declares its Edit target with
  `AdminEditHelper.assign_admin_edit/3`, naming the module permission from the
  `perm` query param (none when absent).

  Routed only in Mix.env() == :test (see PhoenixKitWeb.Router), under `/admin`
  so the layout draws the admin chrome; backs
  test/integration/phoenix_kit_web/live/admin_edit_passthrough_test.exs.
  """
  use Phoenix.LiveView, layout: {PhoenixKitWeb.Layouts, :admin}

  alias PhoenixKitWeb.AdminEditHelper

  on_mount {PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}

  @impl true
  def mount(params, _session, socket) do
    opts =
      case params do
        %{"perm" => perm} -> [label: "Edit probe", permission: perm]
        _ -> [label: "Edit probe"]
      end

    socket =
      socket
      |> AdminEditHelper.assign_admin_edit("/admin/probe/1/edit", opts)
      |> assign(:page_title, "Probe")

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div id="admin-edit-probe">probe body</div>
    """
  end
end
