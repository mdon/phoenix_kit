defmodule PhoenixKitWeb.Users.MagicLinkRegistrationLive do
  @moduledoc """
  LiveView for magic link registration completion form.
  """

  use PhoenixKitWeb, :live_view

  alias PhoenixKit.ReferralCodes
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case MagicLinkRegistration.verify_registration_token(token) do
      {:ok, email} ->
        # Get referral codes configuration
        referral_codes_config = ReferralCodes.get_config()

        # Generate username suggestion from email
        suggested_username = User.generate_username_from_email(email)

        changeset =
          Auth.change_user_registration(%User{
            email: email,
            username: suggested_username
          })

        # Extract IP address for geolocation
        ip_address =
          case get_connect_info(socket, :peer_data) do
            %{address: {a, b, c, d}} -> "#{a}.#{b}.#{c}.#{d}"
            %{address: address} -> to_string(address)
            _ -> "unknown"
          end

        {:ok,
         socket
         |> assign(:page_title, "Complete Registration")
         |> assign(:token, token)
         |> assign(:email, email)
         |> assign(:ip_address, ip_address)
         |> assign(:referral_codes_enabled, referral_codes_config.enabled)
         |> assign(:referral_codes_required, referral_codes_config.required)
         |> assign(:referral_code, nil)
         |> assign(:referral_code_error, nil)
         |> assign(:trigger_submit, false)
         |> assign(:check_errors, false)
         |> assign_form(changeset)}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Registration link is invalid or has expired.")
         |> redirect(to: Routes.path("/users/register"))}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    case validate_referral_code(referral_code, socket) do
      {:ok, _} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: nil)

        changeset =
          %User{email: socket.assigns.email}
          |> Auth.change_user_registration(user_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}

      {:error, error_message} ->
        socket =
          socket
          |> assign(referral_code: referral_code)
          |> assign(referral_code_error: error_message)

        changeset =
          %User{email: socket.assigns.email}
          |> Auth.change_user_registration(user_params)
          |> Map.put(:action, :validate)

        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params} = params, socket) do
    referral_code = params["referral_code"]

    case validate_referral_code(referral_code, socket) do
      {:ok, _validated_code} ->
        # Add referral_code to user params
        user_params =
          if referral_code && String.trim(referral_code) != "" do
            Map.put(user_params, "referral_code", referral_code)
          else
            user_params
          end

        # Complete registration
        case MagicLinkRegistration.complete_registration(
               socket.assigns.token,
               user_params,
               socket.assigns.ip_address
             ) do
          {:ok, user} ->
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
      not socket.assigns.referral_codes_enabled ->
        {:ok, nil}

      socket.assigns.referral_codes_required and
          (is_nil(referral_code) or String.trim(referral_code) == "") ->
        {:error, "Referral code is required"}

      referral_code && String.trim(referral_code) != "" ->
        validate_referral_code_value(String.trim(referral_code))

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

          ReferralCodes.expired?(code) ->
            {:error, "This referral code has expired"}

          ReferralCodes.usage_limit_reached?(code) ->
            {:error, "This referral code has reached its usage limit"}

          true ->
            {:ok, code}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title={@page_title}
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh]">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-2">Complete Your Registration</h1>
            <p class="text-center text-base-content/60 text-sm mb-6">
              Email: <strong>{@email}</strong>
            </p>

            <.form
              for={@form}
              id="registration_completion_form"
              phx-submit="save"
              phx-change="validate"
              phx-trigger-action={@trigger_submit}
              action={Routes.path("/users/log-in?_action=registered")}
              method="post"
            >
              <%!-- Hidden email field for session controller --%>
              <input type="hidden" name="user[email]" value={@email} />

              <fieldset class="fieldset">
                <legend class="fieldset-legend sr-only">Account Information</legend>

                <div :if={@check_errors} class="alert alert-error text-sm mb-4">
                  <PhoenixKitWeb.Components.Core.Icons.icon_error_circle class="stroke-current shrink-0 h-6 w-6" />
                  <span>Oops, something went wrong! Please check the errors below.</span>
                </div>

                <%!-- Username Field --%>
                <div phx-feedback-for="user[username]">
                  <label class="label" for="user_username">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_user_profile class="w-4 h-4 mr-2" />
                      Username
                    </span>
                  </label>
                  <.input
                    field={@form[:username]}
                    type="text"
                    placeholder="Choose a unique username"
                    autocomplete="username"
                    class="transition-colors focus:input-primary"
                  />
                </div>

                <%!-- Password Field --%>
                <div phx-feedback-for="user[password]">
                  <label class="label" for="user_password">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_lock class="w-4 h-4 mr-2" /> Password
                    </span>
                  </label>
                  <.input
                    field={@form[:password]}
                    type="password"
                    placeholder="Choose a secure password"
                    autocomplete="new-password"
                    class="transition-colors focus:input-primary"
                    required
                  />
                </div>

                <%!-- First Name Field (optional) --%>
                <div phx-feedback-for="user[first_name]">
                  <label class="label" for="user_first_name">
                    <span class="label-text">First Name</span>
                  </label>
                  <.input
                    field={@form[:first_name]}
                    type="text"
                    placeholder="Your first name (optional)"
                    autocomplete="given-name"
                    class="transition-colors focus:input-primary"
                  />
                </div>

                <%!-- Last Name Field (optional) --%>
                <div phx-feedback-for="user[last_name]">
                  <label class="label" for="user_last_name">
                    <span class="label-text">Last Name</span>
                  </label>
                  <.input
                    field={@form[:last_name]}
                    type="text"
                    placeholder="Your last name (optional)"
                    autocomplete="family-name"
                    class="transition-colors focus:input-primary"
                  />
                </div>

                <%!-- Referral Code Field --%>
                <%= if @referral_codes_enabled do %>
                  <div phx-feedback-for="referral_code">
                    <.label for="referral_code">
                      Referral Code<%= if @referral_codes_required do %>
                        *
                      <% end %>
                    </.label>
                    <input
                      id="referral_code"
                      name="referral_code"
                      type="text"
                      class={[
                        "input input-bordered",
                        (@referral_code_error ||
                           (@check_errors && @referral_codes_required &&
                              (is_nil(@referral_code) || @referral_code == ""))) && "input-error"
                      ]}
                      placeholder="Enter your referral code"
                      value={@referral_code || ""}
                      required={@referral_codes_required}
                    />
                    <%= if @referral_code_error do %>
                      <.error>{@referral_code_error}</.error>
                    <% end %>
                  </div>
                <% end %>

                <button
                  type="submit"
                  phx-disable-with="Creating account..."
                  class="btn btn-primary w-full mt-4 transition-all hover:scale-[1.02] active:scale-[0.98]"
                >
                  <PhoenixKitWeb.Components.Core.Icons.icon_user_add class="w-5 h-5 mr-2" />
                  Complete Registration <span aria-hidden="true">→</span>
                </button>
              </fieldset>
            </.form>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
