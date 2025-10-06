defmodule PhoenixKitWeb.Live.Modules.Entities.EntityForm do
  @moduledoc """
  LiveView для создания и редактирования сущностей (entities).
  Управляет схемой сущности, полями и их валидацией.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.FieldTypes
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.HeroIcons
  alias PhoenixKit.Utils.Routes

  def mount(%{"id" => id} = params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Edit mode
    entity = Entities.get_entity!(String.to_integer(id))
    changeset = Entities.change_entity(entity)

    mount_entity_form(socket, entity, changeset, gettext("Edit Entity"), locale)
  end

  def mount(params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Create mode
    entity = %Entities{}
    changeset = Entities.change_entity(entity)

    mount_entity_form(socket, entity, changeset, gettext("New Entity"), locale)
  end

  defp mount_entity_form(socket, entity, changeset, page_title, locale) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Get current fields or initialize empty
    current_fields = entity.fields_definition || []

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)
      |> assign(:fields, current_fields)
      |> assign(:field_types, FieldTypes.for_picker())
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, %{})
      |> assign(:field_error, nil)
      |> assign(:show_icon_picker, false)
      |> assign(:icon_search, "")
      |> assign(:selected_category, "All")
      |> assign(:icon_categories, ["All" | HeroIcons.list_categories()])
      |> assign(:available_icons, HeroIcons.list_all_icons())

    {:ok, socket}
  end

  def handle_event("validate", %{"entities" => entity_params}, socket) do
    # Get all current data from the changeset (both changes and original data)
    current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

    # Convert struct to map and merge with incoming params
    existing_data =
      current_data
      |> Map.from_struct()
      |> Map.drop([:__meta__, :creator, :inserted_at, :updated_at])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Merge existing data with new params (new params override existing)
    entity_params = Map.merge(existing_data, entity_params)

    # Auto-generate slug from display_name during creation (but not editing)
    entity_params =
      if is_nil(socket.assigns.entity.id) do
        # Only auto-generate if display_name changed and slug wasn't manually edited
        display_name = entity_params["display_name"] || ""
        current_slug = entity_params["name"] || ""

        # Check if the current slug was auto-generated from the previous display_name
        previous_display_name = existing_data["display_name"] || ""
        auto_generated_slug = generate_slug_from_name(previous_display_name)

        # If slug matches the auto-generated one or is empty, update it
        if current_slug == "" || current_slug == auto_generated_slug do
          Map.put(entity_params, "name", generate_slug_from_name(display_name))
        else
          # User manually edited the slug, don't overwrite it
          entity_params
        end
      else
        # In edit mode, don't auto-generate
        entity_params
      end

    # Add fields_definition to params for validation
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    # Add created_by for new entities during validation so changeset can be valid
    entity_params =
      if socket.assigns.entity.id do
        entity_params
      else
        Map.put(entity_params, "created_by", socket.assigns.current_user.id)
      end

    changeset =
      socket.assigns.entity
      |> Entities.change_entity(entity_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"entities" => entity_params}, socket) do
    # Add current fields to entity params
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    # Add created_by for new entities
    entity_params =
      if socket.assigns.entity.id do
        entity_params
      else
        Map.put(entity_params, "created_by", socket.assigns.current_user.id)
      end

    case save_entity(socket, entity_params) do
      {:ok, _entity} ->
        locale = socket.assigns[:current_locale] || "en"

        socket =
          socket
          |> put_flash(:info, gettext("Entity saved successfully"))
          |> push_navigate(to: Routes.path("/admin/entities", locale: locale))

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  # Icon Picker Events

  def handle_event("open_icon_picker", _params, socket) do
    {:noreply, assign(socket, :show_icon_picker, true)}
  end

  def handle_event("close_icon_picker", _params, socket) do
    {:noreply, assign(socket, show_icon_picker: false, icon_search: "", selected_category: "All")}
  end

  def handle_event("stop_propagation", _params, socket) do
    # This event does nothing - it just prevents the click from propagating to the backdrop
    {:noreply, socket}
  end

  def handle_event("generate_entity_slug", _params, socket) do
    changeset = socket.assigns.changeset

    # Get display_name from changeset
    display_name = Ecto.Changeset.get_field(changeset, :display_name) || ""

    # Don't generate if display_name is empty
    if display_name == "" do
      {:noreply, socket}
    else
      # Generate slug from display_name (snake_case)
      slug = generate_slug_from_name(display_name)

      # Update changeset with generated slug while preserving all other data
      changeset = update_changeset_field(socket, %{"name" => slug})

      {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  def handle_event("select_icon", %{"icon" => icon_name}, socket) do
    # Update the changeset with the selected icon while preserving all other data
    changeset = update_changeset_field(socket, %{"icon" => icon_name})

    socket =
      socket
      |> assign(:changeset, changeset)
      |> assign(:show_icon_picker, false)
      |> assign(:icon_search, "")
      |> assign(:selected_category, "All")

    {:noreply, socket}
  end

  def handle_event("clear_icon", _params, socket) do
    # Clear the icon field while preserving all other data
    changeset = update_changeset_field(socket, %{"icon" => nil})

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("search_icons", %{"search" => search_term}, socket) do
    filtered_icons =
      if String.trim(search_term) == "" do
        if socket.assigns.selected_category == "All" do
          HeroIcons.list_all_icons()
        else
          HeroIcons.list_icons_by_category()[socket.assigns.selected_category] || []
        end
      else
        HeroIcons.search_icons(search_term)
      end

    socket =
      socket
      |> assign(:icon_search, search_term)
      |> assign(:available_icons, filtered_icons)

    {:noreply, socket}
  end

  def handle_event("filter_by_category", %{"category" => category}, socket) do
    filtered_icons =
      if category == "All" do
        HeroIcons.list_all_icons()
      else
        HeroIcons.list_icons_by_category()[category] || []
      end

    socket =
      socket
      |> assign(:selected_category, category)
      |> assign(:available_icons, filtered_icons)
      |> assign(:icon_search, "")

    {:noreply, socket}
  end

  # Field Management Events

  def handle_event("add_field", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, true)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, %{
        "type" => "text",
        "key" => "",
        "label" => "",
        "required" => false,
        "default" => "",
        "options" => []
      })
      |> assign(:field_error, nil)

    {:noreply, socket}
  end

  def handle_event("edit_field", %{"index" => index}, socket) do
    index = String.to_integer(index)
    field = Enum.at(socket.assigns.fields, index)

    socket =
      socket
      |> assign(:show_field_form, true)
      |> assign(:editing_field_index, index)
      |> assign(:field_form, field || %{})
      |> assign(:field_error, nil)

    {:noreply, socket}
  end

  def handle_event("cancel_field", _params, socket) do
    socket =
      socket
      |> assign(:show_field_form, false)
      |> assign(:editing_field_index, nil)
      |> assign(:field_form, %{})
      |> assign(:field_error, nil)

    {:noreply, socket}
  end

  def handle_event("save_field", %{"field" => field_params}, socket) do
    # Merge field_form state with submitted params
    field_form = socket.assigns.field_form || %{}
    merged_params = Map.merge(field_form, field_params)

    # Sanitize options
    merged_params = sanitize_field_options(merged_params)

    # Validate and save
    case validate_and_save_field(merged_params, socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, error_message, socket} -> {:noreply, assign(socket, :field_error, error_message)}
    end
  end

  def handle_event("delete_field", %{"index" => index}, socket) do
    index = String.to_integer(index)
    fields = List.delete_at(socket.assigns.fields, index)

    socket = assign(socket, :fields, fields)
    {:noreply, socket}
  end

  def handle_event("move_field_up", %{"index" => index}, socket) do
    index = String.to_integer(index)

    if index > 0 do
      fields = move_field(socket.assigns.fields, index, index - 1)
      socket = assign(socket, :fields, fields)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move_field_down", %{"index" => index}, socket) do
    index = String.to_integer(index)

    if index < length(socket.assigns.fields) - 1 do
      fields = move_field(socket.assigns.fields, index, index + 1)
      socket = assign(socket, :fields, fields)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_field_form", %{"field" => field_params}, socket) do
    # Update field form with live changes
    current_form = socket.assigns.field_form
    updated_form = Map.merge(current_form, field_params)

    # Auto-generate key from label when adding new field (not editing)
    updated_form =
      if is_nil(socket.assigns.editing_field_index) do
        # Only auto-generate if label changed and key wasn't manually edited
        label = updated_form["label"] || ""
        current_key = updated_form["key"] || ""

        # Check if the current key was auto-generated from the previous label
        previous_label = current_form["label"] || ""
        auto_generated_key = generate_slug_from_name(previous_label)

        # If key matches the auto-generated one or is empty, update it
        if current_key == "" || current_key == auto_generated_key do
          Map.put(updated_form, "key", generate_slug_from_name(label))
        else
          # User manually edited the key, don't overwrite it
          updated_form
        end
      else
        # In edit mode, don't auto-generate
        updated_form
      end

    socket =
      socket
      |> assign(:field_form, updated_form)
      # Clear error when user makes changes
      |> assign(:field_error, nil)

    {:noreply, socket}
  end

  def handle_event("add_option", _params, socket) do
    current_options = Map.get(socket.assigns.field_form, "options", [])
    updated_options = current_options ++ [""]

    field_form = Map.put(socket.assigns.field_form, "options", updated_options)
    socket = assign(socket, :field_form, field_form)

    {:noreply, socket}
  end

  def handle_event("remove_option", %{"index" => index}, socket) do
    index = String.to_integer(index)
    current_options = Map.get(socket.assigns.field_form, "options", [])
    updated_options = List.delete_at(current_options, index)

    field_form = Map.put(socket.assigns.field_form, "options", updated_options)
    socket = assign(socket, :field_form, field_form)

    {:noreply, socket}
  end

  def handle_event("update_option", %{"index" => index, "value" => value}, socket) do
    index = String.to_integer(index)
    current_options = Map.get(socket.assigns.field_form, "options", [])
    updated_options = List.replace_at(current_options, index, value)

    field_form = Map.put(socket.assigns.field_form, "options", updated_options)
    socket = assign(socket, :field_form, field_form)

    {:noreply, socket}
  end

  def handle_event("generate_field_key", _params, socket) do
    # Get label from field form
    label = Map.get(socket.assigns.field_form, "label", "")

    # Don't generate if label is empty
    if label == "" do
      {:noreply, socket}
    else
      # Generate key from label (snake_case)
      key = generate_slug_from_name(label)

      # Update field form with generated key
      field_form = Map.put(socket.assigns.field_form, "key", key)
      socket = assign(socket, :field_form, field_form)

      {:noreply, socket}
    end
  end

  # Helper Functions

  defp save_entity(socket, entity_params) do
    if socket.assigns.entity.id do
      Entities.update_entity(socket.assigns.entity, entity_params)
    else
      Entities.create_entity(entity_params)
    end
  end

  defp move_field(fields, from_index, to_index) do
    field = Enum.at(fields, from_index)

    fields
    |> List.delete_at(from_index)
    |> List.insert_at(to_index, field)
  end

  defp validate_unique_field_key(field_params, existing_fields, editing_index) do
    new_key = field_params["key"]

    duplicate? =
      existing_fields
      |> Enum.with_index()
      |> Enum.any?(fn {field, index} ->
        field["key"] == new_key && index != editing_index
      end)

    if duplicate? do
      {:error,
       gettext("Field key '%{key}' already exists. Please use a unique key.", key: new_key)}
    else
      :ok
    end
  end

  defp update_changeset_field(socket, new_params) do
    # Get all current data from the changeset (both changes and original data)
    current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)

    # Convert struct to map
    existing_data =
      current_data
      |> Map.from_struct()
      |> Map.drop([:__meta__, :creator, :inserted_at, :updated_at])
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Merge existing data with new params (new params override existing)
    entity_params = Map.merge(existing_data, new_params)

    # Add fields_definition
    entity_params = Map.put(entity_params, "fields_definition", socket.assigns.fields)

    # Add created_by for new entities
    entity_params =
      if socket.assigns.entity.id do
        entity_params
      else
        Map.put(entity_params, "created_by", socket.assigns.current_user.id)
      end

    socket.assigns.entity
    |> Entities.change_entity(entity_params)
    |> Map.put(:action, :validate)
  end

  # Field Save Helper Functions

  defp sanitize_field_options(merged_params) do
    sanitized_options =
      merged_params
      |> Map.get("options", [])
      |> Enum.reject(&(&1 in [nil, ""] || String.trim(to_string(&1)) == ""))

    Map.put(merged_params, "options", sanitized_options)
  end

  defp validate_and_save_field(merged_params, socket) do
    with :ok <- validate_field_type_requirements(merged_params),
         :ok <-
           validate_unique_field_key(
             merged_params,
             socket.assigns.fields,
             socket.assigns.editing_field_index
           ),
         {:ok, validated_field} <- FieldTypes.validate_field(merged_params) do
      fields = update_fields_list(validated_field, socket)
      socket = reset_field_form_state(socket, fields)
      {:ok, socket}
    else
      {:error, error_message} -> {:error, error_message, socket}
    end
  end

  defp validate_field_type_requirements(merged_params) do
    field_type = merged_params["type"]
    sanitized_options = Map.get(merged_params, "options", [])

    cond do
      field_type in ["select", "radio", "checkbox"] and sanitized_options == [] ->
        {:error, gettext("Field type '%{type}' requires at least one option", type: field_type)}

      field_type == "relation" and merged_params["target_entity"] in [nil, ""] ->
        {:error, gettext("Relation field requires a target entity")}

      true ->
        :ok
    end
  end

  defp update_fields_list(validated_field, socket) do
    case socket.assigns.editing_field_index do
      nil ->
        # Adding new field
        socket.assigns.fields ++ [validated_field]

      index ->
        # Editing existing field
        List.replace_at(socket.assigns.fields, index, validated_field)
    end
  end

  defp reset_field_form_state(socket, fields) do
    socket
    |> assign(:fields, fields)
    |> assign(:show_field_form, false)
    |> assign(:editing_field_index, nil)
    |> assign(:field_form, %{})
    |> assign(:field_error, nil)
  end

  # Template Helper Functions

  def field_type_label("text"), do: gettext("Text")
  def field_type_label("textarea"), do: gettext("Text Area")
  def field_type_label("email"), do: gettext("Email")
  def field_type_label("url"), do: gettext("URL")
  def field_type_label("rich_text"), do: gettext("Rich Text Editor")
  def field_type_label("number"), do: gettext("Number")
  def field_type_label("boolean"), do: gettext("Boolean")
  def field_type_label("date"), do: gettext("Date")
  def field_type_label("select"), do: gettext("Select Dropdown")
  def field_type_label("radio"), do: gettext("Radio Buttons")
  def field_type_label("checkbox"), do: gettext("Checkboxes")

  def field_type_label(type_name) do
    case FieldTypes.get_type(type_name) do
      nil -> type_name
      type_info -> type_info.label
    end
  end

  def field_category_label(:basic), do: gettext("Basic")
  def field_category_label(:numeric), do: gettext("Numeric")
  def field_category_label(:boolean), do: gettext("Boolean")
  def field_category_label(:datetime), do: gettext("Date & Time")
  def field_category_label(:choice), do: gettext("Choice")
  def field_category_label(other), do: to_string(other)

  def field_type_icon(type_name) do
    case FieldTypes.get_type(type_name) do
      nil -> "hero-question-mark-circle"
      type_info -> type_info.icon
    end
  end

  def requires_options?(type_name) do
    FieldTypes.requires_options?(type_name)
  end

  def icon_category_label("All"), do: gettext("All")
  def icon_category_label("General"), do: gettext("General")
  def icon_category_label("Content"), do: gettext("Content")
  def icon_category_label("Actions"), do: gettext("Actions")
  def icon_category_label("Navigation"), do: gettext("Navigation")
  def icon_category_label("Communication"), do: gettext("Communication")
  def icon_category_label("Users"), do: gettext("Users")
  def icon_category_label("Business"), do: gettext("Business")
  def icon_category_label("Interface"), do: gettext("Interface")
  def icon_category_label("Tech"), do: gettext("Tech")
  def icon_category_label("Status"), do: gettext("Status")
  def icon_category_label(category), do: category

  defp generate_slug_from_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/-+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp generate_slug_from_name(_), do: ""
end
