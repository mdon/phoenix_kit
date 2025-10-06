defmodule PhoenixKitWeb.Live.Modules.Entities.DataForm do
  @moduledoc """
  LiveView для создания и редактирования записей данных сущностей.
  Динамически генерирует формы на основе схемы entity.
  """
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities
  alias PhoenixKit.Entities.EntityData
  alias PhoenixKit.Entities.FormBuilder
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(%{"entity_slug" => entity_slug, "id" => id} = params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Edit mode with slug
    entity = Entities.get_entity_by_name(entity_slug)
    data_record = EntityData.get_data!(String.to_integer(id))
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("Edit Data"), locale)
  end

  def mount(%{"entity_id" => entity_id, "id" => id} = params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Edit mode with ID (backwards compat)
    entity = Entities.get_entity!(String.to_integer(entity_id))
    data_record = EntityData.get_data!(String.to_integer(id))
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("Edit Data"), locale)
  end

  def mount(%{"entity_slug" => entity_slug} = params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Create mode with slug
    entity = Entities.get_entity_by_name(entity_slug)
    data_record = %EntityData{entity_id: entity.id}
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("New Data"), locale)
  end

  def mount(%{"entity_id" => entity_id} = params, _session, socket) do
    # Set locale for LiveView process
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    # Create mode with ID (backwards compat)
    entity = Entities.get_entity!(String.to_integer(entity_id))
    data_record = %EntityData{entity_id: entity.id}
    changeset = EntityData.change(data_record)

    mount_data_form(socket, entity, data_record, changeset, gettext("New Data"), locale)
  end

  defp mount_data_form(socket, entity, data_record, changeset, page_title, locale) do
    project_title = Settings.get_setting("project_title", "PhoenixKit")
    current_user = socket.assigns[:phoenix_kit_current_user]

    # Validate entity is published
    unless entity.status == "published" do
      raise gettext("Entity '%{name}' is not published and cannot be used for data creation",
              name: entity.display_name
            )
    end

    # Ensure entity has field definitions
    if Enum.empty?(entity.fields_definition || []) do
      raise gettext("Entity '%{name}' has no field definitions", name: entity.display_name)
    end

    # For new records, set default status to "published" to avoid validation errors
    changeset =
      if is_nil(data_record.id) do
        Ecto.Changeset.put_change(changeset, :status, "published")
      else
        changeset
      end

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:page_title, page_title)
      |> assign(:project_title, project_title)
      |> assign(:entity, entity)
      |> assign(:data_record, data_record)
      |> assign(:changeset, changeset)
      |> assign(:current_user, current_user)

    {:ok, socket}
  end

  def handle_event("validate", %{"phoenix_kit_entity_data" => data_params}, socket) do
    # Extract the data field from params
    form_data = Map.get(data_params, "data", %{})

    # Add created_by for new records during validation
    data_params =
      if socket.assigns.data_record.id do
        data_params
      else
        Map.put(data_params, "created_by", socket.assigns.current_user.id)
      end

    # Auto-generate slug from title during creation (but not editing)
    data_params =
      if is_nil(socket.assigns.data_record.id) do
        # Only auto-generate if title changed and slug wasn't manually edited
        title = data_params["title"] || ""
        current_slug = data_params["slug"] || ""

        # Get previous values from changeset
        current_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
        previous_title = current_data.title || ""
        auto_generated_slug = generate_slug_from_title(previous_title)

        # If slug matches the auto-generated one or is empty, update it
        if current_slug == "" || current_slug == auto_generated_slug do
          Map.put(data_params, "slug", generate_slug_from_title(title))
        else
          # User manually edited the slug, don't overwrite it
          data_params
        end
      else
        # In edit mode, don't auto-generate
        data_params
      end

    # Validate the form data against entity field definitions
    case FormBuilder.validate_data(socket.assigns.entity, form_data) do
      {:ok, validated_data} ->
        # Create changeset with validated data
        params = Map.put(data_params, "data", validated_data)

        changeset =
          socket.assigns.data_record
          |> EntityData.change(params)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:changeset, changeset)

        {:noreply, socket}

      {:error, errors} ->
        # Add field validation errors to changeset
        changeset =
          socket.assigns.data_record
          |> EntityData.change(data_params)
          |> add_form_errors(errors)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:changeset, changeset)

        {:noreply, socket}
    end
  end

  def handle_event("save", %{"phoenix_kit_entity_data" => data_params}, socket) do
    # Extract the data field from params
    form_data = Map.get(data_params, "data", %{})

    # Validate the form data against entity field definitions
    case FormBuilder.validate_data(socket.assigns.entity, form_data) do
      {:ok, validated_data} ->
        # Add metadata to params
        params =
          data_params
          |> Map.put("data", validated_data)
          |> maybe_add_creator_id(socket.assigns.current_user, socket.assigns.data_record)

        case save_data_record(socket, params) do
          {:ok, _data_record} ->
            # Redirect to entity-specific data navigator after successful creation/update
            entity_name = socket.assigns.entity.name
            locale = socket.assigns[:current_locale] || "en"

            socket =
              socket
              |> put_flash(:info, gettext("Data record saved successfully"))
              |> push_navigate(
                to:
                  Routes.path("/admin/entities/#{entity_name}/data",
                    locale: locale
                  )
              )

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            socket =
              socket
              |> assign(:changeset, changeset)

            {:noreply, socket}
        end

      {:error, errors} ->
        # Add field validation errors to changeset
        changeset =
          socket.assigns.data_record
          |> EntityData.change(data_params)
          |> add_form_errors(errors)

        error_list =
          Enum.map_join(errors, "; ", fn {k, v} -> "#{k}: #{Enum.join(v, ", ")}" end)

        socket =
          socket
          |> assign(:changeset, changeset)
          |> put_flash(:error, gettext("Field validation errors: %{errors}", errors: error_list))

        {:noreply, socket}
    end
  end

  def handle_event("generate_slug", _params, socket) do
    changeset = socket.assigns.changeset

    # Get title from changeset (includes both changes and original data)
    title = Ecto.Changeset.get_field(changeset, :title) || ""

    # Don't generate if title is empty
    if title == "" do
      {:noreply, socket}
    else
      # Generate slug from title
      slug = generate_slug_from_title(title)

      # Get ALL current field values from the changeset
      # This includes both changed values and original struct values
      entity_id = Ecto.Changeset.get_field(changeset, :entity_id)
      status = Ecto.Changeset.get_field(changeset, :status) || "draft"
      data = Ecto.Changeset.get_field(changeset, :data) || %{}
      created_by = Ecto.Changeset.get_field(changeset, :created_by)

      # Debug logging
      require Logger
      Logger.debug("Generate slug - Title: #{inspect(title)}")
      Logger.debug("Generate slug - Current data: #{inspect(data)}")
      Logger.debug("Generate slug - Changeset changes: #{inspect(changeset.changes)}")

      # Build complete params map with ALL required fields
      params = %{
        "entity_id" => entity_id,
        "title" => title,
        "slug" => slug,
        "status" => status,
        "data" => data,
        "created_by" => created_by
      }

      Logger.debug("Generate slug - Final params: #{inspect(params)}")

      # Update changeset with generated slug while preserving all other fields
      changeset =
        socket.assigns.data_record
        |> EntityData.change(params)
        |> Map.put(:action, :validate)

      socket =
        socket
        |> assign(:changeset, changeset)

      {:noreply, socket}
    end
  end

  # Helper Functions

  defp save_data_record(socket, data_params) do
    if socket.assigns.data_record.id do
      EntityData.update(socket.assigns.data_record, data_params)
    else
      EntityData.create(data_params)
    end
  end

  defp maybe_add_creator_id(params, current_user, data_record) do
    if data_record.id do
      # Editing existing record - don't change creator
      params
    else
      # Creating new record - set creator
      Map.put(params, "created_by", current_user.id)
    end
  end

  defp add_form_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn {field_key, field_errors}, acc ->
      Enum.reduce(field_errors, acc, fn error, inner_acc ->
        Ecto.Changeset.add_error(inner_acc, :data, "#{field_key}: #{error}")
      end)
    end)
  end

  defp generate_slug_from_title(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp generate_slug_from_title(_), do: ""
end
