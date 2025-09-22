defmodule PhoenixKitWeb.Users.SettingsLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Account Settings"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh]">
        <div class="w-full max-w-lg px-4">
          <div class="text-center mb-8">
            <div class="flex items-center justify-center mb-4">
              <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-12 h-12 text-primary" />
            </div>
            <h1 class="text-3xl font-bold mb-2">Account Settings</h1>
            <p class="text-base-content/60 text-sm">
              Manage your account email address and password settings
            </p>
          </div>

          <div class="space-y-8">
            <!-- Email Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Email Address</h2>
                    <p class="text-sm text-base-content/60">Change your account email address</p>
                  </div>
                </div>

                <.simple_form
                  for={@email_form}
                  id="email_form"
                  phx-submit="update_email"
                  phx-change="validate_email"
                >
                  <.input
                    field={@email_form[:email]}
                    type="email"
                    label="Email"
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@email_form[:current_password]}
                    name="current_password"
                    id="current_password_for_email"
                    type="password"
                    label="Current password"
                    value={@email_form_current_password}
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-5 h-5 mr-2" />
                      Change Email
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Profile Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Profile Information</h2>
                    <p class="text-sm text-base-content/60">Update your personal information and timezone preference</p>
                  </div>
                </div>

                <.simple_form
                  for={@profile_form}
                  id="profile_form"
                  phx-submit="update_profile"
                  phx-change="validate_profile"
                >
                  <.input
                    field={@profile_form[:first_name]}
                    type="text"
                    label="First Name"
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input field={@profile_form[:last_name]} type="text" label="Last Name">
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <div phx-hook="TimezoneDetector" id="timezone-detector">
                    <.input
                      field={@profile_form[:user_timezone]}
                      type="select"
                      label="Personal Timezone"
                      options={@timezone_options}
                    >
                      <:icon>
                        <PhoenixKitWeb.Components.Core.Icons.icon_clock class="w-4 h-4 mr-2" />
                      </:icon>
                    </.input>

                    <%!-- Timezone Mismatch Warning --%>
                    <%= if assigns[:timezone_mismatch_warning] do %>
                      <div class="alert alert-warning text-sm mt-2">
                        <PhoenixKitWeb.Components.Core.Icons.icon_warning class="stroke-current shrink-0 h-5 w-5" />
                        <div>
                          <div class="font-semibold">Timezone Mismatch Detected</div>
                          <div class="text-xs">
                            {@timezone_mismatch_warning}
                          </div>
                        </div>
                      </div>
                    <% end %>

                    <%!-- Browser Timezone Info --%>
                    <%= if assigns[:browser_timezone_name] do %>
                      <div class="text-xs text-base-content/60 mt-1">
                        Browser detected: {@browser_timezone_name} ({@browser_timezone_offset})
                      </div>
                    <% end %>

                    <%!-- Debug button for timezone detection --%>
                    <div class="mt-2">
                      <button
                        type="button"
                        class="btn btn-sm btn-outline"
                        onclick="detectAndStoreTimezone(); return false;"
                      >
                        🐛 Detect Browser Timezone (Debug)
                      </button>
                      <div class="text-xs text-base-content/60 mt-1">
                        Click if timezone detection isn't working automatically
                      </div>
                    </div>
                  </div>
                  <:actions>
                    <.button
                      phx-disable-with="Updating..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-5 h-5 mr-2" />
                      Update Profile
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Password Settings Card -->
            <div class="card bg-base-100 shadow-2xl">
              <div class="card-body">
                <div class="flex items-center mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-6 h-6 text-primary mr-3" />
                  <div>
                    <h2 class="text-xl font-bold">Password</h2>
                    <p class="text-sm text-base-content/60">Update your account password</p>
                  </div>
                </div>

                <.simple_form
                  for={@password_form}
                  id="password_form"
                  action={Routes.path("/users/log-in?_action=password_updated")}
                  method="post"
                  phx-change="validate_password"
                  phx-submit="update_password"
                  phx-trigger-action={@trigger_submit}
                >
                  <input
                    name={@password_form[:email].name}
                    type="hidden"
                    id="hidden_user_email"
                    value={@current_email}
                  />
                  <.input
                    field={@password_form[:password]}
                    type="password"
                    label="New password"
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@password_form[:password_confirmation]}
                    type="password"
                    label="Confirm new password"
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <.input
                    field={@password_form[:current_password]}
                    name="current_password"
                    type="password"
                    label="Current password"
                    id="current_password_for_password"
                    value={@current_password}
                    required
                  >
                    <:icon>
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" />
                    </:icon>
                  </.input>
                  <:actions>
                    <.button
                      phx-disable-with="Changing..."
                      class="btn-primary transition-all hover:scale-[1.02] active:scale-[0.98]"
                    >
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-5 h-5 mr-2" />
                      Change Password
                    </.button>
                  </:actions>
                </.simple_form>
              </div>
            </div>
            
    <!-- Development Mode Notice -->
            <div :if={show_dev_notice?()} class="alert alert-info">
              <PhoenixKitWeb.Components.Core.Icons.icon_info class="stroke-current shrink-0 h-6 w-6" />
              <span>
                Development mode: Check
                <.link href="/dev/mailbox" class="font-semibold underline">mailbox</.link>
                for confirmation emails
              </span>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>

    <script>
      // Simple timezone detection - detect once and store in form
      function detectAndStoreTimezone() {
        try {
          // Get browser timezone data
          const timezoneName = Intl.DateTimeFormat().resolvedOptions().timeZone;
          const now = new Date();
          const offsetMinutes = now.getTimezoneOffset();
          const offsetHours = Math.round(offsetMinutes / -60);
          const offsetString = offsetHours === 0 ? "0" :
            (offsetHours > 0 ? "+" + offsetHours : offsetHours.toString());

          // Store in global variables for easy access
          window.browserTimezone = {
            name: timezoneName,
            offset: offsetString
          };

          // Add hidden fields to the form
          const form = document.querySelector('#profile_form');
          if (form) {
            // Remove any existing timezone inputs first
            const existingInputs = form.querySelectorAll('input[name="browser_timezone_name"], input[name="browser_timezone_offset"]');
            existingInputs.forEach(input => input.remove());

            // Add new timezone inputs
            const nameInput = document.createElement('input');
            nameInput.type = 'hidden';
            nameInput.name = 'browser_timezone_name';
            nameInput.value = timezoneName;
            nameInput.id = 'browser_timezone_name_input';

            const offsetInput = document.createElement('input');
            offsetInput.type = 'hidden';
            offsetInput.name = 'browser_timezone_offset';
            offsetInput.value = offsetString;
            offsetInput.id = 'browser_timezone_offset_input';

            form.appendChild(nameInput);
            form.appendChild(offsetInput);

            // Trigger form validation to send data to LiveView
            const timezoneSelect = form.querySelector('select[name*="user_timezone"]');
            if (timezoneSelect) {
              const changeEvent = new Event('input', { bubbles: true });
              timezoneSelect.dispatchEvent(changeEvent);
            }

            return true;
          }
        } catch (error) {
          // Silent fail - timezone detection is not critical
        }

        return false;
      }

      // Detect timezone when page loads
      setTimeout(detectAndStoreTimezone, 500);
      setTimeout(detectAndStoreTimezone, 1500);

      // Re-detect when timezone dropdown changes
      document.addEventListener('change', function(event) {
        if (event.target.name && event.target.name.includes('user_timezone')) {
          setTimeout(detectAndStoreTimezone, 100);
        }
      });
    </script>
    """
  end

  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Auth.update_user_email(socket.assigns.phoenix_kit_current_user, token) do
        :ok ->
          put_flash(socket, :info, "Email changed successfully.")

        :error ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: Routes.path("/users/settings"))}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.phoenix_kit_current_user
    email_changeset = Auth.change_user_email(user)
    password_changeset = Auth.change_user_password(user)
    profile_changeset = Auth.change_user_profile(user)

    # Get timezone options from Settings module
    setting_options = Settings.get_setting_options()
    timezone_options = [{"Use System Default", nil} | setting_options["time_zone"]]

    socket =
      socket
      |> assign(:current_password, nil)
      |> assign(:email_form_current_password, nil)
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:profile_form, to_form(profile_changeset))
      |> assign(:timezone_options, timezone_options)
      |> assign(:browser_timezone_name, nil)
      |> assign(:browser_timezone_offset, nil)
      |> assign(:timezone_mismatch_warning, nil)
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  def handle_event("validate_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    email_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_email(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form, email_form_current_password: password)}
  end

  def handle_event("update_email", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.apply_user_email(user, password, user_params) do
      {:ok, applied_user} ->
        Auth.deliver_user_update_email_instructions(
          applied_user,
          user.email,
          &Routes.url("/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info) |> assign(email_form_current_password: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, :email_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params

    password_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_password(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form, current_password: password)}
  end

  def handle_event("update_password", params, socket) do
    %{"current_password" => password, "user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_password(user, password, user_params) do
      {:ok, user} ->
        password_form =
          user
          |> Auth.change_user_password(user_params)
          |> to_form()

        {:noreply, assign(socket, trigger_submit: true, password_form: password_form)}

      {:error, changeset} ->
        {:noreply, assign(socket, password_form: to_form(changeset))}
    end
  end

  def handle_event("validate_profile", params, socket) do
    %{"user" => user_params} = params

    # Check if browser timezone data is included in the form submission
    socket =
      case {params["browser_timezone_name"], params["browser_timezone_offset"]} do
        {name, offset} when is_binary(name) and is_binary(offset) ->
          socket
          |> assign(:browser_timezone_name, name)
          |> assign(:browser_timezone_offset, offset)
        _ ->
          socket
      end

    profile_form =
      socket.assigns.phoenix_kit_current_user
      |> Auth.change_user_profile(user_params)
      |> Map.put(:action, :validate)
      |> to_form()

    # Check for timezone mismatch when user changes timezone
    socket =
      socket
      |> assign(profile_form: profile_form)
      |> check_timezone_mismatch(user_params["user_timezone"])

    {:noreply, socket}
  end

  def handle_event("update_profile", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.phoenix_kit_current_user

    case Auth.update_user_profile(user, user_params) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Profile updated successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(Map.put(changeset, :action, :insert)))}
    end
  end


  def handle_event("use_browser_timezone", _params, socket) do
    browser_offset = socket.assigns.browser_timezone_offset

    if browser_offset do
      # Update the profile form with browser timezone
      user = socket.assigns.phoenix_kit_current_user
      updated_attrs = %{"user_timezone" => browser_offset}

      profile_form =
        user
        |> Auth.change_user_profile(updated_attrs)
        |> to_form()

      socket =
        socket
        |> assign(:profile_form, profile_form)
        |> assign(:timezone_mismatch_warning, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end



  # Check for timezone mismatch based on current form values
  defp check_timezone_mismatch(socket, selected_timezone) do
    browser_offset = socket.assigns[:browser_timezone_offset]
    browser_name = socket.assigns[:browser_timezone_name]

    # Get selected timezone from parameters or current form value
    user_timezone =
      selected_timezone ||
        get_in(socket.assigns.profile_form.params, ["user_timezone"]) ||
        socket.assigns.phoenix_kit_current_user.user_timezone

    case {browser_offset, user_timezone} do
      {nil, _} ->
        # No browser timezone detected, no warning
        assign(socket, :timezone_mismatch_warning, nil)

      {browser_tz, nil} when browser_tz != "0" ->
        # User selected "Use System Default" but browser is not UTC
        system_tz = Settings.get_setting("time_zone", "0")

        if browser_tz != system_tz do
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected 'Use System Default' which is #{format_timezone_offset(system_tz)}."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      {browser_tz, user_tz} when browser_tz != user_tz ->
        # Normalize user timezone for comparison (remove + if present, browser_tz has +)
        normalized_user_tz = String.replace(user_tz, "+", "")
        normalized_browser_tz = String.replace(browser_tz, "+", "")

        # Only show warning if they're actually different (not just formatting)
        if normalized_browser_tz != normalized_user_tz do
          # User selected specific timezone that doesn't match browser
          warning_msg =
            "Your browser timezone appears to be #{browser_name} (#{format_timezone_offset(browser_tz)}) " <>
              "but you selected #{format_timezone_offset(user_tz)}. Please verify this is correct."

          assign(socket, :timezone_mismatch_warning, warning_msg)
        else
          assign(socket, :timezone_mismatch_warning, nil)
        end

      _ ->
        # Timezones match or no significant difference
        assign(socket, :timezone_mismatch_warning, nil)
    end
  end

  # Format timezone offset for display
  defp format_timezone_offset(offset) do
    case offset do
      "0" -> "UTC+0"
      "+" <> _ -> "UTC" <> offset
      "-" <> _ -> "UTC" <> offset
      _ when is_binary(offset) ->
        # If it's a positive number without +, add the +
        case Integer.parse(offset) do
          {num, ""} when num > 0 -> "UTC+" <> offset
          {num, ""} when num < 0 -> "UTC" <> offset
          {0, ""} -> "UTC+0"
          _ -> "UTC" <> offset
        end
      _ -> "Unknown"
    end
  end

  defp show_dev_notice? do
    case Application.get_env(:phoenix_kit, PhoenixKit.Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end
end
