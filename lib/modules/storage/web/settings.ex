defmodule PhoenixKitWeb.Live.Modules.Storage.Settings do
  @moduledoc """
  Storage settings management LiveView for PhoenixKit.

  Provides configuration interface for the distributed file storage system.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.BucketCredentials
  alias PhoenixKit.Modules.Storage.ImageEditing
  alias PhoenixKit.Settings
  alias PhoenixKit.System.Dependencies
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Actor

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
    redundancy_copies = to_string(Storage.redundancy_copies())
    auto_generate_variants = to_string(Storage.get_auto_generate_variants())
    max_upload_size_mb = Settings.get_setting("storage_max_upload_size_mb", "500")
    tile_generation_enabled = to_string(Storage.tile_generation_enabled?())

    annotated_thumbnails_enabled =
      Settings.get_setting("storage_annotated_thumbnails_enabled", "false")

    image_edit_mode = ImageEditing.mode()

    # Calculate maximum redundancy based on available buckets
    active_buckets = Enum.count(buckets, & &1.enabled)
    max_redundancy = if active_buckets > 0, do: active_buckets, else: 1

    # Keep user's current redundancy setting unchanged
    current_redundancy = String.to_integer(redundancy_copies)

    # Store form values for batch updates
    form_redundancy = current_redundancy
    form_auto_generate_variants = auto_generate_variants == "true"
    form_tile_generation_enabled = tile_generation_enabled == "true"
    form_annotated_thumbnails_enabled = annotated_thumbnails_enabled == "true"
    current_max_upload_size_mb = String.to_integer(max_upload_size_mb)

    socket =
      socket
      |> assign(:current_path, current_path)
      |> assign(:page_title, gettext("Media"))
      |> assign(:project_title, project_title)
      |> assign(:buckets, buckets)
      |> assign(:bucket_file_counts, bucket_file_counts)
      |> assign(:redundancy_copies, current_redundancy)
      |> assign(:auto_generate_variants, auto_generate_variants == "true")
      |> assign(:tile_generation_enabled, tile_generation_enabled == "true")
      |> assign(:annotated_thumbnails_enabled, annotated_thumbnails_enabled == "true")
      |> assign(:active_buckets_count, active_buckets)
      |> assign(:max_redundancy, max_redundancy)
      |> assign(:form_redundancy, form_redundancy)
      |> assign(:form_auto_generate_variants, form_auto_generate_variants)
      |> assign(:form_tile_generation_enabled, form_tile_generation_enabled)
      |> assign(:form_annotated_thumbnails_enabled, form_annotated_thumbnails_enabled)
      |> assign(:max_upload_size_mb, current_max_upload_size_mb)
      |> assign(:form_max_upload_size_mb, current_max_upload_size_mb)
      |> assign(:image_edit_mode, image_edit_mode)
      |> assign(:form_image_edit_mode, image_edit_mode)
      |> assign(:external_tools, Dependencies.external_tools())
      |> assign(:active_tab, "buckets")

    {:ok, socket}
  end

  def handle_event("switch_settings_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("recheck_external_tools", _params, socket) do
    Dependencies.clear_cache()
    {:noreply, assign(socket, :external_tools, Dependencies.external_tools())}
  end

  def handle_event("update_redundancy", %{"redundancy_copies" => copies}, socket) do
    requested_copies = String.to_integer(copies)
    max_redundancy = socket.assigns.max_redundancy

    if requested_copies > max_redundancy do
      socket =
        socket
        |> put_flash(
          :error,
          gettext(
            "Cannot set redundancy to %{count} copies. Only %{max} active bucket(s) available.",
            count: requested_copies,
            max: max_redundancy
          )
        )

      {:noreply, socket}
    else
      case Storage.set_redundancy_copies(requested_copies) do
        {:ok, _setting} ->
          # Settings.update_setting already handles cache invalidation
          socket =
            socket
            |> assign(:redundancy_copies, requested_copies)
            |> put_flash(
              :info,
              ngettext(
                "Redundancy settings updated to %{count} copy",
                "Redundancy settings updated to %{count} copies",
                requested_copies
              )
            )

          {:noreply, socket}

        {:error, _changeset} ->
          socket = put_flash(socket, :error, gettext("Failed to update redundancy settings"))
          {:noreply, socket}
      end
    end
  end

  def handle_event("update_form_redundancy", %{"form_redundancy" => copies}, socket) do
    # Handle both string and integer inputs
    form_redundancy =
      cond do
        is_integer(copies) -> copies
        is_binary(copies) -> String.to_integer(copies)
        # fallback
        true -> 1
      end

    socket =
      socket
      |> assign(:form_redundancy, form_redundancy)

    {:noreply, socket}
  end

  def handle_event("update_form_variants", %{"form_auto_generate_variants" => value}, socket) do
    form_auto_generate_variants = value == "true"

    socket =
      socket
      |> assign(:form_auto_generate_variants, form_auto_generate_variants)

    {:noreply, socket}
  end

  def handle_event("toggle_form_tile_generation", _params, socket) do
    new_value = not socket.assigns.form_tile_generation_enabled
    {:noreply, assign(socket, :form_tile_generation_enabled, new_value)}
  end

  def handle_event("toggle_form_annotated_thumbnails", _params, socket) do
    new_value = not socket.assigns.form_annotated_thumbnails_enabled
    {:noreply, assign(socket, :form_annotated_thumbnails_enabled, new_value)}
  end

  def handle_event("toggle_form_variants", _params, socket) do
    new_value = not socket.assigns.form_auto_generate_variants

    socket =
      socket
      |> assign(:form_auto_generate_variants, new_value)

    {:noreply, socket}
  end

  def handle_event("update_storage_form", params, socket) do
    form_redundancy =
      case params["form_redundancy"] do
        nil -> socket.assigns.form_redundancy
        val when is_integer(val) -> val
        val when is_binary(val) -> parse_integer(val, socket.assigns.form_redundancy)
        _ -> socket.assigns.form_redundancy
      end

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
      |> assign(:form_redundancy, form_redundancy)
      |> assign(:form_max_upload_size_mb, form_max_upload_size_mb)
      |> assign(:form_image_edit_mode, form_image_edit_mode)

    {:noreply, socket}
  end

  def handle_event("apply_storage_settings", _params, socket) do
    # Get current form values
    new_redundancy = socket.assigns.form_redundancy
    new_variants = if socket.assigns.form_auto_generate_variants, do: "true", else: "false"

    new_tile_generation =
      if socket.assigns.form_tile_generation_enabled, do: "true", else: "false"

    new_annotated_thumbnails =
      if socket.assigns.form_annotated_thumbnails_enabled, do: "true", else: "false"

    new_max_upload_size_mb = socket.assigns.form_max_upload_size_mb

    # Validate redundancy doesn't exceed available buckets
    max_redundancy = socket.assigns.max_redundancy

    if new_redundancy != socket.assigns.redundancy_copies and new_redundancy > max_redundancy do
      socket =
        socket
        |> put_flash(
          :error,
          gettext(
            "Cannot set redundancy to %{count} copies. Only %{max} active bucket(s) available.",
            count: new_redundancy,
            max: max_redundancy
          )
        )

      {:noreply, socket}
    else
      # Update all settings
      # Only a changed count is saved: saving it rewrites the Default
      # storage profile (and every file of it is checked again).
      redundancy_result =
        if new_redundancy == socket.assigns.redundancy_copies,
          do: {:ok, :unchanged},
          else: Storage.set_redundancy_copies(new_redundancy)

      variants_result = Storage.set_auto_generate_variants(new_variants == "true")

      Storage.set_tile_generation(new_tile_generation == "true")

      Settings.update_setting(
        "storage_annotated_thumbnails_enabled",
        new_annotated_thumbnails
      )

      Settings.update_setting(
        "storage_max_upload_size_mb",
        to_string(new_max_upload_size_mb)
      )

      Settings.update_setting(ImageEditing.mode_setting(), socket.assigns.form_image_edit_mode)

      case {redundancy_result, variants_result} do
        {{:ok, _}, {:ok, _}} ->
          # Verify the settings were saved correctly by reading them back
          saved_redundancy = to_string(Storage.redundancy_copies())
          saved_variants = to_string(Storage.get_auto_generate_variants())
          saved_tile_generation = to_string(Storage.tile_generation_enabled?())

          saved_annotated_thumbnails =
            Settings.get_setting("storage_annotated_thumbnails_enabled", "false")

          saved_max_upload = Settings.get_setting("storage_max_upload_size_mb", "500")

          socket =
            socket
            |> assign(:redundancy_copies, String.to_integer(saved_redundancy))
            |> assign(:auto_generate_variants, saved_variants == "true")
            |> assign(:tile_generation_enabled, saved_tile_generation == "true")
            |> assign(:annotated_thumbnails_enabled, saved_annotated_thumbnails == "true")
            |> assign(:form_redundancy, String.to_integer(saved_redundancy))
            |> assign(:form_auto_generate_variants, saved_variants == "true")
            |> assign(:form_tile_generation_enabled, saved_tile_generation == "true")
            |> assign(:form_annotated_thumbnails_enabled, saved_annotated_thumbnails == "true")
            |> assign(:max_upload_size_mb, String.to_integer(saved_max_upload))
            |> assign(:form_max_upload_size_mb, String.to_integer(saved_max_upload))
            |> assign(:image_edit_mode, ImageEditing.mode())
            |> assign(:form_image_edit_mode, ImageEditing.mode())
            |> put_flash(:info, gettext("Storage settings updated successfully"))

          {:noreply, socket}

        {{:error, _}, {:ok, _}} ->
          socket = put_flash(socket, :error, gettext("Failed to update redundancy settings"))
          {:noreply, socket}

        {{:ok, _}, {:error, _}} ->
          socket = put_flash(socket, :error, gettext("Failed to update variant settings"))
          {:noreply, socket}

        {{:error, _}, {:error, _}} ->
          socket = put_flash(socket, :error, gettext("Failed to update storage settings"))
          {:noreply, socket}
      end
    end
  end

  def handle_event("toggle_variants", _params, socket) do
    new_value = if socket.assigns.auto_generate_variants, do: "false", else: "true"

    case Storage.set_auto_generate_variants(new_value == "true") do
      {:ok, _setting} ->
        # Settings.update_setting already handles cache invalidation
        socket =
          socket
          |> assign(:auto_generate_variants, new_value == "true")
          |> put_flash(
            :info,
            if(new_value == "true",
              do: gettext("Auto-variant generation enabled"),
              else: gettext("Auto-variant generation disabled")
            )
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to update variant settings"))
        {:noreply, socket}
    end
  end

  def handle_event("toggle_bucket", %{"id" => bucket_uuid}, socket) do
    case Storage.get_bucket(bucket_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Bucket not found"))}

      bucket ->
        new_enabled = !bucket.enabled

        case Storage.update_bucket(bucket, %{enabled: new_enabled}) do
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
    bucket = Storage.get_bucket(bucket_uuid)

    case Storage.delete_bucket(bucket) do
      {:ok, _bucket} ->
        # Reload buckets and recalculate max redundancy
        buckets = Storage.list_buckets()
        active_buckets_count = Enum.count(buckets, & &1.enabled)
        max_redundancy = max(1, active_buckets_count)

        socket =
          socket
          |> assign(:buckets, buckets)
          |> assign(:active_buckets_count, active_buckets_count)
          |> assign(:max_redundancy, max_redundancy)
          |> put_flash(:info, gettext("Bucket deleted successfully"))

        {:noreply, socket}

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

  defp legacy_bucket_count(buckets), do: Enum.count(buckets, &BucketCredentials.legacy?/1)

  defp can_manage_integrations?(assigns),
    do: Scope.has_module_access?(assigns[:phoenix_kit_current_scope], "integrations_system")

  defp get_current_path(_socket, _session) do
    # For Storage settings page
    Routes.path("/admin/settings/media")
  end

  # Helper function to get full path for a bucket
  defp get_bucket_full_path(bucket) do
    case bucket.provider do
      "local" ->
        bucket.endpoint || "No path configured"

      provider when provider in ["s3", "b2", "r2", "tigris"] ->
        path_parts = [
          provider <> ":",
          if(bucket.bucket_name, do: bucket.bucket_name, else: "no-bucket"),
          if(bucket.endpoint, do: bucket.endpoint, else: "/")
        ]

        Enum.join(path_parts, "")

      _ ->
        "#{bucket.provider}: unknown configuration"
    end
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
      <button
        type="button"
        phx-click="switch_settings_tab"
        phx-value-tab="external_libraries"
        class="btn btn-ghost btn-xs"
      >
        {gettext("Details")}
      </button>
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

    # Reload storage settings
    redundancy_copies = to_string(Storage.redundancy_copies())
    auto_generate_variants = to_string(Storage.get_auto_generate_variants())
    max_upload_size_mb = Settings.get_setting("storage_max_upload_size_mb", "500")

    # Recalculate max redundancy
    active_buckets_count = Enum.count(buckets, & &1.enabled)
    max_redundancy = if active_buckets_count > 0, do: active_buckets_count, else: 1
    current_redundancy = String.to_integer(redundancy_copies)
    current_max_upload_size_mb = String.to_integer(max_upload_size_mb)

    socket
    |> assign(:buckets, buckets)
    |> assign(:bucket_file_counts, bucket_file_counts)
    |> assign(:redundancy_copies, current_redundancy)
    |> assign(:auto_generate_variants, auto_generate_variants == "true")
    |> assign(:active_buckets_count, active_buckets_count)
    |> assign(:max_redundancy, max_redundancy)
    |> assign(:form_redundancy, current_redundancy)
    |> assign(:form_auto_generate_variants, auto_generate_variants == "true")
    |> assign(:max_upload_size_mb, current_max_upload_size_mb)
    |> assign(:form_max_upload_size_mb, current_max_upload_size_mb)
  end

  defp parse_integer(val, fallback) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> fallback
    end
  end
end
