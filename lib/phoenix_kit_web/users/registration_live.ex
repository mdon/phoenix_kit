defmodule PhoenixKitWeb.Users.RegistrationLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.ReferralCodes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - Create account"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh] bg-base-200">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-6">{@project_title} Create account</h1>

            <.form
              for={@form}
              id="registration_form"
              phx-submit="save"
              phx-change="validate"
              phx-trigger-action={@trigger_submit}
              action="/phoenix_kit/users/log-in?_action=registered"
              method="post"
            >
              <fieldset class="fieldset">
                <legend class="fieldset-legend sr-only">Account Information</legend>

                <div :if={@check_errors} class="alert alert-error text-sm mb-4">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="stroke-current shrink-0 h-6 w-6"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
                    />
                  </svg>
                  <span>Oops, something went wrong! Please check the errors below.</span>
                </div>

                <label class="label" for="user_email">Email</label>
                <input
                  id="user_email"
                  name="user[email]"
                  type="email"
                  class="input input-bordered validator w-full"
                  placeholder="Enter your email address"
                  value={@form.params["email"] || ""}
                  pattern="^[\w\.-]+@[\w\.-]+\.[a-zA-Z]{2,}$"
                  title="Please enter a valid email address"
                  required
                />
                <p class="validator-hint">Please enter a valid email address</p>

                <%!-- Referral Code Field (shown when referral codes are enabled) --%>
                <%= if @referral_codes_enabled do %>
                  <label class="label" for="referral_code">
                    Referral Code
                    <%= if @referral_codes_required do %>
                      <span class="text-error">*</span>
                    <% else %>
                      <span class="text-sm text-base-content/60">(optional)</span>
                    <% end %>
                  </label>
                  <input
                    id="referral_code"
                    name="referral_code"
                    type="text"
                    class={"input input-bordered w-full #{if @referral_code_error, do: "input-error"}"}
                    placeholder="Enter your referral code"
                    value={@referral_code || ""}
                    required={@referral_codes_required}
                  />
                  <%= if @referral_code_error do %>
                    <p class="text-error text-sm mt-1">{@referral_code_error}</p>
                  <% end %>
                <% end %>

                <label class="label" for="user_password">Password</label>
                <input
                  id="user_password"
                  name="user[password]"
                  type="password"
                  class="input input-bordered validator w-full"
                  placeholder="Choose a secure password"
                  minlength="8"
                  title="Password must be at least 8 characters long"
                  required
                />
                <p class="validator-hint">Password must be at least 8 characters long</p>

                <button
                  type="submit"
                  phx-disable-with="Creating account..."
                  class="btn btn-primary w-full mt-4"
                >
                  Create account <span aria-hidden="true">→</span>
                </button>
              </fieldset>
            </.form>
            
    <!-- Login link -->
            <div class="text-center mt-4 text-sm">
              <span>Already have an account? </span>
              <.link
                navigate="/phoenix_kit/users/log-in"
                class="font-semibold text-primary hover:underline"
              >
                Sign in
              </.link>
            </div>
            
    <!-- Development Mode Notice -->
            <div :if={show_dev_notice?()} class="alert alert-info text-sm mt-4">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="stroke-current shrink-0 h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                >
                </path>
              </svg>
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
    """
  end

  def mount(_params, session, socket) do
    # Track anonymous visitor session
    if connected?(socket) do
      session_id = session["live_socket_id"] || generate_session_id()

      Presence.track_anonymous(session_id, %{
        connected_at: DateTime.utc_now(),
        ip_address: get_connect_info(socket, :peer_data) |> extract_ip_address(),
        user_agent: get_connect_info(socket, :user_agent),
        current_page: "/phoenix_kit/users/register"
      })
    end

    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    # Get referral codes configuration
    referral_codes_config = ReferralCodes.get_config()

    changeset = Auth.change_user_registration(%User{})

    socket =
      socket
      |> assign(trigger_submit: false, check_errors: false)
      |> assign(project_title: project_title)
      |> assign(referral_codes_enabled: referral_codes_config.enabled)
      |> assign(referral_codes_required: referral_codes_config.required)
      |> assign(referral_code: nil)
      |> assign(referral_code_error: nil)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    # Validate referral code if system is enabled
    case validate_referral_code(referral_code, socket) do
      {:ok, validated_code} ->
        case Auth.register_user(user_params) do
          {:ok, user} ->
            # Record referral code usage if provided and valid
            if validated_code do
              ReferralCodes.use_code(validated_code.code, user.id)
            end

            {:ok, _} =
              Auth.deliver_user_confirmation_instructions(
                user,
                &"/phoenix_kit/users/confirm/#{&1}"
              )

            changeset = Auth.change_user_registration(user)
            {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, socket |> assign(check_errors: true) |> assign_form(changeset)}
        end

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)
          |> assign(check_errors: true)

        {:noreply, socket}
    end
  end

  def handle_event("validate", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    # Validate referral code and update error state
    case validate_referral_code(referral_code, socket) do
      {:ok, _} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: nil)

        changeset = Auth.change_user_registration(%User{}, user_params)
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)

        changeset = Auth.change_user_registration(%User{}, user_params)
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
    end
  end

  defp validate_referral_code(referral_code, socket) do
    cond do
      # If referral codes are disabled, always allow registration
      not socket.assigns.referral_codes_enabled ->
        {:ok, nil}

      # If referral codes are required but none provided
      socket.assigns.referral_codes_required and
          (is_nil(referral_code) or String.trim(referral_code) == "") ->
        {:error, "Referral code is required"}

      # If referral code is provided, validate it
      referral_code && String.trim(referral_code) != "" ->
        validate_referral_code_value(String.trim(referral_code))

      # If referral codes are optional and none provided
      true ->
        {:ok, nil}
    end
  end

  defp validate_referral_code_value(code_string) do
    case ReferralCodes.get_code_by_string(code_string) do
      nil ->
        {:error, "Invalid referral code"}

      code ->
        cond do
          not code.status ->
            {:error, "This referral code is no longer active"}

          PhoenixKit.ReferralCodes.expired?(code) ->
            {:error, "This referral code has expired"}

          PhoenixKit.ReferralCodes.usage_limit_reached?(code) ->
            {:error, "This referral code has reached its usage limit"}

          true ->
            {:ok, code}
        end
    end
  end

  defp show_dev_notice? do
    case Application.get_env(:phoenix_kit, PhoenixKit.Mailer)[:adapter] do
      Swoosh.Adapters.Local -> true
      _ -> false
    end
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end

  defp extract_ip_address(nil), do: "unknown"
  defp extract_ip_address(%{address: {a, b, c, d}}), do: "#{a}.#{b}.#{c}.#{d}"
  defp extract_ip_address(%{address: address}), do: to_string(address)
  defp extract_ip_address(_), do: "unknown"
end
