defmodule PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent do
  @moduledoc """
  The Libraries tab of Settings → Media: the system storage libraries
  (`PhoenixKit.Modules.Storage.Libraries`), what each holds, and creating,
  renaming and deleting them.

  The media page itself only switches between libraries (and only once there
  are two); managing them lives here, next to the buckets their files are
  stored in. The default library, Media, can be renamed but never deleted,
  and any other library only once it holds nothing — the database refuses it
  otherwise too. Renaming keeps a library's URL (`/admin/media/library/<slug>`).
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, creating: false, renaming: nil, rows: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.rows, do: socket, else: load(socket))}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply, assign(socket, creating: true, renaming: nil)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, creating: false, renaming: nil)}
  end

  def handle_event("create", %{"name" => name}, socket) do
    case Libraries.create_system_library(%{name: name}) do
      {:ok, library} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> load()
         |> flash(:info, gettext("Library \"%{name}\" created", name: library.name))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("start_rename", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, renaming: uuid, creating: false)}
  end

  def handle_event("rename", %{"uuid" => uuid, "name" => name}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, renamed} <- Libraries.rename_library(library, name) do
      {:noreply,
       socket
       |> assign(:renaming, nil)
       |> load()
       |> flash(:info, gettext("Library renamed to \"%{name}\"", name: renamed.name))}
    else
      nil -> {:noreply, socket}
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("delete", %{"uuid" => uuid}, socket) do
    with %{} = library <- find(socket, uuid),
         {:ok, _} <- Libraries.delete_library(library) do
      {:noreply, socket |> load() |> flash(:info, gettext("Library deleted"))}
    else
      nil ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext("Only an empty library can be deleted, and never the default one.")
         )}
    end
  end

  # Only a library this tab listed: the uuid arrives from the client.
  defp find(socket, uuid) do
    Enum.find_value(socket.assigns.rows, fn %{library: library} ->
      if library.uuid == uuid, do: library
    end)
  end

  defp load(socket), do: assign(socket, :rows, Libraries.list_system_libraries_with_stats())

  # A component's own `put_flash` reaches the page only when it also
  # navigates, which this tab does not: the settings page puts it
  # (`handle_info({LibrariesComponent, {:flash, …}})`).
  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Map.values()
    |> List.flatten()
    |> Enum.join("; ")
    |> then(&(gettext("Library name") <> ": " <> &1))
  end

  defp media_path(%{is_default: true}), do: Routes.path("/admin/media")
  defp media_path(%{slug: slug}), do: Routes.path("/admin/media/library/#{slug}")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="card bg-base-100 shadow-xl mb-6 mt-6">
      <div class="card-body">
        <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
          <h2 class="card-title text-lg">
            <.icon name="hero-rectangle-stack" class="w-6 h-6 mr-2" /> {gettext("Libraries")}
          </h2>
          <button
            :if={not @creating}
            type="button"
            class="btn btn-primary"
            phx-click="new"
            phx-target={@myself}
          >
            <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("New library")}
          </button>
        </div>

        <p class="text-sm text-base-content/70 mb-4">
          {gettext(
            "A library is a separate space in Media with its own folders. Everything uploaded so far is in the default library. The Media page shows a library switcher once there are two or more."
          )}
        </p>

        <form
          :if={@creating}
          id={"#{@id}-new"}
          phx-submit="create"
          phx-target={@myself}
          class="flex flex-wrap items-center gap-2 mb-4"
        >
          <input
            type="text"
            name="name"
            id={"#{@id}-new-name"}
            class="input input-sm w-64"
            placeholder={gettext("Library name")}
            maxlength="255"
            required
            autofocus
          />
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel" phx-target={@myself}>
            {gettext("Cancel")}
          </button>
        </form>

        <div class="overflow-x-auto">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>{gettext("Name")}</th>
                <th>{gettext("Address")}</th>
                <th class="text-right">{gettext("Files")}</th>
                <th class="text-right">{gettext("Folders")}</th>
                <th class="text-right">{gettext("Size")}</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={%{library: library} = row <- @rows} id={"#{@id}-#{library.uuid}"}>
                <td>
                  <%= if @renaming == library.uuid do %>
                    <form
                      id={"#{@id}-rename-#{library.uuid}"}
                      phx-submit="rename"
                      phx-target={@myself}
                      class="flex items-center gap-2"
                    >
                      <input type="hidden" name="uuid" value={library.uuid} />
                      <input
                        type="text"
                        name="name"
                        id={"#{@id}-rename-#{library.uuid}-name"}
                        value={library.name}
                        class="input input-sm w-56"
                        maxlength="255"
                        required
                        autofocus
                      />
                      <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
                      <button
                        type="button"
                        class="btn btn-sm btn-ghost"
                        phx-click="cancel"
                        phx-target={@myself}
                      >
                        {gettext("Cancel")}
                      </button>
                    </form>
                  <% else %>
                    <span class="font-medium">{library.name}</span>
                    <span :if={library.is_default} class="badge badge-sm badge-ghost ml-2">
                      {gettext("Default")}
                    </span>
                  <% end %>
                </td>
                <td>
                  <.link navigate={media_path(library)} class="link link-hover font-mono text-xs">
                    {media_path(library)}
                  </.link>
                </td>
                <td class="text-right">{row.files}</td>
                <td class="text-right">{row.folders}</td>
                <td class="text-right">{Format.bytes(row.bytes)}</td>
                <td class="text-right whitespace-nowrap">
                  <button
                    :if={@renaming != library.uuid}
                    type="button"
                    class="btn btn-xs btn-ghost"
                    phx-click="start_rename"
                    phx-value-uuid={library.uuid}
                    phx-target={@myself}
                  >
                    <.icon name="hero-pencil" class="w-4 h-4" /> {gettext("Rename")}
                  </button>
                  <button
                    :if={not library.is_default}
                    type="button"
                    class="btn btn-xs btn-ghost text-error"
                    disabled={row.files > 0 or row.folders > 0}
                    title={
                      if row.files > 0 or row.folders > 0,
                        do: gettext("Only an empty library can be deleted.")
                    }
                    phx-click="delete"
                    phx-value-uuid={library.uuid}
                    phx-target={@myself}
                    data-confirm={gettext("Delete this library?")}
                  >
                    <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end
end
