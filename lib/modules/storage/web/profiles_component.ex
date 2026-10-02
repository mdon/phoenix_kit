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

  # The recommended copy count, applied. Only the count `Profiles.copies_advice/1`
  # recommends for the profile as it is now: the number arrives from the client.
  def handle_event("apply_copies", %{"uuid" => uuid, "copies" => copies}, socket) do
    with %StorageProfile{} = profile <- find(socket, uuid),
         %{recommended: recommended} when is_integer(recommended) <-
           Profiles.copies_advice(profile),
         true <- to_string(recommended) == copies,
         {:ok, _} <- Profiles.update_profile(profile, %{"copies_originals" => recommended}) do
      {:noreply, socket |> load() |> flash(:info, gettext("Storage profile saved"))}
    else
      {:error, changeset} -> {:noreply, flash(socket, :error, error_message(changeset))}
      _ -> {:noreply, socket}
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
  defp status_label("read_only"), do: gettext("Read-only (no new files)")
  defp status_label("draining"), do: gettext("Draining (moving files out)")

  # The columns of the bucket rows. The header and every row share it, so each
  # control sits under its own heading.
  defp columns,
    do: "grid grid-cols-[minmax(11rem,2fr)_7rem_10rem_6rem_6rem_13rem_2.5rem] items-center gap-3"

  # One sentence on what the copy counts mean with the buckets the profile has
  # now: the numbers alone read the same with one bucket and with five. The
  # arithmetic is `Profiles.copies_advice/1`'s, which the bucket form shares.
  defp copies_hint(profile) do
    %{writable: buckets, primaries: primaries, copies: copies} = Profiles.copies_advice(profile)

    cond do
      buckets == 0 ->
        {:error, gettext("No bucket can take new files now, so uploads fail.")}

      copies > buckets ->
        {:warning,
         ngettext(
           "Each original should have %{copies} copies, but only %{count} bucket can take new files, so each gets 1.",
           "Each original should have %{copies} copies, but only %{count} buckets can take new files, so each gets %{count}.",
           buckets,
           copies: copies
         )}

      buckets == 1 ->
        {:info, gettext("One bucket takes new files, so every original is stored there.")}

      # One copy goes to the first role that has a bucket: primaries, then
      # replicas, then backups. Replicas and backups get a file only when a write
      # to the primary fails, so they are not part of the spread.
      copies == 1 and primaries == 1 ->
        {:info,
         gettext(
           "Each original is stored on the primary bucket only. The other buckets take over only if a write to it fails, and hold nothing otherwise. Set the copies to 2 to keep every file on a second bucket."
         )}

      copies == 1 and primaries > 1 ->
        {:info,
         gettext(
           "%{count} buckets take new files and each original is stored on 1 of them, picked by upload order, otherwise at random: files are spread across the buckets, not mirrored. Set the copies to 2 to keep every file on 2 buckets.",
           count: primaries
         )}

      true ->
        {:info,
         gettext(
           "Each original is stored on %{copies} of the %{count} buckets that take new files.",
           copies: copies,
           count: buckets
         )}
    end
  end

  defp hint_class(:error), do: "text-error"
  defp hint_class(:warning), do: "text-warning"
  defp hint_class(:info), do: "text-base-content/60"

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
              "A storage profile says where a library's files are kept: which buckets, how many copies of each file, and which copy is served. A library without a profile of its own uses the Default. When the buckets, their roles or the copy counts change, files are copied or moved in the background; the Health page shows what is left."
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
              <span class="label-text text-sm">{gettext("Copies of each original")}</span>
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
              <span class="label-text text-sm">{gettext("Copies of each size and tile")}</span>
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
              <span class="label-text text-sm">{gettext("Copies needed to accept an upload")}</span>
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

          <p
            :if={profile.buckets != []}
            class={["text-sm mt-3", hint_class(elem(copies_hint(profile), 0))]}
          >
            {elem(copies_hint(profile), 1)}
          </p>

          <% advice = Profiles.copies_advice(profile) %>
          <div
            :if={advice.idle != []}
            id={"#{@id}-advice-#{profile.uuid}"}
            class="mt-2 flex flex-wrap items-center gap-3 rounded-box bg-base-200 px-3 py-2 text-sm"
          >
            <span>
              {gettext("Not used at this copy count: %{names}.", names: Enum.join(advice.idle, ", "))}
            </span>
            <button
              :if={advice.recommended}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="apply_copies"
              phx-value-uuid={profile.uuid}
              phx-value-copies={advice.recommended}
              phx-target={@myself}
              data-confirm={
                gettext(
                  "Set Copies of each original to %{count}? Files already stored are copied to the extra bucket in the background; the Health page shows what is left.",
                  count: advice.recommended
                )
              }
            >
              {gettext("Keep every original on %{count} buckets", count: advice.recommended)}
            </button>
          </div>

          <div class="overflow-x-auto mt-4">
            <div class="min-w-[58rem]">
              <div class={[
                columns(),
                "px-2 pb-2 text-xs font-semibold uppercase text-base-content/60"
              ]}>
                <span>{gettext("Bucket")}</span>
                <span
                  class="tooltip tooltip-bottom normal-case text-left"
                  data-tip={
                    gettext(
                      "Primary: written and served. Replica: written when more copies are wanted than there are primaries; served only if no primary has the file. Backup: written, never served."
                    )
                  }
                >
                  {gettext("Role")}
                </span>
                <span>{gettext("Stores")}</span>
                <span
                  class="tooltip tooltip-bottom normal-case text-left"
                  data-tip={
                    gettext(
                      "Lower numbers get new files first. Leave it empty to share them: buckets with no number take turns at random."
                    )
                  }
                >
                  {gettext("Upload order")}
                </span>
                <span
                  class="tooltip tooltip-bottom normal-case text-left"
                  data-tip={
                    gettext(
                      "When a file is on several buckets, the one with the lowest number serves it."
                    )
                  }
                >
                  {gettext("Serve order")}
                </span>
                <span>{gettext("Status")}</span>
                <span></span>
              </div>

              <p
                :if={profile.buckets == []}
                class="border-t border-base-200 py-3 px-2 text-sm text-base-content/60"
              >
                {gettext("No buckets yet: uploads to a library on this profile fail.")}
              </p>

              <form
                :for={row <- profile.buckets}
                id={"#{@id}-row-#{profile.uuid}-#{row.bucket_uuid}"}
                phx-change="save_row"
                phx-target={@myself}
                class={[columns(), "border-t border-base-200 px-2 py-2"]}
              >
                <input type="hidden" name="uuid" value={profile.uuid} />
                <input type="hidden" name="bucket_uuid" value={row.bucket_uuid} />

                <div id={"#{@id}-#{profile.uuid}-#{row.bucket_uuid}"} class="min-w-0">
                  <span class="font-medium break-words">{row.bucket.name}</span>
                  <span class="badge badge-ghost badge-sm ml-1">{row.bucket.provider}</span>
                  <span :if={not row.bucket.enabled} class="badge badge-error badge-sm ml-1">
                    {gettext("Disabled")}
                  </span>
                </div>

                <select name="row[role]" class="select select-sm select-bordered w-full">
                  <option
                    :for={role <- ProfileBucket.roles()}
                    value={role}
                    selected={row.role == role}
                  >
                    {role_label(role)}
                  </option>
                </select>
                <select name="row[stores]" class="select select-sm select-bordered w-full">
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
                  placeholder={gettext("Any")}
                  phx-debounce="600"
                  class="input input-sm input-bordered w-full"
                />
                <input
                  type="number"
                  name="row[serve_order]"
                  min="0"
                  value={row.serve_order}
                  phx-debounce="600"
                  class="input input-sm input-bordered w-full"
                />
                <select name="row[status]" class="select select-sm select-bordered w-full">
                  <option
                    :for={status <- ProfileBucket.statuses()}
                    value={status}
                    selected={row.status == status}
                  >
                    {status_label(status)}
                  </option>
                </select>
                <button
                  type="button"
                  class="btn btn-xs btn-ghost text-error"
                  title={gettext("Remove")}
                  aria-label={gettext("Remove")}
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
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </form>
            </div>
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
