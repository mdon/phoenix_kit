defmodule PhoenixKitWeb.Live.Components.LibrarySettings do
  @moduledoc """
  The profile's Media tab (`/profile/settings/media`): the signed-in user's
  storage libraries (V203).

    * create one (with `storage.create_library`, up to the per-user limit)
    * rename, make the default, trash (the owner; a manager may rename)
    * members: add by email, change a role, remove (the owner or a manager)
    * leave a library someone else shared

  Browsing and uploading are `/admin/libraries`. Every action goes through
  `PhoenixKit.Modules.Storage.Libraries`, which re-checks who may do it;
  what this component hides is a courtesy, not the boundary.

  Messages are shown inside the component: a LiveComponent's `put_flash`
  never reaches the page.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage.{Libraries, Library, LibraryMember}
  alias PhoenixKit.Users.Auth.Scope

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:scope, assigns.scope)
      |> assign_new(:message, fn -> nil end)
      |> assign_new(:open_members, fn -> nil end)
      |> load()

    {:ok, socket}
  end

  defp load(socket) do
    scope = socket.assigns.scope
    entries = Libraries.list_user_libraries(Scope.user_uuid(scope))
    {owned, shared} = Enum.split_with(entries, &(&1.role == :owner))

    managed =
      Enum.filter(shared, &Libraries.allows?(&1.role, :members))

    open = socket.assigns.open_members

    socket
    |> assign(:owned, owned)
    |> assign(:shared, shared)
    |> assign(:can_create, Libraries.may_create_library?(scope))
    |> assign(:limit, Libraries.user_library_limit())
    |> assign(:managed_uuids, Enum.map(managed, & &1.library.uuid))
    |> assign(
      :members,
      if(open, do: open |> library_of(owned ++ shared) |> members(), else: [])
    )
  end

  defp library_of(uuid, entries) do
    Enum.find_value(entries, fn %{library: library} -> library.uuid == uuid && library end)
  end

  defp members(nil), do: []
  defp members(%Library{} = library), do: Libraries.list_members(library)

  defp entry(socket, uuid),
    do: Enum.find(socket.assigns.owned ++ socket.assigns.shared, &(&1.library.uuid == uuid))

  defp reply(socket, kind, text),
    do: {:noreply, socket |> assign(:message, {kind, text}) |> load()}

  @impl true
  def handle_event("create", %{"library" => %{"name" => name}}, socket) do
    case Libraries.create_user_library(socket.assigns.scope, %{"name" => name}) do
      {:ok, library} ->
        reply(socket, :success, gettext("Library “%{name}” created", name: library.name))

      {:error, :limit_reached} ->
        reply(socket, :error, gettext("You have reached the number of libraries you may own"))

      {:error, :not_allowed} ->
        reply(socket, :error, gettext("You may not create libraries"))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))
    end
  end

  def handle_event("rename", %{"uuid" => uuid, "name" => name}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.rename_user_library(socket.assigns.scope, library, name) do
      reply(socket, :success, gettext("Library renamed"))
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("You may not rename this library"))
    end
  end

  def handle_event("make_default", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.set_default_library(socket.assigns.scope, library) do
      reply(socket, :success, gettext("Default library changed"))
    else
      _ -> reply(socket, :error, gettext("You may not change this library"))
    end
  end

  def handle_event("trash", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.trash_library(socket.assigns.scope, library) do
      socket =
        if socket.assigns.open_members == uuid,
          do: assign(socket, :open_members, nil),
          else: socket

      reply(socket, :success, gettext("Library moved to the trash"))
    else
      _ -> reply(socket, :error, gettext("You may not trash this library"))
    end
  end

  def handle_event("toggle_members", %{"uuid" => uuid}, socket) do
    open = if socket.assigns.open_members == uuid, do: nil, else: uuid
    {:noreply, socket |> assign(:open_members, open) |> load()}
  end

  def handle_event(
        "add_member",
        %{"uuid" => uuid, "member" => %{"email" => email, "role" => role}},
        socket
      ) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.add_member(socket.assigns.scope, library, email, role) do
      reply(socket, :success, gettext("Member added"))
    else
      {:error, :no_such_user} ->
        reply(socket, :error, gettext("No user has that email"))

      {:error, :owner} ->
        reply(socket, :error, gettext("The owner is always in the library"))

      {:error, %Ecto.Changeset{} = changeset} ->
        reply(socket, :error, changeset_message(changeset))

      _ ->
        reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("member_role", %{"uuid" => uuid, "user" => user_uuid, "role" => role}, socket) do
    with %{library: library} <- entry(socket, uuid),
         {:ok, _} <- Libraries.update_member_role(socket.assigns.scope, library, user_uuid, role) do
      reply(socket, :success, gettext("Role changed"))
    else
      _ -> reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("remove_member", %{"uuid" => uuid, "user" => user_uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         :ok <- Libraries.remove_member(socket.assigns.scope, library, user_uuid) do
      reply(socket, :success, gettext("Member removed"))
    else
      _ -> reply(socket, :error, gettext("You may not manage this library's members"))
    end
  end

  def handle_event("leave", %{"uuid" => uuid}, socket) do
    with %{library: library} <- entry(socket, uuid),
         :ok <-
           Libraries.remove_member(
             socket.assigns.scope,
             library,
             Scope.user_uuid(socket.assigns.scope)
           ) do
      reply(socket, :success, gettext("You left “%{name}”", name: library.name))
    else
      _ -> reply(socket, :error, gettext("Could not leave the library"))
    end
  end

  defp changeset_message(%Ecto.Changeset{errors: errors}) do
    case errors[:name] do
      {message, opts} -> gettext("Name %{error}", error: translate_error({message, opts}))
      nil -> gettext("The library could not be saved")
    end
  end

  @doc false
  def role_label("manager"), do: gettext("Manager")
  def role_label("contributor"), do: gettext("Contributor")
  def role_label("viewer"), do: gettext("Viewer")
  def role_label(role) when is_atom(role), do: role |> to_string() |> role_label()
  def role_label(_role), do: ""

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :roles, LibraryMember.roles())

    ~H"""
    <div id={@id} class="flex flex-col gap-6">
      <div
        :if={@message}
        class={[
          "alert",
          elem(@message, 0) == :success && "alert-success",
          elem(@message, 0) == :error && "alert-error"
        ]}
      >
        {elem(@message, 1)}
      </div>

      <div class="flex items-center justify-between gap-3">
        <div>
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-rectangle-stack" class="w-5 h-5 text-primary" /> {gettext(
              "My libraries"
            )}
          </h2>
          <p class="text-sm text-base-content/60">
            {gettext(
              "Libraries keep your files apart from the site's media. Only you and the members you add can see them."
            )}
          </p>
        </div>
        <.pk_link navigate="/admin/libraries" class="btn btn-sm btn-outline">
          {gettext("Open libraries")}
        </.pk_link>
      </div>

      <form
        :if={@can_create}
        id={"#{@id}-create"}
        phx-submit="create"
        phx-target={@myself}
        class="flex flex-wrap items-end gap-2"
      >
        <label class="form-control grow">
          <span class="label-text text-sm">{gettext("New library")}</span>
          <input
            type="text"
            name="library[name]"
            required
            maxlength="255"
            placeholder={gettext("Name")}
            class="input input-sm input-bordered w-full"
          />
        </label>
        <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
        <span class="text-xs text-base-content/60 w-full">
          {gettext("%{count} of %{limit} libraries", count: length(@owned), limit: @limit)}
        </span>
      </form>

      <div :if={@owned == [] and @shared == []} class="text-sm text-base-content/60">
        {gettext("You have no libraries yet.")}
      </div>

      <div
        :for={%{library: library} <- @owned}
        id={"library-row-#{library.uuid}"}
        class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
      >
        <div class="flex flex-wrap items-center gap-2">
          <form
            id={"#{@id}-rename-#{library.uuid}"}
            phx-submit="rename"
            phx-target={@myself}
            class="flex items-center gap-2 grow"
          >
            <input type="hidden" name="uuid" value={library.uuid} />
            <input
              type="text"
              name="name"
              value={library.name}
              required
              maxlength="255"
              aria-label={gettext("Name")}
              class="input input-sm input-bordered grow"
            />
            <button type="submit" class="btn btn-sm btn-ghost">{gettext("Rename")}</button>
          </form>
          <span :if={library.is_default} class="badge badge-primary badge-sm">{gettext("Default")}</span>
          <button
            :if={not library.is_default}
            type="button"
            phx-click="make_default"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            {gettext("Make default")}
          </button>
          <button
            type="button"
            phx-click="toggle_members"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            class="btn btn-sm btn-ghost"
          >
            <.icon name="hero-users" class="w-4 h-4" /> {gettext("Members")}
          </button>
          <button
            type="button"
            phx-click="trash"
            phx-value-uuid={library.uuid}
            phx-target={@myself}
            data-confirm={
              gettext(
                "Move “%{name}” to the trash? Its files are deleted for good after the trash period, and its members lose it now.",
                name: library.name
              )
            }
            class="btn btn-sm btn-ghost text-error"
          >
            <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Trash")}
          </button>
        </div>
        <.members_panel
          :if={@open_members == library.uuid}
          id={@id}
          library={library}
          members={@members}
          roles={@roles}
          myself={@myself}
        />
      </div>

      <div :if={@shared != []} class="flex flex-col gap-2">
        <h3 class="font-semibold">{gettext("Shared with me")}</h3>
        <div
          :for={%{library: library, role: role} <- @shared}
          id={"library-row-#{library.uuid}"}
          class="rounded-lg border border-base-300 p-3 flex flex-col gap-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium grow">{library.name}</span>
            <span class="badge badge-ghost badge-sm">{role_label(role)}</span>
            <button
              :if={library.uuid in @managed_uuids}
              type="button"
              phx-click="toggle_members"
              phx-value-uuid={library.uuid}
              phx-target={@myself}
              class="btn btn-sm btn-ghost"
            >
              <.icon name="hero-users" class="w-4 h-4" /> {gettext("Members")}
            </button>
            <button
              type="button"
              phx-click="leave"
              phx-value-uuid={library.uuid}
              phx-target={@myself}
              data-confirm={gettext("Leave “%{name}”?", name: library.name)}
              class="btn btn-sm btn-ghost"
            >
              {gettext("Leave")}
            </button>
          </div>
          <.members_panel
            :if={@open_members == library.uuid}
            id={@id}
            library={library}
            members={@members}
            roles={@roles}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :library, :map, required: true
  attr :members, :list, required: true
  attr :roles, :list, required: true
  attr :myself, :any, required: true

  defp members_panel(assigns) do
    ~H"""
    <div
      id={"#{@id}-members-#{@library.uuid}"}
      class="flex flex-col gap-2 border-t border-base-300 pt-3"
    >
      <div :if={@members == []} class="text-sm text-base-content/60">
        {gettext("No members yet: only the owner can see this library.")}
      </div>
      <div :for={member <- @members} class="flex flex-wrap items-center gap-2">
        <span class="grow truncate text-sm">{member.user.email}</span>
        <form
          id={"#{@id}-role-#{@library.uuid}-#{member.user_uuid}"}
          phx-change="member_role"
          phx-target={@myself}
        >
          <input type="hidden" name="uuid" value={@library.uuid} />
          <input type="hidden" name="user" value={member.user_uuid} />
          <select name="role" class="select select-sm" aria-label={gettext("Role")}>
            <option :for={role <- @roles} value={role} selected={role == member.role}>
              {role_label(role)}
            </option>
          </select>
        </form>
        <button
          type="button"
          phx-click="remove_member"
          phx-value-uuid={@library.uuid}
          phx-value-user={member.user_uuid}
          phx-target={@myself}
          class="btn btn-sm btn-ghost"
          aria-label={gettext("Remove")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      <form
        id={"#{@id}-add-member-#{@library.uuid}"}
        phx-submit="add_member"
        phx-target={@myself}
        class="flex flex-wrap items-center gap-2"
      >
        <input type="hidden" name="uuid" value={@library.uuid} />
        <input
          type="email"
          name="member[email]"
          required
          placeholder={gettext("Email")}
          aria-label={gettext("Email")}
          class="input input-sm input-bordered grow"
        />
        <select name="member[role]" class="select select-sm" aria-label={gettext("Role")}>
          <option :for={role <- @roles} value={role} selected={role == "viewer"}>
            {role_label(role)}
          </option>
        </select>
        <button type="submit" class="btn btn-sm">{gettext("Add")}</button>
      </form>
    </div>
    """
  end
end
