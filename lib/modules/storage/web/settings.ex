defmodule PhoenixKitWeb.Live.Modules.Storage.Settings do
  @moduledoc """
  Storage settings management LiveView for PhoenixKit.

  Provides configuration interface for the distributed file storage system.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Activity
  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.ObjectStorageServices, as: Services
  alias PhoenixKit.Jobs.Events
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.Endpoint
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.System.Dependencies
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Live.Settings.UrlTabs

  @sync_refresh_interval 30_000

  def mount(_params, _session, socket) do
    # Get current path for navigation
    current_path = get_current_path(socket, %{})

    # Get project title from settings
    project_title = Settings.get_project_title()

    # Load buckets
    buckets = Storage.list_buckets()

    # Load file counts per bucket (unique files, not instances)
    bucket_file_counts = get_bucket_file_counts(buckets)

    # Load storage settings from database (using basic function to avoid cache issues)
    max_upload_size_mb = Settings.get_setting("storage_max_upload_size_mb", "500")

    # What the missing-tools notice needs: whether the Default variant set makes
    # tiles. Redundancy, sizes and tiles are edited on the Storage profiles tab
    # and the variant sets page, not here.
    tile_generation_enabled = Storage.tile_generation_enabled?()

    annotated_thumbnails_enabled =
      Settings.get_setting("storage_annotated_thumbnails_enabled", "false")

    image_edit_mode = ImageEditing.mode()

    # Store form values for batch updates
    form_annotated_thumbnails_enabled = annotated_thumbnails_enabled == "true"
    current_max_upload_size_mb = String.to_integer(max_upload_size_mb)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, gettext("Media"))
      |> assign(:project_title, project_title)
      |> assign(:buckets, buckets)
      |> assign(:bucket_connections, bucket_connections())
      |> assign(:bucket_file_counts, bucket_file_counts)
      |> assign(:tile_generation_enabled, tile_generation_enabled)
      |> assign(:annotated_thumbnails_enabled, annotated_thumbnails_enabled == "true")
      |> assign(:form_annotated_thumbnails_enabled, form_annotated_thumbnails_enabled)
      |> assign(:max_upload_size_mb, current_max_upload_size_mb)
      |> assign(:form_max_upload_size_mb, current_max_upload_size_mb)
      |> assign(:image_edit_mode, image_edit_mode)
      |> assign(:form_image_edit_mode, image_edit_mode)
      |> assign(:external_tools, Dependencies.external_tools())

    # A library's reconcile run moving updates the Libraries tab's sync column.
    if connected?(socket) do
      Events.subscribe()
      PubSubManager.subscribe(Activity.pubsub_topic())
      Process.send_after(self(), :refresh_library_sync, @sync_refresh_interval)
    end

    {:ok, socket}
  end

  # The tab lives in the URL (`?tab=libraries`); see `UrlTabs`.
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
  end

  defp tabs do
    [
      %{id: "buckets", label: gettext("Buckets"), icon: "hero-inbox-stack"},
      %{id: "profiles", label: gettext("Storage profiles"), icon: "hero-server-stack"},
      %{id: "libraries", label: gettext("Libraries"), icon: "hero-rectangle-stack"},
      %{id: "configuration", label: gettext("Configuration"), icon: "hero-cog-6-tooth"},
      %{id: "tools", label: gettext("Tools"), icon: "hero-wrench-screwdriver"},
      %{id: "history", label: gettext("History"), icon: "hero-clock"},
      %{
        id: "external_libraries",
        label: gettext("External libraries"),
        icon: "hero-command-line"
      }
    ]
  end

  def handle_event("recheck_external_tools", _params, socket) do
    Dependencies.clear_cache()
    {:noreply, assign(socket, :external_tools, Dependencies.external_tools())}
  end

  def handle_event("toggle_form_annotated_thumbnails", _params, socket) do
    new_value = not socket.assigns.form_annotated_thumbnails_enabled
    {:noreply, assign(socket, :form_annotated_thumbnails_enabled, new_value)}
  end

  def handle_event("update_storage_form", params, socket) do
    form_max_upload_size_mb =
      case params["form_max_upload_size_mb"] do
        nil ->
          socket.assigns.form_max_upload_size_mb

        val when is_integer(val) ->
          max(val, 1)

        val when is_binary(val) ->
          max(parse_integer(val, socket.assigns.form_max_upload_size_mb), 1)

        _ ->
          socket.assigns.form_max_upload_size_mb
      end

    form_image_edit_mode =
      if params["form_image_edit_mode"] in ImageEditing.modes(),
        do: params["form_image_edit_mode"],
        else: socket.assigns.form_image_edit_mode

    socket =
      socket
      |> assign(:form_max_upload_size_mb, form_max_upload_size_mb)
      |> assign(:form_image_edit_mode, form_image_edit_mode)

    {:noreply, socket}
  end

  def handle_event("apply_storage_settings", _params, socket) do
    Settings.update_setting(
      "storage_annotated_thumbnails_enabled",
      if(socket.assigns.form_annotated_thumbnails_enabled, do: "true", else: "false")
    )

    Settings.update_setting(
      "storage_max_upload_size_mb",
      to_string(socket.assigns.form_max_upload_size_mb)
    )

    Settings.update_setting(ImageEditing.mode_setting(), socket.assigns.form_image_edit_mode)

    # Read back what was saved, so the form shows what is stored
    saved_annotated_thumbnails =
      Settings.get_setting("storage_annotated_thumbnails_enabled", "false")

    saved_max_upload = Settings.get_setting("storage_max_upload_size_mb", "500")

    socket =
      socket
      |> assign(:annotated_thumbnails_enabled, saved_annotated_thumbnails == "true")
      |> assign(:form_annotated_thumbnails_enabled, saved_annotated_thumbnails == "true")
      |> assign(:max_upload_size_mb, String.to_integer(saved_max_upload))
      |> assign(:form_max_upload_size_mb, String.to_integer(saved_max_upload))
      |> assign(:image_edit_mode, ImageEditing.mode())
      |> assign(:form_image_edit_mode, ImageEditing.mode())
      |> put_flash(:info, gettext("Storage settings updated successfully"))

    {:noreply, socket}
  end

  def handle_event("toggle_bucket", %{"id" => bucket_uuid}, socket) do
    case Storage.get_site_bucket(bucket_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Bucket not found"))}

      bucket ->
        new_enabled = !bucket.enabled

        case Storage.update_bucket(bucket, %{enabled: new_enabled}, Actor.opts(socket)) do
          {:ok, _bucket} ->
            message =
              if new_enabled,
                do: gettext("Bucket enabled successfully"),
                else: gettext("Bucket disabled successfully")

            socket = reload_settings_data(socket)
            {:noreply, put_flash(socket, :info, message)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to update bucket"))}
        end
    end
  end

  # Moves every bucket that still carries its own keys into Integrations.
  # Creating the connections needs the integrations key, so it is checked here
  # too: the button is only hidden from a role without it.
  def handle_event("move_all_credentials", _params, socket) do
    if Scope.has_module_access?(socket.assigns[:phoenix_kit_current_scope], "integrations_system") do
      results = BucketCredentials.move_all_to_integrations(actor_uuid: Actor.uuid(socket))
      failed = Enum.count(results, &match?({_bucket, {:error, _reason}}, &1))
      moved = length(results) - failed

      socket = reload_settings_data(socket)

      socket =
        if failed == 0,
          do:
            put_flash(
              socket,
              :info,
              ngettext(
                "Moved the keys of %{count} bucket into an integration.",
                "Moved the keys of %{count} buckets into an integration.",
                moved
              )
            ),
          else:
            put_flash(
              socket,
              :error,
              gettext(
                "Moved %{moved} bucket(s); %{failed} could not be moved and were left as they were.",
                moved: moved,
                failed: failed
              )
            )

      {:noreply, socket}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Moving keys creates integrations, which needs access to Integrations.")
       )}
    end
  end

  def handle_event("delete_bucket", %{"id" => bucket_uuid}, socket) do
    case bucket_uuid |> Storage.get_site_bucket() |> delete_site_bucket(Actor.opts(socket)) do
      {:ok, _bucket} ->
        # Reload buckets and recalculate max redundancy
        buckets = Storage.list_buckets()
        active_buckets_count = Enum.count(buckets, & &1.enabled)
        max_redundancy = max(1, active_buckets_count)

        socket =
          socket
          |> assign(:buckets, buckets)
          |> assign(:bucket_connections, bucket_connections())
          |> assign(:active_buckets_count, active_buckets_count)
          |> assign(:max_redundancy, max_redundancy)
          |> put_flash(:info, gettext("Bucket deleted successfully"))

        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Bucket not found"))}

      {:error, changeset} ->
        message =
          if Keyword.has_key?(changeset.errors, :file_locations),
            do:
              gettext(
                "This bucket still holds files, so it cannot be deleted. Disable it to stop storing new files there."
              ),
            else: gettext("Failed to delete bucket")

        socket = put_flash(socket, :error, message)
        {:noreply, socket}
    end
  end

  def handle_event("repair_storage_module", _params, socket) do
    case Storage.repair_storage_module() do
      {:ok, repairs} ->
        repair_summary = format_repairs(repairs)

        socket =
          socket
          |> reload_settings_data()
          |> put_flash(
            :info,
            gettext("Storage module repaired: %{summary}", summary: repair_summary)
          )

        {:noreply, socket}

      {:error, reason} ->
        socket =
          put_flash(
            socket,
            :error,
            gettext("Failed to repair: %{reason}", reason: inspect(reason))
          )

        {:noreply, socket}
    end
  end

  # The Libraries and Storage profiles tabs' messages.
  def handle_info({component, {:flash, kind, message}}, socket)
      when component in [
             PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent,
             PhoenixKitWeb.Live.Modules.Storage.ProfilesComponent
           ] do
    {:noreply, put_flash(socket, kind, message)}
  end

  def handle_info({:job_run, _action, %{kind: "storage.reconcile"}}, socket) do
    send_update(PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent,
      id: "media-libraries",
      reload_sync: true
    )

    {:noreply, socket}
  end

  def handle_info({:job_run, _action, _run}, socket), do: {:noreply, socket}

  # A storage entry reached the Activity log: the History tab shows it, if it is open.
  def handle_info({:activity_logged, %{module: "storage"}}, socket) do
    if socket.assigns.active_tab == "history" do
      send_update(PhoenixKitWeb.Live.Modules.Storage.HistoryComponent,
        id: "media-history",
        reload: true
      )
    end

    {:noreply, socket}
  end

  def handle_info({:activity_logged, _entry}, socket), do: {:noreply, socket}

  # Eligibility changes with time, and a settings change need not create a run
  # (e.g. every stale file is waiting for an edit or retry). PubSub alone cannot
  # keep those derived states current.
  def handle_info(:refresh_library_sync, socket) do
    Process.send_after(self(), :refresh_library_sync, @sync_refresh_interval)

    if socket.assigns.active_tab == "libraries" do
      send_update(PhoenixKitWeb.Live.Modules.Storage.LibrariesComponent,
        id: "media-libraries",
        reload_sync: true
      )
    end

    {:noreply, socket}
  end

  defp delete_site_bucket(nil, _opts), do: {:error, :not_found}
  defp delete_site_bucket(bucket, opts), do: Storage.delete_bucket(bucket, opts)

  defp legacy_bucket_count(buckets), do: Enum.count(buckets, &BucketCredentials.legacy?/1)

  defp can_manage_integrations?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "integrations_system")

  defp get_current_path(_socket, _session) do
    # For Storage settings page
    Routes.path("/admin/settings/media")
  end

  # The Object Storage connections a bucket may use, reduced to a name and the
  # service each is for — what the list shows next to a cloud bucket. Nothing
  # secret is kept: `list_connections/1` returns decrypted data, only the
  # service is taken from it.
  defp bucket_connections do
    "object_storage"
    |> Integrations.list_connections()
    |> Map.new(fn %{uuid: uuid, name: name, data: data} ->
      {uuid, %{name: name, service: Services.current(data)}}
    end)
  rescue
    _ -> %{}
  end

  defp bucket_type(%{provider: "local"}), do: gettext("Local")
  defp bucket_type(_bucket), do: gettext("Cloud")

  # The service a cloud bucket is on: the one its integration is for, else what
  # the provider says (a bucket that carries its own keys has no integration).
  defp bucket_service(%{provider: "local"}, _connections), do: nil

  defp bucket_service(bucket, connections) do
    case connections[bucket.integration_uuid] do
      %{service: service} when is_binary(service) -> Services.name(service)
      _ -> provider_name(bucket.provider)
    end
  end

  defp provider_name("s3"), do: "AWS S3"
  defp provider_name("b2"), do: "Backblaze B2"
  defp provider_name("r2"), do: "Cloudflare R2"
  defp provider_name("tigris"), do: "Tigris"
  defp provider_name(provider), do: String.upcase(to_string(provider))

  # Where the files go, in words: a path for a local bucket, otherwise the
  # bucket's name on the service and the host it is reached at (or its region).
  defp bucket_location(%{provider: "local"} = bucket),
    do: bucket.endpoint || gettext("No path configured")

  defp bucket_location(bucket) do
    host =
      case Endpoint.parse(bucket.endpoint) do
        %{host: host} -> host
        _ -> bucket.region
      end

    [bucket.bucket_name || gettext("No bucket name"), host]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # Get count of unique files stored on each bucket
  defp get_bucket_file_counts(buckets) do
    repo = PhoenixKit.Config.get_repo()

    Enum.reduce(buckets, %{}, fn bucket, acc ->
      # Count distinct files that have at least one instance located on this bucket
      # We count files, not instances or locations
      count =
        repo.one(
          from f in Storage.File,
            join: fi in Storage.FileInstance,
            on: fi.file_uuid == f.uuid,
            join: fl in Storage.FileLocation,
            on: fl.file_instance_uuid == fi.uuid,
            where: fl.bucket_uuid == ^bucket.uuid and fl.status == "active",
            select: count(f.uuid, :distinct)
        )

      Map.put(acc, bucket.uuid, count || 0)
    end)
  rescue
    _ -> %{}
  end

  defp format_repairs(repairs) do
    Enum.map_join(repairs, ", ", fn
      {:bucket_created, name} ->
        gettext("created bucket '%{name}'", name: name)

      {:buckets_added_to_default, count} ->
        ngettext(
          "added %{count} bucket to the Default profile",
          "added %{count} buckets to the Default profile",
          count
        )

      {:copies_lowered, count} ->
        ngettext(
          "lowered the Default profile to %{count} copy",
          "lowered the Default profile to %{count} copies",
          count
        )

      :default_bucket_cleared ->
        gettext("cleared the missing default bucket")

      {:dimensions_reset, count} ->
        gettext("reset %{count} dimensions", count: count)
    end)
  end

  attr :tools, :list, required: true

  defp missing_tools_banner(assigns) do
    ~H"""
    <div :if={@tools != []} role="alert" class="alert alert-warning alert-soft py-2 mb-6">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
      <span class="text-sm">
        {gettext("Not found on this server: %{tools}.", tools: Enum.map_join(@tools, ", ", & &1.name))}
      </span>
      <.link
        patch={Routes.path("/admin/settings/media?tab=external_libraries")}
        class="btn btn-ghost btn-xs"
      >
        {gettext("Details")}
      </.link>
    </div>
    """
  end

  # The missing tools worth a banner: the tile maker only matters while
  # tiles are on.
  defp missing_tools(tools, tile_generation_enabled?) do
    Enum.filter(tools, fn tool ->
      match?({:error, _}, tool.status) and (tool.id != :magick or tile_generation_enabled?)
    end)
  end

  defp tool_purpose(:images), do: gettext("Image variants, resizing and conversion")
  defp tool_purpose(:tiles), do: gettext("Zoomable tiles for large images")
  defp tool_purpose(:video), do: gettext("Video variants and thumbnails")
  defp tool_purpose(:video_metadata), do: gettext("Video dimensions, duration and capture date")
  defp tool_purpose(:pdf_previews), do: gettext("PDF preview images")
  defp tool_purpose(:pdf_metadata), do: gettext("PDF page count and metadata")

  defp reload_settings_data(socket) do
    # Reload buckets
    buckets = Storage.list_buckets()
    bucket_file_counts = get_bucket_file_counts(buckets)

    socket
    |> assign(:buckets, buckets)
    |> assign(:bucket_connections, bucket_connections())
    |> assign(:bucket_file_counts, bucket_file_counts)
  end

  defp parse_integer(val, fallback) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> fallback
    end
  end
end
