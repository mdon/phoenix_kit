defmodule PhoenixKitWeb.Live.Modules.Pages.Pages do
  @moduledoc """
  LiveView for Pages file management interface.

  Provides tree-based navigation and file editing.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.FileOperations

  def mount(_params, _session, socket) do
    # Set locale
    locale = socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)

    # Check if module is enabled
    unless Pages.enabled?() do
      socket =
        socket
        |> put_flash(:error, "Pages module is not enabled")
        |> redirect(to: PhoenixKit.Utils.Routes.path("/admin/modules"))

      {:ok, socket}
    else
      # Initialize root directory
      root_path = Pages.root_path()

      # Load directory tree - handle errors gracefully
      items =
        case FileOperations.list_directory("/") do
          {:ok, items} -> items
          {:error, _reason} -> []
        end

      socket =
        socket
        |> assign(:page_title, "Pages")
        |> assign(:current_path, "/")
        |> assign(:items, items)
        # Root expanded by default
        |> assign(:expanded_folders, MapSet.new(["/"]))
        |> assign(:editing_file, nil)
        |> assign(:file_content, "")
        |> assign(:show_new_file_modal, false)
        |> assign(:show_new_folder_modal, false)
        |> assign(:new_item_name, "")
        |> assign(:project_title, PhoenixKit.Settings.get_setting("project_title", "PhoenixKit"))
        |> assign(:current_locale, locale)
        |> assign(:root_path, root_path)

      {:ok, socket}
    end
  end

  ## Event Handlers

  def handle_event("toggle_folder", %{"path" => path}, socket) do
    # Navigate into the folder
    case FileOperations.list_directory(path) do
      {:ok, items} ->
        socket =
          socket
          |> assign(:current_path, path)
          |> assign(:items, items)

        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to open folder: #{path}")
        {:noreply, socket}
    end
  end

  def handle_event("open_file", %{"path" => path}, socket) do
    case FileOperations.read_file(path) do
      {:ok, content} ->
        socket =
          socket
          |> assign(:editing_file, path)
          |> assign(:file_content, content)

        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to open file: #{path}")
        {:noreply, socket}
    end
  end

  def handle_event("close_editor", _params, socket) do
    socket =
      socket
      |> assign(:editing_file, nil)
      |> assign(:file_content, "")

    {:noreply, socket}
  end

  def handle_event("update_content", %{"value" => content}, socket) do
    socket = assign(socket, :file_content, content)
    {:noreply, socket}
  end

  def handle_event("save_file", _params, socket) do
    path = socket.assigns.editing_file
    content = socket.assigns.file_content

    case FileOperations.write_file(path, content) do
      :ok ->
        socket =
          socket
          |> assign(:editing_file, nil)
          |> assign(:file_content, "")
          |> put_flash(:info, "File saved: #{Path.basename(path)}")
          |> refresh_tree()

        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to save file")
        {:noreply, socket}
    end
  end

  def handle_event("show_new_file_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_file_modal, true)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("show_new_folder_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_folder_modal, true)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("close_new_file_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_file_modal, false)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("close_new_folder_modal", _params, socket) do
    socket =
      socket
      |> assign(:show_new_folder_modal, false)
      |> assign(:new_item_name, "")

    {:noreply, socket}
  end

  def handle_event("update_new_item_name", %{"name" => name}, socket) do
    socket = assign(socket, :new_item_name, name)
    {:noreply, socket}
  end

  def handle_event("create_file", _params, socket) do
    name = socket.assigns.new_item_name
    current_path = socket.assigns.current_path

    if name == "" do
      socket = put_flash(socket, :error, "File name cannot be empty")
      {:noreply, socket}
    else
      file_path = Path.join(current_path, name)

      # Check if anything with this exact name already exists
      if FileOperations.exists?(file_path) do
        socket = put_flash(socket, :error, "A file or folder named '#{name}' already exists")
        {:noreply, socket}
      else
        case FileOperations.write_file(file_path, "") do
          :ok ->
            socket =
              socket
              |> assign(:show_new_file_modal, false)
              |> assign(:new_item_name, "")
              |> assign(:editing_file, file_path)
              |> assign(:file_content, "")
              |> refresh_tree()
              |> put_flash(:info, "File created: #{name}")

            {:noreply, socket}

          {:error, _reason} ->
            socket = put_flash(socket, :error, "Failed to create file")
            {:noreply, socket}
        end
      end
    end
  end

  def handle_event("create_folder", _params, socket) do
    name = socket.assigns.new_item_name
    current_path = socket.assigns.current_path

    if name == "" do
      socket = put_flash(socket, :error, "Folder name cannot be empty")
      {:noreply, socket}
    else
      folder_path = Path.join(current_path, name)

      # Check if anything with this exact name already exists
      if FileOperations.exists?(folder_path) do
        socket = put_flash(socket, :error, "A file or folder named '#{name}' already exists")
        {:noreply, socket}
      else
        case FileOperations.create_directory(folder_path) do
          :ok ->
            socket =
              socket
              |> assign(:show_new_folder_modal, false)
              |> assign(:new_item_name, "")
              |> refresh_tree()
              |> put_flash(:info, "Folder created: #{name}")

            {:noreply, socket}

          {:error, _reason} ->
            socket = put_flash(socket, :error, "Failed to create folder")
            {:noreply, socket}
        end
      end
    end
  end

  def handle_event("navigate_to", %{"path" => path}, socket) do
    case FileOperations.list_directory(path) do
      {:ok, items} ->
        socket =
          socket
          |> assign(:current_path, path)
          |> assign(:items, items)

        {:noreply, socket}

      {:error, _reason} ->
        socket = put_flash(socket, :error, "Failed to navigate to: #{path}")
        {:noreply, socket}
    end
  end

  ## Private Helpers

  defp refresh_tree(socket) do
    case FileOperations.list_directory(socket.assigns.current_path) do
      {:ok, items} -> assign(socket, :items, items)
      {:error, _reason} -> socket
    end
  end
end
