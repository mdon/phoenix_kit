defmodule PhoenixKitWeb.Live.EmailSystem.EmailTemplateEditorLive do
  @moduledoc """
  LiveView for creating and editing email templates in PhoenixKit admin panel.

  Provides a comprehensive template editor with live preview, variable management,
  test sending functionality, and template validation.

  ## Features

  - **Live Preview**: Real-time HTML and text preview with variable substitution
  - **Variable Management**: Define and validate template variables
  - **Template Validation**: Real-time validation of template content
  - **Test Send**: Send test emails using the template
  - **Version Control**: Track template versions and changes
  - **Syntax Highlighting**: Basic HTML syntax awareness

  ## Routes

  - `/admin/emails/templates/new` - Create new template
  - `/admin/emails/templates/:id/edit` - Edit existing template

  ## Permissions

  Access is restricted to users with admin or owner roles in PhoenixKit.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.EmailSystem.EmailTemplate
  alias PhoenixKit.EmailSystem.Templates
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  import PhoenixKitWeb.Components.Core.Icons, only: [icon_arrow_left: 1]

  ## --- Lifecycle Callbacks ---

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    socket =
      socket
      |> assign(:project_title, project_title)
      |> assign(:template, nil)
      |> assign(:mode, :new)
      |> assign(:loading, false)
      |> assign(:saving, false)
      |> assign(:changeset, EmailTemplate.changeset(%EmailTemplate{}, %{}))
      |> assign(:preview_mode, "html")
      |> assign(:show_test_modal, false)
      |> assign(:test_sending, false)
      |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})
      |> assign(:extracted_variables, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Templates.get_template(String.to_integer(id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Template not found")
         |> push_navigate(to: Routes.path("/admin/emails/templates"))}

      template ->
        changeset = EmailTemplate.changeset(template, %{})
        extracted_variables = EmailTemplate.extract_variables(template)

        socket =
          socket
          |> assign(:page_title, "Edit Template: #{template.display_name}")
          |> assign(:template, template)
          |> assign(:mode, :edit)
          |> assign(:changeset, changeset)
          |> assign(:extracted_variables, extracted_variables)

        {:noreply, socket}
    end
  end

  def handle_params(params, _url, socket) do
    # New template mode
    initial_attrs = %{
      name: params["name"] || "",
      display_name: params["display_name"] || "",
      category: params["category"] || "transactional",
      subject: "",
      html_body: default_html_template(),
      text_body: default_text_template(),
      status: "draft",
      variables: %{}
    }

    changeset = EmailTemplate.changeset(%EmailTemplate{}, initial_attrs)

    socket =
      socket
      |> assign(:page_title, "Create New Template")
      |> assign(:template, nil)
      |> assign(:mode, :new)
      |> assign(:changeset, changeset)
      |> assign(:extracted_variables, [])

    {:noreply, socket}
  end

  ## --- Event Handlers ---

  @impl true
  def handle_event("validate", %{"email_template" => template_params}, socket) do
    template = socket.assigns.template || %EmailTemplate{}

    # Extract variables from current content
    temp_template = %EmailTemplate{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = EmailTemplate.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    # Convert string keys to ensure consistency
    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    # Add any new extracted variables with smart descriptions
    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, smart_description_for_variable(var))
        end
      end)

    # Merge updated variables into template params
    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    changeset = EmailTemplate.changeset(template, template_params_with_vars)

    socket =
      socket
      |> assign(:changeset, %{changeset | action: :validate})
      |> assign(:extracted_variables, extracted_variables)

    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"email_template" => template_params}, socket) do
    socket = assign(socket, :saving, true)

    # Extract variables and auto-add them before saving
    temp_template = %EmailTemplate{
      subject: template_params["subject"] || "",
      html_body: template_params["html_body"] || "",
      text_body: template_params["text_body"] || ""
    }

    extracted_variables = EmailTemplate.extract_variables(temp_template)

    # Auto-add extracted variables with smart descriptions
    current_variables = template_params["variables"] || %{}

    current_variables =
      if is_map(current_variables) do
        current_variables
      else
        %{}
      end

    updated_variables =
      Enum.reduce(extracted_variables, current_variables, fn var, acc ->
        if Map.has_key?(acc, var) do
          acc
        else
          Map.put(acc, var, smart_description_for_variable(var))
        end
      end)

    template_params_with_vars = Map.put(template_params, "variables", updated_variables)

    case socket.assigns.mode do
      :new ->
        create_template(socket, template_params_with_vars)

      :edit ->
        update_template(socket, template_params_with_vars)
    end
  end

  @impl true
  def handle_event("switch_preview", %{"mode" => mode}, socket) when mode in ["html", "text"] do
    {:noreply, assign(socket, :preview_mode, mode)}
  end

  @impl true
  def handle_event("show_test_modal", _params, socket) do
    # Generate sample variables based on extracted variables
    sample_variables = generate_sample_variables(socket.assigns.extracted_variables)

    test_form = %{
      recipient: "",
      sample_variables: sample_variables,
      errors: %{}
    }

    {:noreply,
     socket
     |> assign(:show_test_modal, true)
     |> assign(:test_form, test_form)}
  end

  @impl true
  def handle_event("hide_test_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_test_modal, false)
     |> assign(:test_sending, false)
     |> assign(:test_form, %{recipient: "", sample_variables: %{}, errors: %{}})}
  end

  @impl true
  def handle_event("validate_test", params, socket) do
    test_params = params["test"] || %{}
    errors = validate_test_form(test_params)

    sample_variables =
      case test_params["sample_variables"] do
        nil -> socket.assigns.test_form.sample_variables
        vars -> vars
      end

    test_form = %{
      recipient: test_params["recipient"] || "",
      sample_variables: sample_variables,
      errors: errors
    }

    {:noreply, assign(socket, :test_form, test_form)}
  end

  @impl true
  def handle_event("send_test", params, socket) do
    test_params = params["test"] || %{}
    errors = validate_test_form(test_params)

    if map_size(errors) == 0 do
      socket = assign(socket, :test_sending, true)

      # Get current template data from changeset
      changeset_data = Ecto.Changeset.apply_changes(socket.assigns.changeset)
      sample_variables = test_params["sample_variables"] || %{}

      # Send test email
      send(self(), {:send_test_email, test_params["recipient"], changeset_data, sample_variables})

      {:noreply, socket}
    else
      test_form = %{
        recipient: test_params["recipient"] || "",
        sample_variables: test_params["sample_variables"] || %{},
        errors: errors
      }

      {:noreply, assign(socket, :test_form, test_form)}
    end
  end

  @impl true
  def handle_event(
        "update_variable_description",
        %{"name" => name, "value" => description},
        socket
      ) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.put(current_variables, name, description)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  @impl true
  def handle_event("remove_variable", %{"name" => name}, socket) do
    changeset = socket.assigns.changeset

    current_variables = Ecto.Changeset.get_field(changeset, :variables) || %{}
    updated_variables = Map.delete(current_variables, name)

    updated_changeset = Ecto.Changeset.put_change(changeset, :variables, updated_variables)

    {:noreply, assign(socket, :changeset, updated_changeset)}
  end

  ## --- Info Handlers ---

  @impl true
  def handle_info({:send_test_email, recipient, template_data, sample_variables}, socket) do
    # Create a temporary template for testing
    temp_template = %EmailTemplate{
      name: template_data.name || "test_template",
      subject: template_data.subject || "",
      html_body: template_data.html_body || "",
      text_body: template_data.text_body || ""
    }

    # Render template with sample variables
    rendered = Templates.render_template(temp_template, sample_variables)

    # Use PhoenixKit.Mailer to send test email
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.to(recipient)
      |> Swoosh.Email.from({"PhoenixKit Test", get_from_email()})
      |> Swoosh.Email.subject("[TEST] #{rendered.subject}")
      |> Swoosh.Email.html_body(rendered.html_body)
      |> Swoosh.Email.text_body(rendered.text_body)

    case PhoenixKit.Mailer.deliver_email(email,
           template_name: temp_template.name,
           campaign_id: "template_test"
         ) do
      {:ok, _email} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> assign(:show_test_modal, false)
         |> put_flash(:info, "Test email sent successfully to #{recipient}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:test_sending, false)
         |> put_flash(:error, "Failed to send test email: #{inspect(reason)}")}
    end
  rescue
    error ->
      {:noreply,
       socket
       |> assign(:test_sending, false)
       |> put_flash(:error, "Error sending test email: #{Exception.message(error)}")}
  end

  ## --- Template ---

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
      current_path={@url_path}
      project_title={@project_title}
    >
      <div class="container flex-col mx-auto px-4 py-6">
        <%!-- Header Section --%>
        <header class="w-full relative mb-6">
          <%!-- Back Button (Left aligned) --%>
          <.link
            navigate={Routes.path("/admin/emails/templates")}
            class="btn btn-outline btn-primary btn-sm absolute left-0 top-0 -mb-12"
          >
            <.icon_arrow_left /> Back to Templates
          </.link>

          <%!-- Title Section --%>
          <div class="text-center">
            <h1 class="text-4xl font-bold text-base-content mb-3">{@page_title}</h1>
            <%= if @mode == :edit and @template do %>
              <p class="text-lg text-base-content">
                Version {@template.version} • {String.capitalize(@template.category)} • {String.capitalize(
                  @template.status
                )}
              </p>
            <% else %>
              <p class="text-lg text-base-content">Create a new email template</p>
            <% end %>
          </div>
        </header>

        <%!-- Main Editor Grid --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <%!-- Editor Panel --%>
          <div class="space-y-6">
            <.form
              for={@changeset}
              as={:email_template}
              phx-change="validate"
              phx-submit="save"
              class="space-y-6"
            >
              <%!-- Basic Information --%>
              <div class="card bg-base-100 shadow-sm">
                <div class="card-body">
                  <h2 class="card-title text-lg mb-4">Basic Information</h2>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Template Name</span>
                      </label>
                      <input
                        type="text"
                        name="email_template[name]"
                        value={Ecto.Changeset.get_field(@changeset, :name)}
                        placeholder="welcome_email"
                        class="input input-bordered"
                        disabled={(@mode == :edit and @template) && @template.is_system}
                      />
                      <%= if error = Keyword.get(@changeset.errors, :name) do %>
                        <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                      <% end %>
                    </div>

                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Display Name</span>
                      </label>
                      <input
                        type="text"
                        name="email_template[display_name]"
                        value={Ecto.Changeset.get_field(@changeset, :display_name)}
                        placeholder="Welcome Email"
                        class="input input-bordered"
                      />
                      <%= if error = Keyword.get(@changeset.errors, :display_name) do %>
                        <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                      <% end %>
                    </div>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Slug</span>
                    </label>
                    <input
                      type="text"
                      name="email_template[slug]"
                      value={Ecto.Changeset.get_field(@changeset, :slug)}
                      placeholder="welcome-email"
                      class="input input-bordered"
                      disabled={(@mode == :edit and @template) && @template.is_system}
                    />
                    <%= if error = Keyword.get(@changeset.errors, :slug) do %>
                      <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                    <% end %>
                    <label class="label">
                      <span class="label-text-alt">
                        URL-friendly identifier (auto-generated from name if left empty)
                      </span>
                    </label>
                  </div>

                  <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Category</span>
                      </label>
                      <select
                        name="email_template[category]"
                        class="select select-bordered"
                        disabled={(@mode == :edit and @template) && @template.is_system}
                      >
                        <option
                          value="transactional"
                          selected={
                            Ecto.Changeset.get_field(@changeset, :category) == "transactional"
                          }
                        >
                          Transactional
                        </option>
                        <option
                          value="marketing"
                          selected={Ecto.Changeset.get_field(@changeset, :category) == "marketing"}
                        >
                          Marketing
                        </option>
                        <option
                          value="system"
                          selected={Ecto.Changeset.get_field(@changeset, :category) == "system"}
                        >
                          System
                        </option>
                      </select>
                      <%= if error = Keyword.get(@changeset.errors, :category) do %>
                        <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                      <% end %>
                    </div>

                    <div class="form-control">
                      <label class="label">
                        <span class="label-text">Status</span>
                      </label>
                      <select
                        name="email_template[status]"
                        class="select select-bordered"
                      >
                        <option
                          value="draft"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "draft"}
                        >
                          Draft
                        </option>
                        <option
                          value="active"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}
                        >
                          Active
                        </option>
                        <option
                          value="archived"
                          selected={Ecto.Changeset.get_field(@changeset, :status) == "archived"}
                        >
                          Archived
                        </option>
                      </select>
                      <%= if error = Keyword.get(@changeset.errors, :status) do %>
                        <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                      <% end %>
                    </div>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Description (Optional)</span>
                    </label>
                    <textarea
                      name="email_template[description]"
                      placeholder="Brief description of this template..."
                      class="textarea textarea-bordered"
                      rows="2"
                    ><%= Ecto.Changeset.get_field(@changeset, :description) %></textarea>
                    <%= if error = Keyword.get(@changeset.errors, :description) do %>
                      <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Email Content --%>
              <div class="card bg-base-100 shadow-sm">
                <div class="card-body">
                  <h2 class="card-title text-lg mb-4">Email Content</h2>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Subject Line</span>
                    </label>
                    <input
                      type="text"
                      name="email_template[subject]"
                      value={Ecto.Changeset.get_field(@changeset, :subject)}
                      placeholder="Welcome to {{app_name}}!"
                      class="input input-bordered"
                    />
                    <%= if error = Keyword.get(@changeset.errors, :subject) do %>
                      <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                    <% end %>
                    <label class="label">
                      <span class="label-text-alt">
                        Use {"{{variable}}"} syntax for dynamic content
                      </span>
                    </label>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">HTML Body</span>
                    </label>
                    <textarea
                      name="email_template[html_body]"
                      class="textarea textarea-bordered font-mono"
                      rows="12"
                      placeholder="<h1>Welcome {{user_name}}!</h1>"
                    ><%= Ecto.Changeset.get_field(@changeset, :html_body) %></textarea>
                    <%= if error = Keyword.get(@changeset.errors, :html_body) do %>
                      <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                    <% end %>
                  </div>

                  <div class="form-control">
                    <label class="label">
                      <span class="label-text">Text Body</span>
                    </label>
                    <textarea
                      name="email_template[text_body]"
                      class="textarea textarea-bordered font-mono"
                      rows="8"
                      placeholder="Welcome {{user_name}}!"
                    ><%= Ecto.Changeset.get_field(@changeset, :text_body) %></textarea>
                    <%= if error = Keyword.get(@changeset.errors, :text_body) do %>
                      <div class="text-sm text-error mt-1">{elem(error, 0)}</div>
                    <% end %>
                  </div>
                </div>
              </div>

              <%!-- Template Variables --%>
              <div class="card bg-base-100 shadow-sm">
                <div class="card-body">
                  <h2 class="card-title text-lg mb-4">Template Variables</h2>

                  <%= if length(@extracted_variables) > 0 do %>
                    <div class="alert alert-info mb-4">
                      <.icon name="hero-information-circle" class="w-5 h-5" />
                      <div>
                        <div class="font-semibold">
                          {length(@extracted_variables)} variable(s) detected and auto-added
                        </div>
                        <div class="text-sm mt-1">
                          Variables are automatically managed. Edit descriptions below or remove if not needed.
                        </div>
                      </div>
                    </div>

                    <div class="space-y-2">
                      <%= for {name, description} <- Ecto.Changeset.get_field(@changeset, :variables) || %{} do %>
                        <div class="flex items-start gap-2 p-3 bg-base-200 rounded">
                          <div class="flex-shrink-0 pt-2">
                            <span class="font-mono text-sm font-semibold">{"{{#{name}}}"}</span>
                          </div>
                          <div class="flex-1">
                            <input
                              type="text"
                              value={description}
                              placeholder="Description for this variable..."
                              class="input input-sm input-bordered w-full"
                              phx-change="update_variable_description"
                              phx-value-name={name}
                              phx-debounce="300"
                            />
                            <input
                              type="hidden"
                              name={"email_template[variables][#{name}]"}
                              value={description}
                            />
                          </div>
                          <button
                            type="button"
                            phx-click="remove_variable"
                            phx-value-name={name}
                            class="btn btn-xs btn-ghost text-error mt-1"
                            title="Remove variable"
                          >
                            <.icon name="hero-trash" class="w-4 h-4" />
                          </button>
                        </div>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="text-center py-8 text-base-content/60">
                      <.icon name="hero-code-bracket" class="w-12 h-12 mx-auto mb-3 opacity-30" />
                      <div class="font-medium mb-2">No variables found in template</div>
                      <div class="text-sm">
                        Use {"{{variable_name}}"} syntax in subject or body to add dynamic variables.
                      </div>
                      <div class="text-sm mt-1">
                        Example: {"{{user_name}}"}, {"{{email}}"}, {"{{url}}"}
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Action Buttons --%>
              <div class="flex justify-between">
                <div class="flex gap-2">
                  <%= if @mode == :edit do %>
                    <button
                      type="button"
                      phx-click="show_test_modal"
                      class="btn btn-outline btn-secondary"
                    >
                      <.icon name="hero-envelope" class="w-4 h-4 mr-1" /> Test Send
                    </button>
                  <% end %>
                </div>

                <div class="flex gap-2">
                  <.link
                    navigate={Routes.path("/admin/emails/templates")}
                    class="btn btn-ghost"
                  >
                    Cancel
                  </.link>
                  <button
                    type="submit"
                    class={[
                      "btn btn-primary",
                      @saving && "loading"
                    ]}
                    disabled={@saving}
                  >
                    <%= if @saving do %>
                      Saving...
                    <% else %>
                      {if @mode == :new, do: "Create Template", else: "Update Template"}
                    <% end %>
                  </button>
                </div>
              </div>
            </.form>
          </div>

          <%!-- Preview Panel --%>
          <div class="space-y-6">
            <div class="card bg-base-100 shadow-sm">
              <div class="card-body">
                <div class="flex items-center justify-between mb-4">
                  <h2 class="card-title text-lg">Live Preview</h2>
                  <div class="btn-group">
                    <button
                      type="button"
                      phx-click="switch_preview"
                      phx-value-mode="html"
                      class={[
                        "btn btn-sm",
                        @preview_mode == "html" && "btn-active"
                      ]}
                    >
                      HTML
                    </button>
                    <button
                      type="button"
                      phx-click="switch_preview"
                      phx-value-mode="text"
                      class={[
                        "btn btn-sm",
                        @preview_mode == "text" && "btn-active"
                      ]}
                    >
                      Text
                    </button>
                  </div>
                </div>

                <%!-- Subject Preview --%>
                <div class="mb-4">
                  <div class="text-sm font-medium text-base-content/70 mb-1">Subject:</div>
                  <div class="p-2 bg-base-200 rounded text-sm">
                    {Ecto.Changeset.get_field(@changeset, :subject) || "No subject"}
                  </div>
                </div>

                <%!-- Body Preview --%>
                <div class="border rounded-lg overflow-hidden">
                  <%= if @preview_mode == "html" do %>
                    <%= case Ecto.Changeset.get_field(@changeset, :html_body) do %>
                      <% html_content when is_binary(html_content) and html_content != "" -> %>
                        <iframe
                          id="email-preview-iframe"
                          sandbox="allow-same-origin"
                          class="w-full border-0 bg-white"
                          style="min-height: 400px; height: auto;"
                          srcdoc={html_content}
                          phx-update="ignore"
                          onload="this.style.height = (this.contentWindow.document.body.scrollHeight + 40) + 'px';"
                        >
                        </iframe>
                      <% _ -> %>
                        <div class="bg-white p-4 min-h-96">
                          <div class="text-gray-500 italic">No HTML content</div>
                        </div>
                    <% end %>
                  <% else %>
                    <div class="bg-gray-50 p-4 min-h-96 font-mono text-sm whitespace-pre-wrap">
                      <%= case Ecto.Changeset.get_field(@changeset, :text_body) do %>
                        <% nil -> %>
                          <div class="text-gray-500 italic not-italic">No text content</div>
                        <% "" -> %>
                          <div class="text-gray-500 italic not-italic">No text content</div>
                        <% text_content -> %>
                          {text_content}
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Test Email Modal --%>
        <div
          :if={@show_test_modal}
          class="modal modal-open"
          phx-click-away="hide_test_modal"
        >
          <div class="modal-box max-w-4xl">
            <h3 class="font-bold text-lg mb-4">Send Test Email</h3>

            <.form
              for={%{}}
              phx-submit="send_test"
              phx-change="validate_test"
              class="space-y-4"
            >
              <div class="form-control">
                <label class="label">
                  <span class="label-text">Recipient Email</span>
                </label>
                <input
                  type="email"
                  name="test[recipient]"
                  value={@test_form[:recipient] || ""}
                  placeholder="admin@example.com"
                  class={[
                    "input input-bordered w-full",
                    @test_form[:errors][:recipient] && "input-error"
                  ]}
                  required
                />
                <%= if @test_form[:errors][:recipient] do %>
                  <label class="label">
                    <span class="label-text-alt text-error">
                      {@test_form[:errors][:recipient]}
                    </span>
                  </label>
                <% end %>
              </div>

              <%= if length(@extracted_variables) > 0 do %>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text">Sample Variable Values</span>
                  </label>
                  <div class="space-y-2">
                    <%= for variable <- @extracted_variables do %>
                      <div class="grid grid-cols-3 gap-2 items-center">
                        <label class="text-sm font-mono">{"{{#{variable}}}"}</label>
                        <div class="col-span-2">
                          <input
                            type="text"
                            name={"test[sample_variables][#{variable}]"}
                            value={@test_form[:sample_variables][variable] || ""}
                            placeholder={"Sample #{variable}"}
                            class="input input-bordered input-sm w-full"
                          />
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <div class="alert alert-info">
                <.icon name="hero-information-circle" class="w-5 h-5" />
                <div class="text-sm">
                  This will send a test email using the current template content with the sample variables provided above.
                </div>
              </div>

              <div class="modal-action">
                <button
                  type="button"
                  phx-click="hide_test_modal"
                  class="btn btn-ghost"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class={[
                    "btn btn-primary",
                    @test_sending && "loading"
                  ]}
                  disabled={@test_sending}
                >
                  <%= if @test_sending do %>
                    Sending...
                  <% else %>
                    Send Test Email
                  <% end %>
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  ## --- Private Helper Functions ---

  defp create_template(socket, template_params) do
    case Templates.create_template(template_params) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> put_flash(:info, "Template '#{template.name}' created successfully")
         |> push_navigate(to: Routes.path("/admin/emails/templates"))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  defp update_template(socket, template_params) do
    case Templates.update_template(socket.assigns.template, template_params) do
      {:ok, template} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:template, template)
         |> put_flash(
           :info,
           "Template '#{template.name}' updated successfully (v#{template.version})"
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:saving, false)
         |> assign(:changeset, changeset)}
    end
  end

  defp smart_description_for_variable(variable) do
    descriptions = %{
      "user_name" => "User's display name",
      "user_email" => "User's email address",
      "email" => "User's email address",
      "url" => "Action URL or link",
      "confirmation_url" => "Email confirmation link",
      "reset_url" => "Password reset link",
      "magic_link_url" => "Magic link authentication URL",
      "update_url" => "Profile update URL",
      "timestamp" => "Current timestamp",
      "app_name" => "Application name",
      "company_name" => "Company or organization name",
      "support_email" => "Support contact email",
      "first_name" => "User's first name",
      "last_name" => "User's last name",
      "username" => "User's username",
      "token" => "Verification or authentication token",
      "code" => "Verification code",
      "expiry" => "Expiration date/time",
      "subject" => "Email subject line"
    }

    Map.get(descriptions, variable, "Custom variable: #{variable}")
  end

  defp generate_sample_variables(variables) do
    Enum.into(variables, %{}, fn variable ->
      {variable, get_sample_value_for_variable(variable)}
    end)
  end

  defp get_sample_value_for_variable(variable) do
    sample_data = %{
      "user_name" => "John Doe",
      "user_email" => "john@example.com",
      "email" => "john@example.com",
      "url" => "https://example.com/action",
      "confirmation_url" => "https://example.com/confirm",
      "reset_url" => "https://example.com/reset",
      "magic_link_url" => "https://example.com/magic",
      "update_url" => "https://example.com/update",
      "timestamp" => DateTime.utc_now() |> DateTime.to_string(),
      "app_name" => "PhoenixKit",
      "company_name" => "Your Company",
      "support_email" => "support@example.com"
    }

    Map.get(sample_data, variable, "Sample #{variable}")
  end

  defp validate_test_form(params) do
    errors = %{}

    # Validate recipient email
    errors =
      case String.trim(params["recipient"] || "") do
        "" ->
          Map.put(errors, :recipient, "Email address is required")

        email ->
          if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, email) do
            errors
          else
            Map.put(errors, :recipient, "Please enter a valid email address")
          end
      end

    errors
  end

  defp get_from_email do
    case PhoenixKit.Config.get(:from_email) do
      {:ok, email} -> email
      :not_found -> "noreply@localhost"
    end
  end

  defp default_html_template do
    """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>{{subject}}</title>
      <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; line-height: 1.6; color: #333; }
        .header { text-align: center; margin-bottom: 30px; }
        .button { display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: 500; }
        .button:hover { background-color: #2563eb; }
        .footer { margin-top: 30px; padding-top: 20px; border-top: 1px solid #e5e7eb; font-size: 14px; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Your email title here</h1>
        </div>

        <p>Hello {{user_name}},</p>

        <p>Your email content goes here...</p>

        <p style="text-align: center; margin: 30px 0;">
          <a href="{{url}}" class="button">Call to Action</a>
        </p>

        <div class="footer">
          <p>Thank you for using our service!</p>
        </div>
      </div>
    </body>
    </html>
    """
  end

  defp default_text_template do
    """
    Hello {{user_name}},

    Your email content goes here...

    {{url}}

    Thank you for using our service!
    """
  end
end
