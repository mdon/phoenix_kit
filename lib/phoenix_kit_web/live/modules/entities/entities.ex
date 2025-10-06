defmodule PhoenixKitWeb.Live.Modules.Entities.Entities do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities
  alias PhoenixKit.Settings

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    project_title = Settings.get_setting("project_title", "PhoenixKit")

    stats = Entities.get_system_stats()

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, gettext("Entities"))
      |> assign(:project_title, project_title)
      |> assign(:total_entities, stats.total_entities)
      |> assign(:active_entities, stats.active_entities)
      |> assign(:total_data_records, stats.total_data_records)
      |> assign(:selected_status, "all")
      |> assign(:search_term, "")
      |> assign(:view_mode, "table")

    {:ok, socket}
  end

  def handle_params(params, _url, socket) do
    status = params["status"] || socket.assigns.selected_status
    search_term = params["search"] || socket.assigns.search_term
    view_mode = params["view"] || "table"

    socket =
      socket
      |> assign(:selected_status, status)
      |> assign(:search_term, search_term)
      |> assign(:view_mode, view_mode)
      |> apply_filters()

    {:noreply, socket}
  end

  def handle_event("toggle_view_mode", %{"mode" => mode}, socket) do
    params = build_url_params(socket.assigns.selected_status, socket.assigns.search_term, mode)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      socket
      |> push_patch(to: PhoenixKit.Utils.Routes.path("/admin/entities?#{params}", locale: locale))

    {:noreply, socket}
  end

  def handle_event("filter_by_status", %{"status" => status}, socket) do
    params = build_url_params(status, socket.assigns.search_term, socket.assigns.view_mode)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      socket
      |> push_patch(to: PhoenixKit.Utils.Routes.path("/admin/entities?#{params}", locale: locale))

    {:noreply, socket}
  end

  def handle_event("search", %{"search" => %{"term" => term}}, socket) do
    params = build_url_params(socket.assigns.selected_status, term, socket.assigns.view_mode)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      socket
      |> push_patch(to: PhoenixKit.Utils.Routes.path("/admin/entities?#{params}", locale: locale))

    {:noreply, socket}
  end

  def handle_event("clear_filters", _params, socket) do
    params = build_url_params("all", "", socket.assigns.view_mode)
    locale = socket.assigns[:current_locale] || "en"

    socket =
      socket
      |> push_patch(to: PhoenixKit.Utils.Routes.path("/admin/entities?#{params}", locale: locale))

    {:noreply, socket}
  end

  def handle_event("archive_entity", %{"id" => id}, socket) do
    entity = Entities.get_entity!(String.to_integer(id))

    # Update entity status to archived
    case Entities.update_entity(entity, %{status: "archived"}) do
      {:ok, _entity} ->
        entities = Entities.list_entities()
        stats = Entities.get_system_stats()

        socket =
          socket
          |> assign(:entities, entities)
          |> assign(:total_entities, stats.total_entities)
          |> assign(:active_entities, stats.active_entities)
          |> assign(:total_data_records, stats.total_data_records)
          |> put_flash(
            :info,
            gettext("Entity '%{name}' archived successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to archive entity"))
        {:noreply, socket}
    end
  end

  def handle_event("restore_entity", %{"id" => id}, socket) do
    entity = Entities.get_entity!(String.to_integer(id))

    # Restore entity status to published
    case Entities.update_entity(entity, %{status: "published"}) do
      {:ok, _entity} ->
        entities = Entities.list_entities()
        stats = Entities.get_system_stats()

        socket =
          socket
          |> assign(:entities, entities)
          |> assign(:total_entities, stats.total_entities)
          |> assign(:active_entities, stats.active_entities)
          |> assign(:total_data_records, stats.total_data_records)
          |> put_flash(
            :info,
            gettext("Entity '%{name}' restored successfully", name: entity.display_name)
          )

        {:noreply, socket}

      {:error, _changeset} ->
        socket = put_flash(socket, :error, gettext("Failed to restore entity"))
        {:noreply, socket}
    end
  end

  # Helper Functions

  defp build_url_params(status, search_term, view_mode) do
    params = []

    params =
      if status && status != "all" do
        [{"status", status} | params]
      else
        params
      end

    params =
      if search_term && String.trim(search_term) != "" do
        [{"search", search_term} | params]
      else
        params
      end

    params =
      if view_mode && view_mode != "table" do
        [{"view", view_mode} | params]
      else
        params
      end

    URI.encode_query(params)
  end

  defp apply_filters(socket) do
    status = socket.assigns[:selected_status] || "all"
    search_term = socket.assigns[:search_term] || ""

    # Start with all entities
    entities = Entities.list_entities()

    # Apply status filter
    entities =
      if status != "all" do
        Enum.filter(entities, fn entity -> entity.status == status end)
      else
        entities
      end

    # Apply search filter
    entities =
      if String.trim(search_term) != "" do
        search_term_lower = String.downcase(search_term)

        Enum.filter(entities, fn entity ->
          name_match = String.contains?(String.downcase(entity.name || ""), search_term_lower)

          display_name_match =
            String.contains?(String.downcase(entity.display_name || ""), search_term_lower)

          name_match || display_name_match
        end)
      else
        entities
      end

    assign(socket, :entities, entities)
  end
end
