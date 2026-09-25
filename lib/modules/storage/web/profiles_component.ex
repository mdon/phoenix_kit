defmodule PhoenixKitWeb.Live.Modules.Storage.ProfilesComponent do
  @moduledoc """
  The Storage profiles tab of Settings → Media (V205): where each library's
  bytes live.

  A profile lists buckets and says, for each, its role (`primary` is
  written and served, `replica` is served when no primary has the copy,
  `backup` is written but never served), what it stores (everything,
  originals only or derived files only), a fixed write priority (empty is
  the shuffled pool), a serve order and a status (`read_only` keeps
  serving and gets no new files, `draining` has its files moved to the
  profile's other buckets). The profile also says how many copies an
  original and a derived file get, and how many copies of an original an
  upload needs to succeed.

  Every library without its own profile uses the Default, which every
  bucket joins when it is created. Any change bumps the profile's revision,
  and the reconciler moves its files by itself (the Health page shows what
  is left). A library picks its profile on the Libraries tab.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{ProfileBucket, Profiles, StorageProfile}

  import PhoenixKitWeb.Components.Core.Input, only: [translate_error: 1]

  @impl true
  def mount(socket) do
    {:ok, assign(socket, profiles: nil, creating: false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, if(socket.assigns.profiles, do: socket, else: load(socket))}
  end

  defp load(socket) do
    profiles = Profiles.list_profiles()

    socket
    |> assign(:profiles, profiles)
    |> assign(:buckets, Storage.list_buckets())
    |> assign(:in_use, Map.new(profiles, &{&1.uuid, Profiles.libraries_using(&1.uuid)}))
  end

  @impl true
  def handle_event("new", _params, socket), do: {:noreply, assign(socket, :creating, true)}
  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, :creating, false)}

  def handle_event("create", %{"profile" => params}, socket) do
    case Profiles.create_profile(params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:creating, false)
         |> load()
         |> flash(:info, gettext("Storage profile \"%{name}\" created", name: profile.name))}

      {:error, changeset} ->
        {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("save_profile", %{"uuid" => uuid, "profile" => params}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         {:ok, _} <- Profiles.update_profile(profile, params) do
      {:noreply, socket |> load() |> flash(:info, gettext("Storage profile saved"))}
    else
      nil -> {:noreply, socket}
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("delete_profile", %{"uuid" => uuid}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         {:ok, _} <- Profiles.delete_profile(profile) do
      {:noreply, socket |> load() |> flash(:info, gettext("Storage profile deleted"))}
    else
      nil ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         flash(
           socket,
           :error,
           gettext("The Default profile, and a profile a library uses, cannot be deleted.")
         )}
    end
  end

  def handle_event("add_bucket", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         true <- Enum.any?(socket.assigns.buckets, &(to_string(&1.uuid) == bucket_uuid)),
         {:ok, _} <-
           Profiles.put_bucket(profile, bucket_uuid, %{serve_order: next_serve_order(profile)}) do
      {:noreply, socket |> load() |> flash(:info, gettext("Bucket added to the profile"))}
    else
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("save_row", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid} = params, socket) do
    attrs = Map.get(params, "row", %{})

    with %StorageProfile{} = profile <- find(socket, uuid),
         true <- Enum.any?(profile.buckets, &(to_string(&1.bucket_uuid) == bucket_uuid)),
         {:ok, _} <- Profiles.put_bucket(profile, bucket_uuid, attrs) do
      {:noreply, load(socket)}
    else
      {:error, changeset} ->
        {:noreply, socket |> load() |> flash(:error, error_message(changeset))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_bucket", %{"uuid" => uuid, "bucket_uuid" => bucket_uuid}, socket) do
    case find(socket, uuid) do
      %StorageProfile{} = profile ->
        :ok = Profiles.remove_bucket(profile, bucket_uuid)

        {:noreply,
         socket
         |> load()
         |> flash(
           :info,
           gettext(
             "Bucket taken out of the profile. Its files are copied to the profile's other buckets, then removed from it."
           )
         )}

      nil ->
        {:noreply, socket}
    end
  end

  # Only a profile this tab listed: the uuid arrives from the client.
  defp find(socket, uuid), do: Enum.find(socket.assigns.profiles, &(to_string(&1.uuid) == uuid))

  defp next_serve_order(profile),
    do: (profile.buckets |> Enum.map(& &1.serve_order) |> Enum.max(fn -> 0 end)) + 1

  defp flash(socket, kind, message) do
    send(self(), {__MODULE__, {:flash, kind, message}})
    socket
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{Phoenix.Naming.humanize(field)}: #{Enum.join(messages, ", ")}"
    end)
  end

  defp role_label("primary"), do: gettext("Primary")
  defp role_label("replica"), do: gettext("Replica")
  defp role_label("backup"), do: gettext("Backup")

  defp stores_label("all"), do: gettext("Everything")
  defp stores_label("originals"), do: gettext("Originals")
  defp stores_label("derived"), do: gettext("Sizes and tiles")

  defp status_label("active"), do: gettext("Active")
  defp status_label("read_only"), do: gettext("Read-only")
  defp status_label("draining"), do: gettext("Draining")

  defp not_in(profile, buckets) do
    used = MapSet.new(profile.buckets, &to_string(&1.bucket_uuid))
    Enum.reject(buckets, &MapSet.member?(used, to_string(&1.uuid)))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div class="card bg-base-100 shadow-xl mb-6 mt-6">
        <div class="card-body">
          <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h2 class="card-title text-lg">
              <.icon name="hero-server-stack" class="w-6 h-6 mr-2" /> {gettext("Storage profiles")}
            </h2>
            <button
              :if={not @creating}
              type="button"
              class="btn btn-primary"
              phx-click="new"
              phx-target={@myself}
            >
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("New profile")}
            </button>
          </div>
          <p class="text-sm text-base-content/70">
            {gettext(
              "A storage profile says where a library's files are kept: which buckets, how many copies, and which copy is served. Every library without its own profile uses the Default. After a change, files are moved in the background; the Health page shows what is left."
            )}
          </p>

          <form
            :if={@creating}
            id={"#{@id}-new"}
            phx-submit="create"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mt-4"
          >
            <input
              type="text"
              name="profile[name]"
              id={"#{@id}-new-name"}
              class="input input-sm w-64"
              placeholder={gettext("Profile name")}
              maxlength="255"
              required
              autofocus
            />
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Create")}</button>
            <button type="button" class="btn btn-sm btn-ghost" phx-click="cancel" phx-target={@myself}>
              {gettext("Cancel")}
            </button>
          </form>
        </div>
      </div>

      <div
        :for={profile <- @profiles}
        id={"#{@id}-#{profile.uuid}"}
        class="card bg-base-100 shadow-xl mb-6"
      >
        <div class="card-body">
          <form
            id={"#{@id}-form-#{profile.uuid}"}
            phx-submit="save_profile"
            phx-target={@myself}
            class="flex flex-wrap items-end gap-4"
          >
            <input type="hidden" name="uuid" value={profile.uuid} />
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Name")}</span>
              <input
                type="text"
                name="profile[name]"
                value={profile.name}
                maxlength="255"
                required
                class="input input-sm input-bordered w-56"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Copies of an original")}</span>
              <input
                type="number"
                name="profile[copies_originals]"
                min="1"
                max="5"
                value={profile.copies_originals}
                class="input input-sm input-bordered w-24"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Copies of a size or tile")}</span>
              <input
                type="number"
                name="profile[copies_variants]"
                min="1"
                max="5"
                value={profile.copies_variants}
                class="input input-sm input-bordered w-24"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">{gettext("Copies an upload needs")}</span>
              <input
                type="number"
                name="profile[min_copies_on_write]"
                min="1"
                max={profile.copies_originals}
                value={profile.min_copies_on_write}
                class="input input-sm input-bordered w-24"
              />
            </label>
            <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
            <span :if={profile.is_default} class="badge badge-ghost">{gettext("Default")}</span>
            <span class="text-sm text-base-content/60">
              {ngettext(
                "Used by %{count} library.",
                "Used by %{count} libraries.",
                Map.get(@in_use, profile.uuid, 0)
              )}
            </span>
            <button
              :if={not profile.is_default}
              type="button"
              class="btn btn-sm btn-ghost text-error ml-auto"
              disabled={Map.get(@in_use, profile.uuid, 0) > 0}
              phx-click="delete_profile"
              phx-value-uuid={profile.uuid}
              phx-target={@myself}
              data-confirm={gettext("Delete this storage profile?")}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> {gettext("Delete")}
            </button>
          </form>

          <div class="overflow-x-auto mt-4">
            <table class="table table-zebra">
              <thead>
                <tr>
                  <th>{gettext("Bucket")}</th>
                  <th>{gettext("Role")}</th>
                  <th>{gettext("Stores")}</th>
                  <th>{gettext("Write priority")}</th>
                  <th>{gettext("Serve order")}</th>
                  <th>{gettext("Status")}</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :if={profile.buckets == []}>
                  <td colspan="7" class="text-sm text-base-content/60">
                    {gettext("No buckets yet: uploads to a library on this profile fail.")}
                  </td>
                </tr>
                <tr :for={row <- profile.buckets} id={"#{@id}-#{profile.uuid}-#{row.bucket_uuid}"}>
                  <td>
                    <span class="font-medium">{row.bucket.name}</span>
                    <span class="badge badge-ghost badge-sm ml-1">{row.bucket.provider}</span>
                    <span :if={not row.bucket.enabled} class="badge badge-error badge-sm ml-1">
                      {gettext("Disabled")}
                    </span>
                  </td>
                  <td colspan="5">
                    <form
                      id={"#{@id}-row-#{profile.uuid}-#{row.bucket_uuid}"}
                      phx-change="save_row"
                      phx-target={@myself}
                      class="flex flex-wrap items-center gap-2"
                    >
                      <input type="hidden" name="uuid" value={profile.uuid} />
                      <input type="hidden" name="bucket_uuid" value={row.bucket_uuid} />
                      <select name="row[role]" class="select select-sm select-bordered">
                        <option
                          :for={role <- ProfileBucket.roles()}
                          value={role}
                          selected={row.role == role}
                        >
                          {role_label(role)}
                        </option>
                      </select>
                      <select name="row[stores]" class="select select-sm select-bordered">
                        <option
                          :for={stores <- ProfileBucket.stores()}
                          value={stores}
                          selected={row.stores == stores}
                        >
                          {stores_label(stores)}
                        </option>
                      </select>
                      <input
                        type="number"
                        name="row[write_priority]"
                        min="1"
                        value={row.write_priority}
                        placeholder={gettext("Pool")}
                        phx-debounce="600"
                        class="input input-sm input-bordered w-24"
                      />
                      <input
                        type="number"
                        name="row[serve_order]"
                        min="0"
                        value={row.serve_order}
                        phx-debounce="600"
                        class="input input-sm input-bordered w-20"
                      />
                      <select name="row[status]" class="select select-sm select-bordered">
                        <option
                          :for={status <- ProfileBucket.statuses()}
                          value={status}
                          selected={row.status == status}
                        >
                          {status_label(status)}
                        </option>
                      </select>
                    </form>
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      class="btn btn-xs btn-ghost text-error"
                      phx-click="remove_bucket"
                      phx-value-uuid={profile.uuid}
                      phx-value-bucket_uuid={row.bucket_uuid}
                      phx-target={@myself}
                      data-confirm={
                        gettext(
                          "Take this bucket out of the profile? Its files are copied to the profile's other buckets first, then removed from it."
                        )
                      }
                    >
                      <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Remove")}
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <form
            :if={not_in(profile, @buckets) != []}
            id={"#{@id}-add-#{profile.uuid}"}
            phx-submit="add_bucket"
            phx-target={@myself}
            class="flex flex-wrap items-center gap-2 mt-2"
          >
            <input type="hidden" name="uuid" value={profile.uuid} />
            <select name="bucket_uuid" class="select select-sm select-bordered">
              <option :for={bucket <- not_in(profile, @buckets)} value={bucket.uuid}>
                {bucket.name}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-outline">
              <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add bucket")}
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end
end
