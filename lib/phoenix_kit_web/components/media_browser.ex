defmodule PhoenixKitWeb.Components.MediaBrowser do
  @moduledoc """
  MediaBrowser LiveComponent — embeddable media management UI.

  Provides a full media browser with folder navigation, file upload, search,
  and selection tools. Operates in two modes:

  - **Uncontrolled** (default): all navigation state is owned internally.
    No URL sync.
  - **Controlled** (opt-in): when `on_navigate` is set to a truthy value,
    navigation events (`navigate_folder`, `search`, `clear_search`, `set_page`)
    emit `{PhoenixKitWeb.Components.MediaBrowser, id, {:navigate, params}}`
    to the parent LiveView process instead of mutating local state. The parent
    must call `push_patch` and feed URL params back via `send_update` with a
    `:nav_params` key.

  ## Enabling uploads

  The fastest path is the `Embed` helper — one `use` line gives you
  uploads, the validate-channel stub, and the message delegator:

      defmodule MyAppWeb.MediaPage do
        use MyAppWeb, :live_view
        use PhoenixKitWeb.Components.MediaBrowser.Embed
      end

  Manual setup (if you prefer explicit wiring) is three calls:

      def mount(_params, _session, socket) do
        {:ok, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
      end

      def handle_event("validate", _params, socket), do: {:noreply, socket}

      def handle_info({__MODULE__, _, _} = msg, socket) do
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end

  ## Usage (uncontrolled)

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        phoenix_kit_current_user={@phoenix_kit_current_user}
      />

  ## Usage (controlled — URL-sync driven by parent)

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        phoenix_kit_current_user={@phoenix_kit_current_user}
        on_navigate={true}
      />

  The parent LiveView must implement:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, "media-browser",
                       {:navigate, params}}, socket) do
        # push_patch to update URL, handle_params will send_update back
      end

  ## Required attributes

  - `id` — unique DOM id (required by LiveComponent)

  ## Optional attributes

  - `phoenix_kit_current_user` — logged-in user struct (for upload attribution)
  - `scope_folder_id` — constrain the browser to a virtual root folder
  - `on_navigate` — when truthy, enables controlled mode (URL-sync via parent)
  - `admin` — when `true`, clicking a file opens the admin detail page at
    `/admin/media/:uuid`. When `false` (default), clicks open a read-only
    in-place modal viewer (image / video / PDF / icon + metadata + Download
    + prev/next navigation). Bulk-select is still reachable via the
    toolbar's Select button — once `select_mode` is on, clicks toggle
    selection instead of opening the modal.
  """
  use PhoenixKitWeb, :live_component

  require Logger

  import Ecto.Query

  import PhoenixKitWeb.Components.FolderExplorer,
    only: [
      folder_explorer: 1,
      folder_tree_node: 1,
      folder_color_hex: 1,
      folder_icon_style: 1,
      folder_bg_style: 1
    ]

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Utils.Format
  alias PhoenixKit.Utils.Routes

  # Grid/list view preference is persisted per-user in `custom_fields`
  # ("user meta") so the server renders the correct mode on first paint —
  # no grid→list flash while the client restores a localStorage value
  # after connect.
  @media_view_mode_key "media_view_mode"

  # Sidebar folder-tree state, also persisted server-side in user meta and
  # rendered on first paint — same reasoning as the view mode above: restoring
  # the expanded folders from localStorage only after connect made the tree
  # render fully collapsed and then jump to its open positions.
  @media_expanded_folders_key "media_expanded_folders"
  @media_sidebar_collapsed_key "media_sidebar_collapsed"

  # ──────────────────────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────────────────────

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:scope_folder_id, fn -> nil end)
      |> assign_new(:admin, fn -> false end)
      |> assign_new(:viewer_file, fn -> nil end)
      # When true, the browser fills its parent's width + height (flex-1)
      # instead of the default fixed-height card. Used by the full-page
      # admin media view; modal/gallery embeds keep the bounded default.
      |> assign_new(:fill_height, fn -> false end)

    cond do
      not Map.has_key?(socket.assigns, :uploaded_files) ->
        socket = init_socket(socket)

        # Register this component id with the parent so it can route uploads here
        send(self(), {__MODULE__, :register_component, socket.assigns.id})

        # Apply initial params if provided (avoids flash of root before correct view)
        socket =
          if Map.has_key?(assigns, :initial_params),
            do: apply_nav_params(socket, assigns.initial_params),
            else: socket

        {:ok, socket}

      Map.has_key?(assigns, :nav_params) ->
        {:ok, apply_nav_params(socket, socket.assigns.nav_params)}

      Map.has_key?(assigns, :pending_upload) ->
        {:ok, process_pending_upload(socket, assigns.pending_upload)}

      # The header-image picker (MediaSelectorModal) reports back here via
      # `notify: {__MODULE__, id}`: a confirmed selection sets the cover or logo
      # (per `@image_picker_target`); a close just dismisses the picker.
      Map.has_key?(assigns, :media_selected) ->
        {:ok, set_image_from_selection(socket, assigns.media_selected)}

      Map.has_key?(assigns, :media_selector_closed) ->
        {:ok, assign(socket, :selecting_cover, false)}

      Map.get(assigns, :action) == :commit_upload_batch ->
        {:ok, commit_upload_batch(socket)}

      true ->
        {:ok, socket}
    end
  end

  # Processes one entry and buffers the result. A single reload + flash is
  # committed from commit_upload_batch/1 once the batch debounce window closes,
  # so dropping N files produces one page reload instead of N.
  defp process_pending_upload(socket, {path, entry}) do
    result = process_single_upload(socket, path, entry)
    File.rm(path)

    batch = [result | socket.assigns[:pending_batch] || []]

    new_uuids =
      case result do
        {:ok, %{file_uuid: uuid}} -> [uuid | socket.assigns.last_uploaded_file_uuids]
        _ -> socket.assigns.last_uploaded_file_uuids
      end

    socket =
      socket
      |> assign(:pending_batch, batch)
      |> assign(:last_uploaded_file_uuids, new_uuids)

    if socket.assigns[:batch_scheduled] do
      socket
    else
      Phoenix.LiveView.send_update_after(
        __MODULE__,
        [id: socket.assigns.id, action: :commit_upload_batch],
        250
      )

      assign(socket, :batch_scheduled, true)
    end
  end

  defp commit_upload_batch(socket) do
    batch = socket.assigns[:pending_batch] || []
    {flash_type, flash_msg} = build_upload_flash_message(Enum.reverse(batch))

    socket
    |> assign(:pending_batch, [])
    |> assign(:batch_scheduled, false)
    |> reload_current_page()
    |> put_flash(flash_type, flash_msg)
  end

  # Sets the open folder's cover (background) or logo (icon) — per
  # `@image_picker_target` — to a file chosen in the media picker (an existing
  # folder image or one just uploaded into it via the picker).
  defp set_image_from_selection(socket, uuids) do
    target = socket.assigns[:image_picker_target] || "cover"
    attr = if target == "logo", do: :logo_file_uuid, else: :cover_file_uuid
    folder_uuid = socket.assigns[:editing_folder_header]
    file_uuid = uuids |> List.wrap() |> List.first()
    socket = assign(socket, :selecting_cover, false)
    folder = is_binary(folder_uuid) && loaded_folder(socket, folder_uuid)

    if is_binary(file_uuid) and folder do
      scope = scope_folder_id(socket)

      case Storage.update_folder(folder, %{attr => file_uuid}, scope) do
        {:ok, updated} ->
          socket
          |> maybe_refresh_current_folder(updated, folder_uuid)
          |> reload_current_page()

        _ ->
          put_flash(socket, :error, gettext("Failed to set the image"))
      end
    else
      socket
    end
  end

  # Keeps the in-folder header in sync after a header change — refreshes the
  # current folder struct + cover/logo URLs when the edited folder is open.
  defp maybe_refresh_current_folder(socket, updated, folder_uuid) do
    if socket.assigns[:current_folder] &&
         to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid) do
      # Editor-time path (infrequent): load both URLs unconditionally so the
      # Edit-header previews stay correct even with the show toggles off.
      socket
      |> assign(:current_folder, updated)
      |> assign(:folder_cover_url, folder_image_url(updated.cover_file_uuid))
      |> assign(:folder_logo_url, folder_image_url(updated.logo_file_uuid))
    else
      socket
    end
  end

  # Update a folder-header field (size / toggles / cover-or-logo clear) and
  # refresh the open folder's header. No listing reload needed — header changes
  # don't affect the file grid (the cover/logo stay as folder assets).
  defp update_header_field(socket, folder_uuid, attrs) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)

    case folder && Storage.update_folder(folder, attrs, scope) do
      {:ok, updated} ->
        {:noreply, maybe_refresh_current_folder(socket, updated, folder_uuid)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update the header"))}
    end
  end

  defp header_option_field("title"), do: :header_show_title
  defp header_option_field("icon"), do: :header_show_icon
  defp header_option_field("creator"), do: :header_show_creator
  defp header_option_field("date"), do: :header_show_date
  defp header_option_field("file_count"), do: :header_show_file_count
  defp header_option_field("description"), do: :header_show_description
  defp header_option_field("background"), do: :header_show_background
  defp header_option_field(_), do: nil

  defp apply_nav_params(socket, params) do
    q = params[:q] || ""
    page = params[:page] || 1
    filter_orphaned = params[:filter_orphaned] || false
    file_view = params[:view]
    scope = scope_folder_id(socket)
    per_page = socket.assigns.per_page

    {current_folder, breadcrumbs, folders, scoped_fallback?} =
      resolve_folder(params[:folder], scope)

    actual_uuid = current_folder && current_folder.uuid

    {files, total_count} =
      load_nav_files(
        scope,
        page,
        per_page,
        q,
        actual_uuid,
        filter_orphaned,
        file_view,
        list_extra(socket)
      )

    orphaned_count =
      if filter_orphaned,
        do: total_count,
        else: Storage.count_orphaned_files(scope)

    socket
    |> assign(:current_folder, current_folder)
    |> assign_folder_header_media(current_folder)
    |> assign(:breadcrumbs, breadcrumbs)
    # The "all" view, the orphaned view, and any active search are flat file
    # listings — they show no folder cards, only the matching files. (The
    # sidebar folder tree is unaffected; only the grid's folder cards here.)
    |> assign(
      :folders,
      if(file_view == "all" or filter_orphaned or q != "", do: [], else: folders)
    )
    |> assign(:search_query, q)
    |> assign(:current_page, page)
    |> assign(:filter_orphaned, filter_orphaned)
    |> assign(:filter_trash, false)
    |> assign(:file_view, file_view)
    |> assign(:orphaned_count, orphaned_count)
    |> assign(:trash_count, full_trash_count(scope_folder_id(socket)))
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, ceil(total_count / per_page))
    |> then(
      &if(scoped_fallback?,
        do: put_flash(&1, :info, gettext("Folder not accessible — showing root")),
        else: &1
      )
    )
    |> auto_expand_breadcrumbs(breadcrumbs)
  end

  defp resolve_folder(folder_uuid, scope) do
    if folder_uuid in [nil, ""] do
      {nil, [], Storage.list_folders(nil, scope), false}
    else
      folder = Storage.get_folder(folder_uuid)

      if folder && Storage.within_scope?(folder.uuid, scope) do
        bc = Storage.folder_breadcrumbs(folder.uuid, scope)
        flds = Storage.list_folders(folder.uuid, scope)
        {folder, bc, flds, false}
      else
        # Folder not found or outside scope — fall back to scope root.
        {nil, [], Storage.list_folders(nil, scope), not is_nil(folder_uuid)}
      end
    end
  end

  defp load_nav_files(scope, page, per_page, q, actual_uuid, filter_orphaned, file_view, extra) do
    cond do
      filter_orphaned -> load_orphaned_files(page, per_page)
      file_view == "all" -> load_all_view_files(scope, page, per_page, q, extra)
      true -> load_scoped_files(scope, page, per_page, actual_uuid, q, extra)
    end
  end

  # Sort + file-type filter opts from the toolbar, for the listing query.
  defp list_extra(socket) do
    [
      sort: socket.assigns[:sort_by] || "newest",
      file_type: socket.assigns[:file_type_filter] || "all"
    ]
  end

  defp init_socket(socket) do
    scope = scope_folder_id(socket)
    scope_folder = if scope, do: Storage.get_folder(scope)
    scope_invalid = not is_nil(scope) and is_nil(scope_folder)

    enabled_buckets = Storage.list_enabled_buckets()
    has_buckets = not Enum.empty?(enabled_buckets)

    scope_name = if scope_folder, do: scope_folder.name, else: "Root"

    socket
    |> maybe_allow_upload(has_buckets)
    |> assign(:has_buckets, has_buckets)
    |> assign(:scope_invalid, scope_invalid)
    |> assign(:scope_folder_name, scope_name)
    |> assign(:show_upload, false)
    |> assign(:show_search, false)
    |> assign(:last_uploaded_file_uuids, [])
    |> assign(:pending_batch, [])
    |> assign(:batch_scheduled, false)
    |> assign(:filter_orphaned, false)
    |> assign(:filter_trash, false)
    |> assign(:trash_count, full_trash_count(scope_folder_id(socket)))
    |> assign(:file_view, nil)
    |> assign(
      :orphaned_count,
      if(scope_invalid, do: 0, else: Storage.count_orphaned_files(scope))
    )
    |> assign(:current_folder, nil)
    |> assign(:folder_creator_user, nil)
    |> assign(:folder_creator_name, nil)
    |> assign(:folder_cover_url, nil)
    |> assign(:folder_logo_url, nil)
    # The header-image media picker (MediaSelectorModal): open flag + which
    # image it sets ("cover" background or "logo" icon).
    |> assign(:selecting_cover, false)
    |> assign(:image_picker_target, "cover")
    |> assign(:breadcrumbs, [])
    |> assign(:folders, if(scope_invalid, do: [], else: Storage.list_folders(nil, scope)))
    |> assign(:folder_tree, if(scope_invalid, do: [], else: Storage.list_folder_tree(scope)))
    |> assign(
      :sidebar_collapsed,
      load_user_sidebar_collapsed(socket.assigns[:phoenix_kit_current_user])
    )
    |> assign(
      :expanded_folders,
      load_user_expanded_folders(socket.assigns[:phoenix_kit_current_user])
    )
    |> assign(:renaming_folder, nil)
    |> assign(:renaming_source, nil)
    |> assign(:renaming_text, "")
    |> assign(:editing_folder_description, nil)
    |> assign(:folder_description_text, "")
    # In-folder header editor (edits the current folder's name + description
    # together; distinct from the grid/list card description-only editors).
    |> assign(:editing_folder_header, nil)
    |> assign(:folder_header_name, "")
    |> assign(:folder_header_description, "")
    |> assign(:view_mode, load_user_view_mode(socket.assigns[:phoenix_kit_current_user]))
    # Toolbar sort + file-type filter (socket state, applied to the listing).
    |> assign(:sort_by, "newest")
    |> assign(:file_type_filter, "all")
    |> assign(:search_query, "")
    |> assign(:select_mode, false)
    |> assign(:selected_files, MapSet.new())
    |> assign(:selected_folders, MapSet.new())
    |> assign(:show_move_modal, false)
    # Expand state for the Move modal's directory tree (separate from the
    # sidebar's :expanded_folders so drilling one doesn't move the other).
    # Starts collapsed → top-level folders only, drill in via the chevrons.
    |> assign(:move_expanded, MapSet.new())
    |> assign(:current_page, 1)
    |> assign(:per_page, 50)
    |> then(fn s ->
      if scope_invalid,
        do: assign(s, uploaded_files: [], total_count: 0, total_pages: 0),
        else: reload_current_page(s)
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Upload
  # ──────────────────────────────────────────────────────────────

  @doc """
  Handles the upload setup message from the MediaBrowser component.

  Parent LiveViews embedding MediaBrowser should add this to their `handle_info`:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, _id, :setup_uploads}, socket) do
        {:noreply, PhoenixKitWeb.Components.MediaBrowser.setup_uploads(socket)}
      end

  Or use the catch-all delegator:

      def handle_info({PhoenixKitWeb.Components.MediaBrowser, _, _} = msg, socket) do
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end
  """
  def setup_uploads(socket) do
    if socket.assigns[:uploads] do
      socket
    else
      max_size_mb =
        Settings.get_setting_cached("storage_max_upload_size_mb", "500")
        |> String.to_integer()

      socket
      |> assign(:max_upload_size_mb, max_size_mb)
      |> allow_upload(:media_files,
        accept: :any,
        max_entries: 10,
        max_file_size: max_size_mb * 1_000_000,
        auto_upload: true,
        progress: &__MODULE__.parent_progress/3
      )
    end
  end

  @doc false
  # Progress callback that runs on the parent LiveView socket.
  # Consumes the upload and sends the file to the MediaBrowser component for processing.
  def parent_progress(:media_files, entry, socket) do
    if entry.done? do
      # Persist file to a temp path since consume_uploaded_entry cleans up the original
      persistent_path = Path.join(System.tmp_dir!(), "pk_upload_#{entry.uuid}")

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          File.cp!(path, persistent_path)
          {:ok, :done}
        end)

      if result == :done do
        # Payload is wrapped in a tuple so the outer message stays a 3-tuple;
        # the Embed macro's handle_info matches `{Mod, _, _}` only.
        send(self(), {__MODULE__, :process_pending_upload, {persistent_path, entry}})
      end
    end

    {:noreply, socket}
  end

  @doc "Catch-all handler for parent LiveViews to delegate MediaBrowser messages."
  def handle_parent_info({__MODULE__, :register_component, id}, socket) do
    ids = MapSet.put(socket.assigns[:media_browser_ids] || MapSet.new(), id)
    {:noreply, assign(socket, :media_browser_ids, ids)}
  end

  def handle_parent_info({__MODULE__, :process_pending_upload, {path, entry}}, socket) do
    # Forward the upload to every registered MediaBrowser. If more than one is on
    # the page, copy the temp file per recipient so each component owns its own
    # path — otherwise the first one to run would delete the shared file and the
    # rest would crash on `File.stat/1`.
    component_ids =
      socket.assigns[:media_browser_ids]
      |> Kernel.||(MapSet.new())
      |> MapSet.to_list()

    case component_ids do
      [] ->
        File.rm(path)

      [single] ->
        send_update(__MODULE__, id: single, pending_upload: {path, entry})

      [first | rest] ->
        send_update(__MODULE__, id: first, pending_upload: {path, entry})

        Enum.each(rest, fn id ->
          copy = "#{path}-#{id}"

          case File.cp(path, copy) do
            :ok -> send_update(__MODULE__, id: id, pending_upload: {copy, entry})
            _ -> :ok
          end
        end)
    end

    {:noreply, socket}
  end

  def handle_parent_info(_msg, socket), do: {:noreply, socket}

  defp maybe_allow_upload(socket, has_buckets) do
    if has_buckets do
      max_size_mb =
        Settings.get_setting_cached("storage_max_upload_size_mb", "500")
        |> String.to_integer()

      assign(socket, :max_upload_size_mb, max_size_mb)
    else
      assign(socket, :max_upload_size_mb, 0)
    end
  end

  @doc false
  def handle_progress(:media_files, entry, socket) do
    socket =
      if entry.done? do
        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            process_single_upload(socket, path, entry)
          end)

        {flash_type, flash_msg} = build_upload_flash_message([result])

        new_uuids =
          case result do
            {:ok, %{file_uuid: uuid}} -> [uuid | socket.assigns.last_uploaded_file_uuids]
            _ -> socket.assigns.last_uploaded_file_uuids
          end

        socket
        |> reload_current_page()
        |> put_flash(flash_type, flash_msg)
        |> assign(:last_uploaded_file_uuids, new_uuids)
      else
        socket
      end

    {:noreply, socket}
  end

  # ──────────────────────────────────────────────────────────────
  # Event handlers
  # ──────────────────────────────────────────────────────────────

  # Finder/Explorer-style instant folder creation. Click the "+" button
  # in any toolbar and a folder appears named "untitled" (or
  # "untitled 1", "untitled 2", ... if that's taken). The new folder
  # immediately opens inline rename in the sidebar.
  def handle_event("create_untitled_folder", _params, socket) do
    cond do
      socket.assigns[:filter_trash] ->
        {:noreply, put_flash(socket, :error, gettext("Cannot create folders in trash"))}

      socket.assigns[:file_view] == "all" ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot create folders in the all-files view"))}

      true ->
        parent_uuid = current_folder_uuid(socket)
        scope = scope_folder_id(socket)
        user = socket.assigns[:phoenix_kit_current_user]
        name = next_untitled_name(parent_uuid, scope)

        case Storage.create_folder(
               %{name: name, parent_uuid: parent_uuid, user_uuid: user && user.uuid},
               scope
             ) do
          {:ok, folder} ->
            {:noreply,
             socket
             |> reload_folder_lists()
             |> expand_sidebar_folder(parent_uuid)
             |> assign(:sidebar_collapsed, false)
             |> assign(:renaming_folder, folder.uuid)
             |> assign(:renaming_source, "sidebar")
             |> assign(:renaming_text, name)
             |> put_flash(:info, gettext("Folder \"%{name}\" created", name: name))}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot create folder outside the allowed scope"))}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to create folder"))}
        end
    end
  end

  def handle_event("delete_folder", %{"id" => folder_uuid}, socket) do
    folder = Storage.get_folder(folder_uuid)
    scope = scope_folder_id(socket)

    if folder do
      # Mirror the file kebab: trash-recursive when outside the trash
      # view, permanent-recursive (with storage cleanup) when inside.
      # Subtree files come along automatically — both helpers walk
      # descendants via `Storage.folder_subtree_uuids/1` and apply the
      # operation atomically.
      result =
        if socket.assigns[:filter_trash] do
          Storage.delete_folder_completely(folder, scope)
        else
          Storage.trash_folder(folder, scope)
        end

      flash =
        if socket.assigns[:filter_trash],
          do: gettext("Folder permanently deleted"),
          else: gettext("Folder moved to trash")

      case result do
        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot delete folder outside the allowed scope"))}

        _ ->
          {:noreply,
           socket
           |> reload_folder_lists()
           |> reload_current_page()
           |> put_flash(:info, flash)}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Folder not found"))}
    end
  end

  def handle_event(
        "move_file_to_folder",
        %{"file_uuid" => file_uuid, "folder_uuid" => folder_uuid},
        socket
      ) do
    scope = scope_folder_id(socket)
    # "root" in a scoped browser is the scope folder, not nil. Passing nil
    # would mean the system's true root, which is outside the scope —
    # `move_file_to_folder/3` would reject it with `:out_of_scope`.
    target = if folder_uuid == "", do: scope, else: folder_uuid

    case Storage.move_file_to_folder(file_uuid, target, scope) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("File moved")) |> reload_current_page()}

      {:error, :out_of_scope} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move file outside the allowed scope"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to move file"))}
    end
  end

  # Drag a folder onto another folder (or the root drop target) to
  # reparent it. Mirrors `move_file_to_folder` but uses
  # `Storage.update_folder/3`, which enforces the cycle check (can't
  # move a folder into its own descendant). JS pre-empts the
  # drop-on-self case so we don't see it here.
  def handle_event(
        "move_folder_to_folder",
        %{"folder_uuid" => folder_uuid, "target_uuid" => target_uuid},
        socket
      ) do
    scope = scope_folder_id(socket)
    target = if target_uuid == "", do: scope, else: target_uuid

    case Storage.get_folder(folder_uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Folder not found"))}

      folder ->
        case Storage.update_folder(folder, %{parent_uuid: target}, scope) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Folder moved"))
             |> reload_folder_lists()
             |> reload_current_page()}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

          {:error, :cycle} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move a folder into its own descendant"))}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to move folder"))}
        end
    end
  end

  # Drag-to-trash: file dragged onto the sidebar Trash button. Always
  # soft-deletes via `Storage.trash_file/1` — the "drop on trash" gesture
  # means "put this in the trash", not "permanently destroy". Permanent
  # deletion stays explicit (kebab Delete Permanently when already in
  # trash view, or the Empty Trash button).
  def handle_event("trash_file", %{"file_uuid" => file_uuid}, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()
    file = repo.get(Storage.File, file_uuid)

    cond do
      is_nil(file) ->
        {:noreply, put_flash(socket, :error, gettext("File not found"))}

      not Storage.within_scope?(file.folder_uuid, scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move file outside the allowed scope"))}

      true ->
        Storage.trash_file(file)

        {:noreply,
         socket
         |> put_flash(:info, gettext("File moved to trash"))
         |> reload_current_page()}
    end
  end

  # Drag-to-trash for a single folder. Mirrors `trash_file` above but
  # uses `Storage.trash_folder/2`, which recursively trashes the folder
  # and every descendant + file inside the subtree. Always soft-delete
  # — permanent deletion stays explicit (kebab Delete Permanently when
  # already in the trash view, or bulk select + delete).
  def handle_event("trash_folder", %{"folder_uuid" => folder_uuid}, socket) do
    scope = scope_folder_id(socket)
    folder = Storage.get_folder(folder_uuid)

    cond do
      is_nil(folder) ->
        {:noreply, put_flash(socket, :error, gettext("Folder not found"))}

      not Storage.within_scope?(folder.uuid, scope) ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

      true ->
        case Storage.trash_folder(folder, scope) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Folder moved to trash"))
             |> reload_folder_lists()
             |> reload_current_page()}

          {:error, :out_of_scope} ->
            {:noreply,
             put_flash(socket, :error, gettext("Cannot move folder outside the allowed scope"))}

          _ ->
            {:noreply, put_flash(socket, :error, gettext("Failed to move folder to trash"))}
        end
    end
  end

  def handle_event("search", %{"q" => query}, socket) do
    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: query, page: 1, view: socket.assigns.file_view}}}
      )

      {:noreply, socket}
    else
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        if file_view == "all" do
          load_all_view_files(scope, 1, per_page, query)
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, query)
        end

      folders =
        cond do
          file_view == "all" -> []
          query != "" -> []
          true -> Storage.list_folders(folder_uuid, scope)
        end

      {:noreply,
       socket
       |> assign(:search_query, query)
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  # The inline search collapses back to the magnifier when emptied via the ✕ or
  # blurred while empty.
  def handle_event("close_search_if_empty", _params, socket) do
    if socket.assigns.search_query == "" do
      {:noreply, assign(socket, :show_search, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear_search", _params, socket) do
    socket = assign(socket, :show_search, false)

    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: "", page: 1, view: socket.assigns.file_view}}}
      )

      {:noreply, socket}
    else
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        if file_view == "all" do
          load_all_view_files(scope, 1, per_page, "")
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, "")
        end

      folders =
        if file_view == "all",
          do: [],
          else: Storage.list_folders(folder_uuid, scope)

      {:noreply,
       socket
       |> assign(:search_query, "")
       |> assign(:folders, folders)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("navigate_folder", params, socket) do
    folder_uuid = params["folder-uuid"] || params["folder_uuid"]
    navigate_to_folder(socket, folder_uuid)
  end

  def handle_event("navigate_root", _params, socket) do
    navigate_to_folder(socket, nil)
  end

  def handle_event("navigate_view_all", _params, socket) do
    if controlled_mode?(socket) do
      q = socket.assigns.search_query

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{view: "all", folder: nil, q: q, page: 1, filter_orphaned: false}}}
      )

      {:noreply, socket}
    else
      scope = scope_folder_id(socket)
      per_page = socket.assigns.per_page
      q = socket.assigns.search_query
      {files, total_count} = load_all_view_files(scope, 1, per_page, q, list_extra(socket))

      {:noreply,
       socket
       |> assign(:file_view, "all")
       |> assign(:current_folder, nil)
       |> assign(:breadcrumbs, [])
       |> assign(:folders, [])
       |> assign(:filter_orphaned, false)
       |> assign(:filter_trash, false)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) when mode in ["grid", "list"] do
    # Persist the choice to user meta so the next page load renders this mode
    # directly (the server is the source of truth — see @media_view_mode_key).
    socket =
      case socket.assigns[:phoenix_kit_current_user] do
        %{} = user ->
          assign(socket, :phoenix_kit_current_user, persist_user_view_mode(user, mode))

        _ ->
          socket
      end

    {:noreply, assign(socket, :view_mode, mode)}
  end

  @valid_sorts ~w(newest oldest name_asc name_desc largest smallest)
  @valid_file_types ~w(all image video document audio archive other)

  def handle_event("set_sort", %{"sort" => sort}, socket) when sort in @valid_sorts do
    {:noreply,
     socket
     |> assign(:sort_by, sort)
     |> assign(:current_page, 1)
     |> reload_current_page()}
  end

  # Ignore an out-of-whitelist sort instead of crashing the component.
  def handle_event("set_sort", _params, socket), do: {:noreply, socket}

  def handle_event("set_file_filter", %{"type" => type}, socket)
      when type in @valid_file_types do
    {:noreply,
     socket
     |> assign(:file_type_filter, type)
     |> assign(:current_page, 1)
     |> reload_current_page()}
  end

  # Ignore an out-of-whitelist file-type filter instead of crashing.
  def handle_event("set_file_filter", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_sidebar", _params, socket) do
    socket = assign(socket, :sidebar_collapsed, !socket.assigns.sidebar_collapsed)
    {:noreply, persist_tree_state(socket)}
  end

  def handle_event("start_rename_folder", %{"folder-uuid" => folder_uuid} = params, socket) do
    source = params["source"] || "content"
    folder = Storage.get_folder(folder_uuid)

    {:noreply,
     socket
     |> assign(:renaming_folder, folder_uuid)
     |> assign(:renaming_source, source)
     |> assign(:renaming_text, (folder && folder.name) || "")}
  end

  def handle_event("rename_folder_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :renaming_text, name)}
  end

  def handle_event("cancel_rename_folder", _params, socket) do
    {:noreply,
     socket
     |> assign(:renaming_folder, nil)
     |> assign(:renaming_source, nil)
     |> assign(:renaming_text, "")}
  end

  def handle_event("rename_folder", %{"folder_uuid" => folder_uuid, "name" => name}, socket) do
    folder = Storage.get_folder(folder_uuid)

    scope = scope_folder_id(socket)

    if folder && name != "" do
      case Storage.update_folder(folder, %{name: String.trim(name)}, scope) do
        {:ok, _} ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:renaming_folder, nil)
           |> assign(:renaming_source, nil)
           |> assign(:renaming_text, "")
           |> assign(:folders, Storage.list_folders(parent_uuid, scope))
           |> assign(:folder_tree, Storage.list_folder_tree(scope))}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot rename folder outside the allowed scope"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to rename folder"))}
      end
    else
      {:noreply,
       socket
       |> assign(:renaming_folder, nil)
       |> assign(:renaming_source, nil)
       |> assign(:renaming_text, "")}
    end
  end

  # Folder description edit — opens the inline editor in the current-folder
  # header, seeded with the folder's existing description.
  def handle_event("start_edit_folder_description", %{"folder-uuid" => folder_uuid}, socket) do
    folder = loaded_folder(socket, folder_uuid)

    {:noreply,
     socket
     |> assign(:editing_folder_description, folder_uuid)
     |> assign(:folder_description_text, (folder && folder.description) || "")}
  end

  def handle_event("folder_description_input", %{"description" => description}, socket) do
    {:noreply, assign(socket, :folder_description_text, description)}
  end

  def handle_event("cancel_edit_folder_description", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_folder_description, nil)
     |> assign(:folder_description_text, "")}
  end

  def handle_event(
        "save_folder_description",
        %{"folder_uuid" => folder_uuid, "description" => description},
        socket
      ) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)
    # Blank/whitespace-only clears the description (stored as nil).
    trimmed = String.trim(description)
    value = if trimmed == "", do: nil, else: trimmed

    if folder do
      case Storage.update_folder(folder, %{description: value}, scope) do
        {:ok, updated} ->
          parent_uuid = current_folder_uuid(socket)

          socket =
            socket
            |> assign(:editing_folder_description, nil)
            |> assign(:folder_description_text, "")
            # Reload the listing so the grid card / list row reflects the new
            # description immediately (they render from `@folders`, not the
            # tree), plus the tree.
            |> assign(:folders, Storage.list_folders(parent_uuid, scope))
            |> assign(:folder_tree, Storage.list_folder_tree(scope))

          # Refresh the header's folder if we're editing the one we're inside.
          socket =
            if socket.assigns[:current_folder] &&
                 to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid),
               do: assign(socket, :current_folder, updated),
               else: socket

          {:noreply, socket}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Cannot edit a folder outside the allowed scope")
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to save folder description"))}
      end
    else
      {:noreply,
       socket
       |> assign(:editing_folder_description, nil)
       |> assign(:folder_description_text, "")}
    end
  end

  # ── In-folder header editor ───────────────────────────────────────────
  # Edits the current folder's name AND description together from the
  # header you see after opening a folder. Separate from the grid/list
  # card editors above (which only touch the description), so adding a
  # name field here doesn't disturb those.
  def handle_event("start_edit_folder_header", %{"folder-uuid" => folder_uuid}, socket) do
    folder = loaded_folder(socket, folder_uuid)

    {:noreply,
     socket
     |> assign(:editing_folder_header, folder_uuid)
     |> assign(:folder_header_name, (folder && folder.name) || "")
     |> assign(:folder_header_description, (folder && folder.description) || "")
     # Load the cover/logo previews up front (unconditionally) so the editor
     # shows them even when their show toggles are off — navigation gates these
     # on the toggles, so they may be nil when the editor opens.
     |> assign(:folder_cover_url, folder && folder_image_url(folder.cover_file_uuid))
     |> assign(:folder_logo_url, folder && folder_image_url(folder.logo_file_uuid))}
  end

  def handle_event("folder_header_input", params, socket) do
    {:noreply,
     socket
     |> assign(:folder_header_name, params["name"] || socket.assigns.folder_header_name)
     |> assign(
       :folder_header_description,
       params["description"] || socket.assigns.folder_header_description
     )}
  end

  def handle_event("cancel_edit_folder_header", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_folder_header, nil)
     |> assign(:folder_header_name, "")
     |> assign(:folder_header_description, "")}
  end

  # Open the media picker (scoped to the open folder) to choose/upload the
  # header background (cover) or the icon (logo).
  def handle_event("open_cover_picker", _params, socket) do
    {:noreply, socket |> assign(:image_picker_target, "cover") |> assign(:selecting_cover, true)}
  end

  def handle_event("open_logo_picker", _params, socket) do
    {:noreply, socket |> assign(:image_picker_target, "logo") |> assign(:selecting_cover, true)}
  end

  # Clear the folder's cover / logo. The image stays in the folder as a normal
  # asset — only the header reference is removed.
  def handle_event("remove_folder_cover", %{"folder-uuid" => folder_uuid}, socket) do
    update_header_field(socket, folder_uuid, %{cover_file_uuid: nil})
  end

  def handle_event("remove_folder_logo", %{"folder-uuid" => folder_uuid}, socket) do
    update_header_field(socket, folder_uuid, %{logo_file_uuid: nil})
  end

  # Header size (small / medium / large) — affects the hero height.
  def handle_event("set_header_size", %{"size" => size, "folder-uuid" => folder_uuid}, socket)
      when size in ~w(small medium large) do
    update_header_field(socket, folder_uuid, %{header_size: size})
  end

  # Ignore an out-of-whitelist header size instead of crashing.
  def handle_event("set_header_size", _params, socket), do: {:noreply, socket}

  # Toggle a header element's visibility (title / icon / creator / date /
  # file_count / description / background).
  def handle_event(
        "toggle_header_option",
        %{"option" => option, "folder-uuid" => folder_uuid},
        socket
      ) do
    field = header_option_field(option)
    folder = field && loaded_folder(socket, folder_uuid)

    if folder do
      update_header_field(socket, folder_uuid, %{field => !Map.get(folder, field, true)})
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "save_folder_header",
        %{"folder_uuid" => folder_uuid, "name" => name, "description" => description},
        socket
      ) do
    folder = loaded_folder(socket, folder_uuid)
    scope = scope_folder_id(socket)
    trimmed_name = String.trim(name)
    trimmed_desc = String.trim(description)
    desc_value = if trimmed_desc == "", do: nil, else: trimmed_desc

    cond do
      is_nil(folder) ->
        {:noreply, reset_folder_header_edit(socket)}

      trimmed_name == "" ->
        {:noreply, put_flash(socket, :error, gettext("Folder name can't be blank"))}

      true ->
        save_folder_header(socket, folder, folder_uuid, scope, trimmed_name, desc_value)
    end
  end

  def handle_event(
        "change_folder_color",
        %{"folder-uuid" => folder_uuid, "color" => color},
        socket
      ) do
    folder = Storage.get_folder(folder_uuid)

    scope = scope_folder_id(socket)

    if folder do
      case Storage.update_folder(folder, %{color: color}, scope) do
        {:ok, _} ->
          parent_uuid = current_folder_uuid(socket)

          {:noreply,
           socket
           |> assign(:folders, Storage.list_folders(parent_uuid, scope))
           |> assign(:folder_tree, Storage.list_folder_tree(scope))}

        {:error, :out_of_scope} ->
          {:noreply,
           put_flash(socket, :error, gettext("Cannot change folder outside the allowed scope"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to change color"))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_folder_expand", %{"folder-uuid" => folder_uuid}, socket) do
    expanded = socket.assigns.expanded_folders

    expanded =
      if MapSet.member?(expanded, folder_uuid),
        do: MapSet.delete(expanded, folder_uuid),
        else: MapSet.put(expanded, folder_uuid)

    socket = assign(socket, :expanded_folders, expanded)
    {:noreply, persist_tree_state(socket)}
  end

  def handle_event("toggle_select_mode", _params, socket) do
    if socket.assigns.select_mode do
      {:noreply,
       socket
       |> assign(:select_mode, false)
       |> assign(:selected_files, MapSet.new())
       |> assign(:selected_folders, MapSet.new())}
    else
      {:noreply, assign(socket, :select_mode, true)}
    end
  end

  # Long-press on a card (from the MediaDragDrop JS hook) enters select mode and
  # selects the held item.
  def handle_event("long_press_select", %{"type" => "file", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, true)
     |> assign(:selected_files, MapSet.put(socket.assigns.selected_files, uuid))}
  end

  def handle_event("long_press_select", %{"type" => "folder", "uuid" => uuid}, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, true)
     |> assign(:selected_folders, MapSet.put(socket.assigns.selected_folders, uuid))}
  end

  def handle_event("click_file", %{"file-uuid" => file_uuid}, socket) do
    cond do
      # Already in selection mode → toggle this file in/out, stay in selection mode.
      # The toolbar's "Select" button is how callers reach bulk-select; once on,
      # clicks add/remove rather than open the modal.
      socket.assigns.select_mode ->
        {:noreply, do_toggle_file(socket, file_uuid)}

      # Admin context → navigate to the rich admin detail page.
      socket.assigns.admin ->
        {:noreply, push_navigate(socket, to: Routes.path("/admin/media/#{file_uuid}"))}

      # Anywhere else (non-admin, not in select mode) → open the in-place
      # modal viewer for that file. This is the default and is what every
      # embedded MediaBrowser gets unless `admin={true}` is set.
      true ->
        {:noreply, open_viewer(socket, find_uploaded_file(socket, file_uuid))}
    end
  end

  def handle_event("close_viewer", _params, socket) do
    {:noreply, open_viewer(socket, nil)}
  end

  # Single keydown router so we can handle multiple keys without stacking
  # phx-window-keydown directives (only one fires per element).
  def handle_event("viewer_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, open_viewer(socket, nil)}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowLeft"}, socket) do
    {:noreply, step_viewer(socket, :prev)}
  end

  def handle_event("viewer_keydown", %{"key" => "ArrowRight"}, socket) do
    {:noreply, step_viewer(socket, :next)}
  end

  def handle_event("viewer_keydown", _params, socket), do: {:noreply, socket}

  def handle_event("step_viewer", %{"dir" => "prev"}, socket) do
    {:noreply, step_viewer(socket, :prev)}
  end

  def handle_event("step_viewer", %{"dir" => "next"}, socket) do
    {:noreply, step_viewer(socket, :next)}
  end

  # Etcher annotation events + composer lifecycle are owned by the
  # MediaCanvasViewer child LiveComponent embedded in the viewer
  # modal — events fire there, not here. See
  # `lib/phoenix_kit_web/components/media_canvas_viewer.ex`.

  def handle_event("toggle_select_folder", %{"folder-uuid" => folder_uuid}, socket) do
    selected = socket.assigns.selected_folders

    selected =
      if MapSet.member?(selected, folder_uuid),
        do: MapSet.delete(selected, folder_uuid),
        else: MapSet.put(selected, folder_uuid)

    {:noreply, assign(socket, :selected_folders, selected)}
  end

  def handle_event("toggle_select", %{"file-uuid" => file_uuid}, socket) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file_uuid),
        do: MapSet.delete(selected, file_uuid),
        else: MapSet.put(selected, file_uuid)

    {:noreply, assign(socket, :selected_files, selected)}
  end

  def handle_event("select_all", _params, socket) do
    all_file_uuids = Enum.map(socket.assigns.uploaded_files, & &1.file_uuid)
    all_folder_uuids = Enum.map(socket.assigns.folders, & &1.uuid)

    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new(all_file_uuids))
     |> assign(:selected_folders, MapSet.new(all_folder_uuids))}
  end

  def handle_event("deselect_all", _params, socket) do
    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())}
  end

  def handle_event("show_move_modal", _params, socket) do
    # Bulk move only opens when something is selected. The Move button is
    # disabled with an empty selection; this guards the handler too so a
    # stray event can't pop an empty modal.
    if MapSet.size(socket.assigns.selected_files) +
         MapSet.size(socket.assigns.selected_folders) > 0 do
      {:noreply, open_move_modal(socket)}
    else
      {:noreply, socket}
    end
  end

  # Expand/collapse a folder in the Move modal's directory tree.
  def handle_event("toggle_move_folder", %{"folder-uuid" => uuid}, socket) do
    expanded = socket.assigns.move_expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :move_expanded, expanded)}
  end

  def handle_event("close_move_modal", _params, socket) do
    # Clear the transient single-item selection when the cancel came from
    # a kebab-triggered move. Bulk-mode users may want their selection to
    # persist across a cancel (so they can retry without reselecting), so
    # only clear when select_mode is off — which is also when the kebabs
    # are visible, since we hide them in select_mode.
    socket = assign(socket, :show_move_modal, false)

    socket =
      if socket.assigns.select_mode do
        socket
      else
        socket
        |> assign(:selected_files, MapSet.new())
        |> assign(:selected_folders, MapSet.new())
      end

    {:noreply, socket}
  end

  # Single-file move from kebab — pre-populates the selection with just
  # this file and opens the move modal. Reuses the bulk
  # `move_selected_to_folder` flow without entering select_mode.
  def handle_event("prepare_move_file", %{"file-uuid" => file_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new([file_uuid]))
     |> assign(:selected_folders, MapSet.new())
     |> open_move_modal()}
  end

  # Single-folder move from kebab — symmetric to `prepare_move_file`.
  def handle_event("prepare_move_folder", %{"folder-uuid" => folder_uuid}, socket) do
    {:noreply,
     socket
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new([folder_uuid]))
     |> open_move_modal()}
  end

  def handle_event("move_selected_to_folder", %{"folder-uuid" => folder_uuid}, socket) do
    scope = scope_folder_id(socket)
    # "root" in a scoped browser is the scope folder, not nil — same fix as
    # the drag-drop `move_file_to_folder` handler above. Without this,
    # picking the home/root option in the move modal silently failed for
    # files (`:out_of_scope`) and silently *escaped* the scope for folders
    # (the scoped `update_folder` skips the parent-scope check when the
    # new parent is nil).
    target = if folder_uuid == "", do: scope, else: folder_uuid

    Enum.each(socket.assigns.selected_files, fn file_uuid ->
      Storage.move_file_to_folder(file_uuid, target, scope)
    end)

    Enum.each(socket.assigns.selected_folders, fn sel_folder_uuid ->
      if sel_folder_uuid != target do
        folder = Storage.get_folder(sel_folder_uuid)
        if folder, do: Storage.update_folder(folder, %{parent_uuid: target}, scope)
      end
    end)

    file_count = MapSet.size(socket.assigns.selected_files)
    folder_count = MapSet.size(socket.assigns.selected_folders)

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> assign(:show_move_modal, false)
     |> put_flash(
       :info,
       ngettext("%{count} item moved", "%{count} items moved", file_count + folder_count)
     )
     |> reload_folder_lists()
     |> reload_current_page()}
  end

  def handle_event("delete_selected", _params, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()

    if socket.assigns.filter_trash do
      # Permanent delete from trash (with scope guard)
      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          Storage.delete_file_completely(file)
        end
      end)
    else
      # Soft-delete to trash
      Enum.each(socket.assigns.selected_files, fn file_uuid ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          Storage.trash_file(file)
        end
      end)
    end

    # Folders now have trash support (V119) — recursive trash outside
    # the trash view, recursive permanent delete inside. Both operations
    # cover the folder's entire subtree (descendant folders + files).
    Enum.each(socket.assigns.selected_folders, fn folder_uuid ->
      folder = Storage.get_folder(folder_uuid)

      if folder do
        if socket.assigns.filter_trash do
          Storage.delete_folder_completely(folder, scope)
        else
          Storage.trash_folder(folder, scope)
        end
      end
    end)

    file_count = MapSet.size(socket.assigns.selected_files)
    folder_count = MapSet.size(socket.assigns.selected_folders)

    flash =
      if socket.assigns.filter_trash,
        do: "#{file_count + folder_count} item(s) permanently deleted",
        else: "#{file_count + folder_count} item(s) moved to trash"

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> put_flash(:info, flash)
     |> reload_folder_lists()
     |> reload_current_page()}
  end

  def handle_event("download_selected", _params, socket) do
    files =
      socket.assigns.uploaded_files
      |> Enum.filter(&MapSet.member?(socket.assigns.selected_files, &1.file_uuid))
      |> Enum.map(fn f ->
        %{url: Map.get(f.urls, "original") || Map.get(f.urls, :original), name: f.filename}
      end)
      |> Enum.reject(&is_nil(&1.url))

    {:noreply, push_event(socket, "download_files", %{files: files})}
  end

  # Single-file delete via the per-row kebab menu. Mirrors `delete_selected`
  # for one file — soft-delete to trash when outside the trash view, permanent
  # delete when already inside it. Scope-guarded the same way.
  def handle_event("delete_file", %{"file-uuid" => file_uuid}, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()
    file = repo.get(Storage.File, file_uuid)

    if file && Storage.within_scope?(file.folder_uuid, scope) do
      if socket.assigns.filter_trash do
        Storage.delete_file_completely(file)
      else
        Storage.trash_file(file)
      end

      flash =
        if socket.assigns.filter_trash,
          do: gettext("File permanently deleted"),
          else: gettext("File moved to trash")

      {:noreply,
       socket
       |> put_flash(:info, flash)
       |> reload_current_page()}
    else
      {:noreply, socket}
    end
  end

  # Single-file download via the per-row kebab menu. Pushes the same
  # `download_files` event the JS hook listens for, with one entry. The heex
  # only renders the menu item when an "original" URL is present, so a
  # missing URL here is a stale assigns / race condition — silent no-op is
  # the right call.
  def handle_event("download_file", %{"file-uuid" => file_uuid}, socket) do
    file = Enum.find(socket.assigns.uploaded_files, &(&1.file_uuid == file_uuid))
    url = file && (Map.get(file.urls || %{}, "original") || Map.get(file.urls || %{}, :original))

    if url do
      {:noreply,
       push_event(socket, "download_files", %{files: [%{url: url, name: file.filename}]})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_trash_filter", _params, socket) do
    filter_trash = !socket.assigns.filter_trash
    scope = scope_folder_id(socket)

    {files, total_count} =
      if filter_trash do
        load_trashed_files(scope, 1, socket.assigns.per_page)
      else
        folder_uuid = current_folder_uuid(socket)
        load_scoped_files(scope, 1, socket.assigns.per_page, folder_uuid, "")
      end

    # In trash view `@folders` becomes the trashed-folder list so the
    # grid/list rows render trashed folders alongside trashed files.
    # Outside trash it stays the active folder set.
    folders =
      if filter_trash, do: Storage.list_trashed_folders(scope), else: socket.assigns.folders

    {:noreply,
     socket
     |> assign(:filter_trash, filter_trash)
     |> assign(:filter_orphaned, false)
     |> assign(:folders, folders)
     |> assign(:uploaded_files, files)
     |> assign(:total_count, total_count)
     |> assign(:total_pages, ceil(total_count / socket.assigns.per_page))
     |> assign(:current_page, 1)
     |> assign(:trash_count, full_trash_count(scope))}
  end

  def handle_event("restore_selected", _params, socket) do
    scope = scope_folder_id(socket)
    repo = PhoenixKit.Config.get_repo()

    restored_files =
      Enum.reduce(socket.assigns.selected_files, 0, fn file_uuid, acc ->
        file = repo.get(Storage.File, file_uuid)

        if file && Storage.within_scope?(file.folder_uuid, scope) do
          case Storage.restore_file(file) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      end)

    restored_folders =
      Enum.reduce(socket.assigns.selected_folders, 0, fn folder_uuid, acc ->
        folder = Storage.get_folder(folder_uuid)

        if folder && Storage.within_scope?(folder.uuid, scope) do
          case Storage.restore_folder(folder, scope) do
            {:ok, _} -> acc + 1
            _ -> acc
          end
        else
          acc
        end
      end)

    total = restored_files + restored_folders

    {:noreply,
     socket
     |> assign(:select_mode, false)
     |> assign(:selected_files, MapSet.new())
     |> assign(:selected_folders, MapSet.new())
     |> put_flash(:info, ngettext("%{count} item restored", "%{count} items restored", total))
     |> reload_folder_lists()
     |> reload_current_page()}
  end

  def handle_event("empty_trash", _params, socket) do
    {:ok, count} = Storage.empty_trash(scope_folder_id(socket))

    {:noreply,
     socket
     |> assign(:filter_trash, false)
     |> put_flash(
       :info,
       ngettext("%{count} file permanently deleted", "%{count} files permanently deleted", count)
     )
     |> reload_current_page()}
  end

  def handle_event("toggle_orphan_filter", _params, socket) do
    filter_orphaned = !socket.assigns.filter_orphaned

    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)
      q = socket.assigns.search_query

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate,
          %{folder: folder_uuid, q: q, page: 1, filter_orphaned: filter_orphaned, view: nil}}}
      )

      {:noreply, socket}
    else
      per_page = socket.assigns.per_page
      scope = scope_folder_id(socket)
      folder_uuid = current_folder_uuid(socket)
      search = socket.assigns.search_query

      {files, total_count} =
        if filter_orphaned do
          load_orphaned_files(1, per_page)
        else
          load_scoped_files(scope, 1, per_page, folder_uuid, search)
        end

      orphaned_count =
        if filter_orphaned,
          do: total_count,
          else: Storage.count_orphaned_files(scope_folder_id(socket))

      {:noreply,
       socket
       |> assign(:filter_orphaned, filter_orphaned)
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_pages, ceil(total_count / per_page))
       |> assign(:total_count, total_count)
       |> assign(:orphaned_count, orphaned_count)}
    end
  end

  def handle_event("delete_all_orphaned", _params, socket) do
    orphan_uuids = Storage.find_orphaned_files() |> Enum.map(& &1.uuid)
    Storage.queue_file_cleanup(orphan_uuids)

    {:noreply,
     put_flash(
       socket,
       :info,
       ngettext(
         "%{count} orphaned file queued for deletion",
         "%{count} orphaned files queued for deletion",
         length(orphan_uuids)
       )
     )}
  end

  def handle_event("toggle_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, !socket.assigns.show_upload)}
  end

  def handle_event("toggle_search", _params, socket) do
    {:noreply, assign(socket, :show_search, !socket.assigns.show_search)}
  end

  def handle_event("show_upload", _params, socket) do
    {:noreply, assign(socket, :show_upload, true)}
  end

  def handle_event("validate", _params, socket) do
    # Upload progress is handled via the progress: &handle_progress/3 callback.
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :media_files, ref)}
  end

  def handle_event("set_page", %{"page" => page_str}, socket) do
    page =
      case Integer.parse(page_str) do
        {n, _} when n > 0 -> n
        _ -> 1
      end

    if controlled_mode?(socket) do
      folder_uuid = current_folder_uuid(socket)
      q = socket.assigns.search_query
      file_view = socket.assigns.file_view

      send(
        self(),
        {__MODULE__, socket.assigns.id,
         {:navigate, %{folder: folder_uuid, q: q, page: page, view: file_view}}}
      )

      {:noreply, socket}
    else
      folder_uuid = current_folder_uuid(socket)
      per_page = socket.assigns.per_page
      search = socket.assigns.search_query
      scope = scope_folder_id(socket)
      file_view = socket.assigns.file_view

      {files, total_count} =
        cond do
          socket.assigns.filter_orphaned -> load_orphaned_files(page, per_page)
          file_view == "all" -> load_all_view_files(scope, page, per_page, search)
          true -> load_scoped_files(scope, page, per_page, folder_uuid, search)
        end

      {:noreply,
       socket
       |> assign(:uploaded_files, files)
       |> assign(:current_page, page)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Navigation helpers
  # ──────────────────────────────────────────────────────────────

  defp do_toggle_file(socket, file_uuid) do
    selected = socket.assigns.selected_files

    selected =
      if MapSet.member?(selected, file_uuid),
        do: MapSet.delete(selected, file_uuid),
        else: MapSet.put(selected, file_uuid)

    assign(socket, :selected_files, selected)
  end

  # Look up the clicked file's enriched map (filename, mime_type, size, urls,
  # …) inside the current page's uploaded_files list so the modal can render
  # without an extra DB roundtrip.
  defp find_uploaded_file(socket, file_uuid) do
    Enum.find(socket.assigns.uploaded_files, fn f -> f.file_uuid == file_uuid end)
  end

  # Advance the modal viewer by one step in the current page's file list.
  # Stops at the boundary (no wrap-around) so the user knows they hit the
  # edge instead of being silently teleported to the other end.
  defp step_viewer(socket, direction) do
    current = socket.assigns.viewer_file
    list = socket.assigns.uploaded_files

    with %{file_uuid: uuid} <- current,
         idx when is_integer(idx) <-
           Enum.find_index(list, fn f -> f.file_uuid == uuid end),
         next_idx <- if(direction == :prev, do: idx - 1, else: idx + 1),
         true <- next_idx >= 0 and next_idx < length(list),
         %{} = next_file <- Enum.at(list, next_idx) do
      open_viewer(socket, next_file)
    else
      _ -> socket
    end
  end

  # Opens / closes the modal viewer. The per-file content (canvas,
  # annotations, composer, sidebar with comments) lives in the
  # `MediaCanvasViewer` child LiveComponent embedded in the viewer
  # heex — it loads its own annotations on mount based on the file
  # we pass through `assigns[:file]`. MediaBrowser only owns the
  # modal open/close lifecycle and which file is currently shown.
  defp open_viewer(socket, nil), do: assign(socket, :viewer_file, nil)
  defp open_viewer(socket, %{file_uuid: _} = file), do: assign(socket, :viewer_file, file)

  defp navigate_to_folder(socket, folder_uuid) when folder_uuid in [nil, ""] do
    if controlled_mode?(socket) do
      send(self(), {__MODULE__, socket.assigns.id, {:navigate, %{folder: nil, q: "", page: 1}}})
      {:noreply, socket}
    else
      scope = scope_folder_id(socket)
      per_page = socket.assigns.per_page
      {files, total_count} = load_scoped_files(scope, 1, per_page, nil, "")

      {:noreply,
       socket
       |> assign(:file_view, nil)
       |> assign(:filter_trash, false)
       |> assign(:filter_orphaned, false)
       |> assign(:current_folder, nil)
       |> assign(:breadcrumbs, [])
       |> assign(:folders, Storage.list_folders(nil, scope))
       |> assign(:search_query, "")
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))}
    end
  end

  defp navigate_to_folder(socket, folder_uuid) do
    if controlled_mode?(socket) do
      send(
        self(),
        {__MODULE__, socket.assigns.id, {:navigate, %{folder: folder_uuid, q: "", page: 1}}}
      )

      {:noreply, socket}
    else
      scope = scope_folder_id(socket)

      {current_folder, actual_uuid} =
        if folder_uuid do
          folder = Storage.get_folder(folder_uuid)

          if folder && Storage.within_scope?(folder.uuid, scope) do
            {folder, folder.uuid}
          else
            {nil, nil}
          end
        else
          {nil, nil}
        end

      breadcrumbs = Storage.folder_breadcrumbs(actual_uuid, scope)
      folders = Storage.list_folders(actual_uuid, scope)
      per_page = socket.assigns.per_page
      {files, total_count} = load_scoped_files(scope, 1, per_page, actual_uuid, "")

      {:noreply,
       socket
       |> assign(:file_view, nil)
       |> assign(:filter_trash, false)
       |> assign(:filter_orphaned, false)
       |> assign(:current_folder, current_folder)
       |> assign(:breadcrumbs, breadcrumbs)
       |> assign(:folders, folders)
       |> assign(:search_query, "")
       |> assign(:uploaded_files, files)
       |> assign(:current_page, 1)
       |> assign(:total_count, total_count)
       |> assign(:total_pages, ceil(total_count / per_page))
       |> auto_expand_breadcrumbs(breadcrumbs)}
    end
  end

  # Refresh `@folders` (the children of the current navigation folder)
  # and `@folder_tree` (the sidebar tree). Called from handlers that
  # mutate folder rows — move, bulk move/delete — so the UI shows the
  # new structure without a manual refresh. File-only mutations skip
  # this since they don't change the folder set.
  defp reload_folder_lists(socket) do
    scope = scope_folder_id(socket)
    parent_uuid = current_folder_uuid(socket)
    filter_trash = socket.assigns[:filter_trash]
    file_view = socket.assigns[:file_view]

    folders =
      cond do
        filter_trash -> Storage.list_trashed_folders(scope)
        file_view == "all" -> []
        true -> Storage.list_folders(parent_uuid, scope)
      end

    socket
    |> assign(:folders, folders)
    |> assign(:folder_tree, Storage.list_folder_tree(scope))
  end

  # Combined trash count for the sidebar badge — files + folders.
  # Used wherever `:trash_count` is assigned so the badge reflects the
  # whole trash bucket, not just files.
  defp full_trash_count(scope) do
    Storage.count_trashed_files(scope) + Storage.count_trashed_folders(scope)
  end

  defp reload_current_page(socket) do
    folder_uuid = current_folder_uuid(socket)
    page = socket.assigns.current_page
    per_page = socket.assigns.per_page
    search = socket.assigns.search_query
    scope = scope_folder_id(socket)
    file_view = socket.assigns[:file_view]

    extra = list_extra(socket)

    {files, total_count} =
      cond do
        socket.assigns[:filter_trash] -> load_trashed_files(scope, page, per_page)
        socket.assigns.filter_orphaned -> load_orphaned_files(page, per_page)
        file_view == "all" -> load_all_view_files(scope, page, per_page, search, extra)
        true -> load_scoped_files(scope, page, per_page, folder_uuid, search, extra)
      end

    socket
    |> assign(:uploaded_files, files)
    |> assign(:total_count, total_count)
    |> assign(:total_pages, ceil(total_count / per_page))
    |> assign(:trash_count, full_trash_count(scope_folder_id(socket)))
  end

  # Open the move modal, seeding its directory tree's expansion from the
  # sidebar's current `:expanded_folders` so the picker opens showing the
  # same expanded directories the user already sees on the left. The
  # modal then tracks its own `:move_expanded` independently, so drilling
  # in the picker doesn't move the sidebar.
  defp open_move_modal(socket) do
    socket
    |> assign(:show_move_modal, true)
    |> assign(:move_expanded, socket.assigns.expanded_folders)
  end

  defp current_folder_uuid(socket) do
    socket.assigns.current_folder && socket.assigns.current_folder.uuid
  end

  # Resolve a folder already loaded in assigns (the current folder or the
  # listing) before falling back to a DB read — the description editor is
  # always opened from a folder that's on screen, so the re-query is redundant.
  defp loaded_folder(socket, folder_uuid) do
    current = socket.assigns[:current_folder]
    key = to_string(folder_uuid)

    found =
      if current && to_string(current.uuid) == key do
        current
      else
        Enum.find(socket.assigns[:folders] || [], &(to_string(&1.uuid) == key))
      end

    found || Storage.get_folder(folder_uuid)
  end

  # The folder's creator (the `user_uuid` owner) for the folder-header info
  # line — returns the user struct (used for the avatar + name) or nil.
  # Header media (creator user + cover/logo URLs) for the folder hero. Each
  # piece is gated on its matching `header_show_*` toggle so a folder whose
  # header hides that element costs no extra query / signed-URL build on
  # navigation (the hot path). The Edit-header editor loads the cover/logo URLs
  # unconditionally when it opens (see `start_edit_folder_header`) so its
  # previews still work with the toggles off.
  defp assign_folder_header_media(socket, %{} = folder) do
    creator = if folder.header_show_creator, do: folder_creator_user(folder)
    cover = if folder.header_show_background, do: folder_image_url(folder.cover_file_uuid)
    logo = if folder.header_show_icon, do: folder_image_url(folder.logo_file_uuid)

    socket
    |> assign(:folder_creator_user, creator)
    |> assign(:folder_creator_name, creator_label(creator))
    |> assign(:folder_cover_url, cover)
    |> assign(:folder_logo_url, logo)
  end

  defp assign_folder_header_media(socket, _no_folder) do
    socket
    |> assign(:folder_creator_user, nil)
    |> assign(:folder_creator_name, nil)
    |> assign(:folder_cover_url, nil)
    |> assign(:folder_logo_url, nil)
  end

  defp folder_creator_user(%{user_uuid: user_uuid}) when is_binary(user_uuid),
    do: Auth.get_user(user_uuid)

  defp folder_creator_user(_), do: nil

  # Display label for a creator — full name, falling back to email.
  defp creator_label(nil), do: nil
  defp creator_label(user), do: User.full_name(user) || user.email

  # Display URL for a folder header image (cover or logo) by file uuid, or nil.
  # Loads the referenced file and enriches it for its signed URLs.
  defp folder_image_url(uuid) when is_binary(uuid) do
    case Storage.get_file(uuid) do
      nil ->
        nil

      file ->
        case enrich_files([file]) do
          [%{urls: urls}] -> urls["original"] || urls |> Map.values() |> List.first()
          _ -> nil
        end
    end
  end

  defp folder_image_url(_), do: nil

  defp reset_folder_header_edit(socket) do
    socket
    |> assign(:editing_folder_header, nil)
    |> assign(:folder_header_name, "")
    |> assign(:folder_header_description, "")
  end

  defp save_folder_header(socket, folder, folder_uuid, scope, name, desc_value) do
    case Storage.update_folder(folder, %{name: name, description: desc_value}, scope) do
      {:ok, updated} ->
        parent_uuid = current_folder_uuid(socket)

        socket =
          socket
          |> reset_folder_header_edit()
          # Reload the listing + tree so any grid card / list row / sidebar
          # entry for this folder reflects the new name and description.
          |> assign(:folders, Storage.list_folders(parent_uuid, scope))
          |> assign(:folder_tree, Storage.list_folder_tree(scope))

        # Refresh the header's folder + breadcrumbs when editing the folder
        # we're currently inside, so the title, description and breadcrumb
        # trail all show the new name immediately.
        socket =
          if socket.assigns[:current_folder] &&
               to_string(socket.assigns.current_folder.uuid) == to_string(folder_uuid) do
            socket
            |> assign(:current_folder, updated)
            |> assign(:breadcrumbs, Storage.folder_breadcrumbs(folder_uuid, scope))
          else
            socket
          end

        {:noreply, socket}

      {:error, :out_of_scope} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot edit a folder outside the allowed scope"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save folder header"))}
    end
  end

  # Read the per-user grid/list preference from `custom_fields`, defaulting to
  # "grid". Tolerant of a missing/garbage value.
  defp load_user_view_mode(%{} = user) do
    case Auth.get_user_field(user, @media_view_mode_key) do
      mode when mode in ["grid", "list"] -> mode
      _ -> "grid"
    end
  end

  defp load_user_view_mode(_), do: "grid"

  # Persist the preference into a freshly-read `custom_fields` copy so a
  # concurrent change elsewhere isn't clobbered. Returns the updated user (or
  # the original on no-user / error) for the caller to re-assign.
  defp persist_user_view_mode(%{uuid: uuid} = user, mode) when is_binary(uuid) do
    fresh = Auth.get_user(uuid) || user
    merged = Map.put(fresh.custom_fields || %{}, @media_view_mode_key, mode)

    case Auth.update_user_custom_fields(fresh, merged) do
      {:ok, updated} -> updated
      {:error, _} -> user
    end
  end

  defp persist_user_view_mode(user, _mode), do: user

  # Sidebar tree state (expanded folder uuids + collapsed flag). Persisted in
  # user meta so the first server render already shows the tree open — no
  # collapsed→expanded jump after connect.
  defp load_user_expanded_folders(%{} = user) do
    case Auth.get_user_field(user, @media_expanded_folders_key) do
      list when is_list(list) -> list |> Enum.filter(&is_binary/1) |> MapSet.new()
      _ -> MapSet.new()
    end
  end

  defp load_user_expanded_folders(_), do: MapSet.new()

  defp load_user_sidebar_collapsed(%{} = user) do
    Auth.get_user_field(user, @media_sidebar_collapsed_key) == true
  end

  defp load_user_sidebar_collapsed(_), do: false

  # Write the current tree state into the user's custom_fields and re-assign the
  # updated user, mirroring `persist_user_view_mode/2`. We re-read the user fresh
  # from the DB first because `update_user_custom_fields` blind-writes the WHOLE
  # custom_fields map (no server-side merge) — using the in-socket copy would
  # clobber any custom_fields key written elsewhere since this socket loaded
  # (e.g. notification preferences saved on the settings page in another tab).
  defp persist_tree_state(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} = user when is_binary(uuid) ->
        fresh = Auth.get_user(uuid) || user

        merged =
          (fresh.custom_fields || %{})
          |> Map.put(
            @media_expanded_folders_key,
            MapSet.to_list(socket.assigns.expanded_folders)
          )
          |> Map.put(@media_sidebar_collapsed_key, socket.assigns.sidebar_collapsed)

        case Auth.update_user_custom_fields(fresh, merged) do
          {:ok, updated} -> assign(socket, :phoenix_kit_current_user, updated)
          {:error, _} -> socket
        end

      _ ->
        socket
    end
  end

  defp scope_folder_id(socket), do: socket.assigns[:scope_folder_id]

  defp controlled_mode?(socket), do: socket.assigns[:on_navigate] != nil

  # ──────────────────────────────────────────────────────────────
  # Data loading
  # ──────────────────────────────────────────────────────────────

  # Both trash and orphan views render through the same list / grid
  # markup, so delegate to `enrich_files/1` for the per-file display
  # shape (urls, folder_path, etc.). Previously these hand-rolled the
  # map and omitted `folder_path`, which the list-view Path column
  # reads unconditionally — opening the trash or orphan view in list
  # mode crashed with `KeyError`.
  defp load_trashed_files(scope, page, per_page) do
    offset = (page - 1) * per_page
    total_count = Storage.count_trashed_files(scope)
    files = Storage.list_trashed_files(scope, limit: per_page, offset: offset)
    {enrich_files(files), total_count}
  end

  defp load_orphaned_files(page, per_page) do
    offset = (page - 1) * per_page
    total_count = Storage.count_orphaned_files()
    files = Storage.find_orphaned_files(limit: per_page, offset: offset)
    {enrich_files(files), total_count}
  end

  # Loads files within scope with optional folder/search filters.
  # When scope=nil AND folder_uuid=nil AND search="", passes include_orphaned: true
  # to preserve the /admin/media root view behavior of showing only orphan files.
  defp load_scoped_files(scope, page, per_page, folder_uuid, search, extra \\ []) do
    at_real_root = is_nil(scope) and is_nil(folder_uuid) and search in [nil, ""]

    opts = extra ++ [page: page, per_page: per_page]

    opts =
      if folder_uuid && folder_uuid != "", do: [{:folder_uuid, folder_uuid} | opts], else: opts

    opts = if search && search != "", do: [{:search, search} | opts], else: opts
    opts = if at_real_root, do: [{:include_orphaned, true} | opts], else: opts

    case Storage.list_files_in_scope(scope, opts) do
      {:error, :out_of_scope} -> {[], 0}
      {files, total_count} -> {enrich_files(files), total_count}
    end
  end

  # Loads ALL files in the system (or within scope subtree when scope is set).
  # Used for the view=all flat listing. Does not apply folder or orphan filters.
  defp load_all_view_files(scope, page, per_page, search, extra \\ []) do
    opts = extra ++ [page: page, per_page: per_page]
    opts = if search && search != "", do: [{:search, search} | opts], else: opts

    case Storage.list_files_in_scope(scope, opts) do
      {:error, :out_of_scope} -> {[], 0}
      {files, total_count} -> {enrich_files(files), total_count}
    end
  end

  # Enriches raw Storage.File structs with URLs, folder paths, and display fields.
  defp enrich_files([]), do: []

  defp enrich_files(files) do
    repo = PhoenixKit.Config.get_repo()
    file_uuids = Enum.map(files, & &1.uuid)

    instances_by_file =
      from(fi in FileInstance, where: fi.file_uuid in ^file_uuids)
      |> repo.all()
      |> Enum.group_by(& &1.file_uuid)

    folder_uuids =
      files |> Enum.map(& &1.folder_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    folder_paths = Map.new(folder_uuids, fn fuuid -> {fuuid, breadcrumb_path(fuuid)} end)

    Enum.map(files, fn file ->
      instances = Map.get(instances_by_file, file.uuid, [])
      urls = generate_urls_from_instances(instances, file.uuid, file.mime_type)
      variant_widths = generate_widths_from_instances(instances)

      %{
        file_uuid: file.uuid,
        filename: file.original_file_name || file.file_name || "Unknown",
        original_filename: file.original_file_name,
        file_type: file.file_type,
        mime_type: file.mime_type,
        size: file.size || 0,
        status: file.status,
        inserted_at: file.inserted_at,
        # Width and height come straight from the File schema columns
        # populated by the variant generator on upload. `nil` is
        # possible for files uploaded before the variant generator ran
        # (or for non-image types); `build_viewer_canvas/2` falls back
        # to a 1000x1000 placeholder canvas in that case so the LV
        # doesn't crash.
        width: file.width,
        height: file.height,
        folder_path: Map.get(folder_paths, file.folder_uuid),
        urls: urls,
        variant_widths: variant_widths
      }
    end)
  end

  # ──────────────────────────────────────────────────────────────
  # Upload processing
  # ──────────────────────────────────────────────────────────────

  defp process_single_upload(socket, path, entry) do
    ext = Path.extname(entry.client_name) |> String.replace_leading(".", "")
    mime_type = entry.client_type || MIME.from_path(entry.client_name)
    file_type = determine_file_type(mime_type)
    current_user = socket.assigns[:phoenix_kit_current_user]
    user_uuid = if current_user, do: current_user.uuid, else: nil
    {:ok, stat} = Elixir.File.stat(path)
    file_size = stat.size
    file_hash = Auth.calculate_file_hash(path)

    case Storage.store_file_in_buckets(
           path,
           file_type,
           user_uuid,
           file_hash,
           ext,
           entry.client_name
         ) do
      {:ok, file, :duplicate} ->
        maybe_set_folder(file, socket)
        build_upload_result(file, entry, file_type, mime_type, file_size, true)

      {:ok, file} ->
        maybe_set_folder(file, socket)
        build_upload_result(file, entry, file_type, mime_type, file_size, false)

      {:error, reason} ->
        Logger.error("MediaBrowser upload error: #{inspect(reason)}")
        {:postpone, reason}
    end
  end

  defp build_upload_result(file, entry, file_type, mime_type, file_size, is_duplicate) do
    result = %{
      file_uuid: file.uuid,
      filename: entry.client_name,
      file_type: file_type,
      mime_type: mime_type,
      size: file_size,
      status: file.status,
      urls: %{}
    }

    result = if is_duplicate, do: Map.put(result, :duplicate, true), else: result
    {:ok, result}
  end

  defp build_upload_flash_message(uploaded_files) do
    error_count = Enum.count(uploaded_files, &match?({:postpone, _}, &1))
    successful_uploads = Enum.reject(uploaded_files, &match?({:postpone, _}, &1))

    duplicate_count =
      Enum.count(successful_uploads, fn
        {:ok, %{duplicate: true}} -> true
        _ -> false
      end)

    new_count = length(successful_uploads) - duplicate_count
    build_flash_from_counts(error_count, new_count, duplicate_count)
  end

  defp build_flash_from_counts(error_count, new_count, duplicate_count) do
    cond do
      all_failed?(error_count, new_count, duplicate_count) ->
        build_all_failed_message()

      partial_success?(error_count, new_count) ->
        build_partial_success_message(new_count, error_count)

      only_duplicates?(duplicate_count, new_count) ->
        build_only_duplicates_message(duplicate_count)

      new_files_only?(new_count, duplicate_count) ->
        build_new_files_only_message(new_count)

      new_and_duplicates?(new_count, duplicate_count) ->
        build_new_and_duplicates_message(new_count, duplicate_count)

      true ->
        {:info, gettext("Upload processed")}
    end
  end

  defp all_failed?(error_count, new_count, duplicate_count),
    do: error_count > 0 && new_count == 0 && duplicate_count == 0

  defp partial_success?(error_count, new_count), do: error_count > 0 && new_count > 0
  defp only_duplicates?(duplicate_count, new_count), do: duplicate_count > 0 && new_count == 0
  defp new_files_only?(new_count, duplicate_count), do: new_count > 0 && duplicate_count == 0
  defp new_and_duplicates?(new_count, duplicate_count), do: new_count > 0 && duplicate_count > 0

  defp build_all_failed_message do
    {:error,
     gettext(
       "Upload failed: No storage buckets configured. Please configure at least one storage bucket before uploading files."
     )}
  end

  defp build_partial_success_message(new_count, error_count) do
    uploaded = ngettext("%{count} file uploaded", "%{count} files uploaded", new_count)
    failed = ngettext("%{count} failed", "%{count} failed", error_count)

    {:warning,
     gettext(
       "Partially successful: %{uploaded}, %{failed} due to missing storage buckets.",
       uploaded: uploaded,
       failed: failed
     )}
  end

  defp build_only_duplicates_message(duplicate_count) do
    {:info,
     ngettext(
       "Already have %{count} duplicate file. No new files were added.",
       "Already have %{count} duplicate files. No new files were added.",
       duplicate_count
     )}
  end

  defp build_new_files_only_message(new_count) do
    {:info,
     ngettext(
       "Upload successful! %{count} new file processed",
       "Upload successful! %{count} new files processed",
       new_count
     )}
  end

  defp build_new_and_duplicates_message(new_count, duplicate_count) do
    added = ngettext("%{count} new file added", "%{count} new files added", new_count)

    duplicates =
      ngettext(
        "%{count} file was already uploaded",
        "%{count} files were already uploaded",
        duplicate_count
      )

    {:info,
     gettext("Upload successful! %{added}. %{duplicates}.",
       added: added,
       duplicates: duplicates
     )}
  end

  defp maybe_set_folder(file, socket) do
    scope = scope_folder_id(socket)
    folder_uuid = current_folder_uuid(socket) || scope

    cond do
      is_nil(folder_uuid) ->
        :ok

      is_nil(scope) or Storage.within_scope?(folder_uuid, scope) ->
        # The target folder is verified in-scope above, so passing nil as the
        # scope arg to move_file_to_folder/3 is safe — it skips the scope
        # re-check against the file's current folder (which is the real root
        # for a fresh upload and would fail the gate).
        Storage.move_file_to_folder(file.uuid, folder_uuid, nil)

      true ->
        Logger.warning(
          "MediaBrowser: refusing out-of-scope initial placement " <>
            "target=#{inspect(folder_uuid)} scope=#{inspect(scope)}"
        )

        :ok
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Style / icon helpers
  # ──────────────────────────────────────────────────────────────

  defp generate_urls_from_instances(instances, file_uuid, mime_type) do
    # For images, `put_dzi_url/3` adds a `"dzi"` manifest URL when tile
    # generation is enabled (shared with the detail page + lightbox so all
    # viewers wire deep zoom identically). Manifest + tiles are generated
    # lazily on first request; off → no `"dzi"` key, so Tessera just swaps
    # the medium/large/original rasters and never asks for tiles.
    instances
    |> Enum.reduce(%{}, fn instance, acc ->
      url = URLSigner.signed_url(file_uuid, instance.variant_name)
      Map.put(acc, instance.variant_name, url)
    end)
    |> URLSigner.put_dzi_url(file_uuid, mime_type)
  end

  # Builds a parallel map of `%{variant_name => width}` from the same
  # FileInstance rows that produce the URLs. Used downstream by
  # `tessera_sources/1` to decide which variants to surface as zoom
  # layers and where to set the swap thresholds.
  defp generate_widths_from_instances(instances) do
    Enum.reduce(instances, %{}, fn instance, acc ->
      case instance.width do
        nil -> acc
        w -> Map.put(acc, instance.variant_name, w)
      end
    end)
  end

  # NOTE: `tessera_sources/1` + `maybe_append_layer/4` were removed in
  # the Fresco 0.5 / Etcher 0.3 migration. Tessera 0.2 was OpenSeadragon-
  # backed (Fresco 0.1.x); Fresco 0.5 dropped OSD entirely, so the
  # Tessera layer no longer attaches. Restore once a Fresco 0.5-compatible
  # Tessera (or replacement) ships and `<Tessera.layer>` is wired back
  # into the file-zoom heex.

  defp determine_file_type(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> "image"
      String.starts_with?(mime_type, "video/") -> "video"
      # PDFs fall under "document" because the File schema's allowlist is
      # ["image", "video", "audio", "document", "archive", "other"] — returning
      # "pdf" here made every PDF upload fail the changeset validation silently.
      mime_type == "application/pdf" -> "document"
      true -> "document"
    end
  end

  # Build a "Folder1 / Folder2 / ..." path string from a folder uuid.
  # Returns nil at root so callers can render a `/` placeholder. Shared
  # by `enrich_files` (per-file folder_path) and `folder_list_path`
  # (single per-render path for the folder list view).
  defp breadcrumb_path(nil), do: nil

  defp breadcrumb_path(uuid) do
    case Storage.folder_breadcrumbs(uuid) do
      [] -> nil
      chain -> Enum.map_join(chain, " / ", & &1.name)
    end
  end

  # Path shown in the list-view folder rows' Path column. All folders
  # displayed share the same parent (children of @current_folder, or of
  # the scope when at the scoped root), so we compute it once per render
  # instead of recomputing per row — the previous `folder_parent_path/1`
  # did one breadcrumbs walk per folder, an N+1 over identical work.
  defp folder_list_path(nil, scope_id), do: breadcrumb_path(scope_id)
  defp folder_list_path(%{uuid: uuid}, _scope_id), do: breadcrumb_path(uuid)

  # Finder-style "untitled" / "untitled 1" / "untitled 2" naming for
  # quick folder creation. Looks at sibling folders in the same parent
  # and picks the first non-conflicting name. Gaps fill before
  # extending — if "untitled" and "untitled 5" exist, we create
  # "untitled 1". Active siblings only: the V122 partial index makes
  # trashed siblings invisible to the unique constraint, so
  # `list_folders/2`'s active-only view matches what the DB will
  # accept.
  defp next_untitled_name(parent_uuid, scope) do
    base = gettext("untitled")

    existing =
      parent_uuid
      |> Storage.list_folders(scope)
      |> Enum.map(& &1.name)
      |> MapSet.new()

    if MapSet.member?(existing, base) do
      n =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.find(fn n -> not MapSet.member?(existing, "#{base} #{n}") end)

      "#{base} #{n}"
    else
      base
    end
  end

  defp format_file_size(bytes), do: Format.bytes(bytes, base: 1000, decimals: 2)

  defp delete_selected_confirm(selected_files, selected_folders, filter_trash) do
    file_count = MapSet.size(selected_files)
    folder_count = MapSet.size(selected_folders)

    cond do
      filter_trash and file_count > 0 ->
        ngettext(
          "Permanently delete %{count} file? This cannot be undone.",
          "Permanently delete %{count} files? This cannot be undone.",
          file_count
        )

      folder_count > 0 and file_count > 0 ->
        files = ngettext("%{count} file", "%{count} files", file_count)
        folders = ngettext("%{count} folder", "%{count} folders", folder_count)

        gettext(
          "Delete %{files} (to trash) and %{folders}? Folder contents will be moved to parent.",
          files: files,
          folders: folders
        )

      folder_count > 0 ->
        ngettext(
          "Delete %{count} folder? Folder contents will be moved to parent.",
          "Delete %{count} folders? Folder contents will be moved to parent.",
          folder_count
        )

      true ->
        ngettext("Move %{count} file to trash?", "Move %{count} files to trash?", file_count)
    end
  end

  defp file_icon("image"), do: "hero-photo"
  defp file_icon("video"), do: "hero-play-circle"
  defp file_icon("pdf"), do: "hero-document-text"
  defp file_icon("document"), do: "hero-document"
  defp file_icon(_), do: "hero-document-arrow-down"

  defp auto_expand_breadcrumbs(socket, breadcrumbs) do
    ancestor_uuids = Enum.map(breadcrumbs, & &1.uuid)
    expanded = Enum.reduce(ancestor_uuids, socket.assigns.expanded_folders, &MapSet.put(&2, &1))
    assign(socket, :expanded_folders, expanded)
  end

  defp expand_sidebar_folder(socket, nil), do: socket

  defp expand_sidebar_folder(socket, folder_uuid) do
    assign(socket, :expanded_folders, MapSet.put(socket.assigns.expanded_folders, folder_uuid))
  end
end
