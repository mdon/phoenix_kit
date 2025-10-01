defmodule PhoenixKitWeb.Users.MagicLinkRegistrationRequestLive do
  @moduledoc """
  LiveView for requesting magic link registration.

  Allows users to enter their email and receive a magic link to complete registration.
  """

  use PhoenixKitWeb, :live_view

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.MagicLinkRegistration
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(_params, _session, socket) do
    # Get project title from settings
    project_title = Settings.get_setting("project_title", "PhoenixKit")

    {:ok,
     socket
     |> assign(:page_title, "Register via Magic Link")
     |> assign(:project_title, project_title)
     |> assign(:email, "")
     |> assign(:email_sent, false)
     |> assign(:error_message, nil)
     |> assign(:loading, false)}
  end

  @impl true
  def handle_event("send_magic_link", %{"email" => email}, socket) do
    email = String.trim(email)

    socket = assign(socket, :loading, true)

    case MagicLinkRegistration.send_registration_link(email) do
      {:ok, sent_email, _token} ->
        {:noreply,
         socket
         |> assign(:email_sent, true)
         |> assign(:email, sent_email)
         |> assign(:loading, false)
         |> assign(:error_message, nil)
         |> put_flash(:info, "Registration link sent! Check your email.")}

      {:error, :email_already_exists} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "This email is already registered. Please log in instead.")
         |> put_flash(:error, "Email already exists")}

      {:error, :invalid_email} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "Please enter a valid email address.")
         |> put_flash(:error, "Invalid email format")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:loading, false)
         |> assign(:error_message, "Failed to send registration link. Please try again.")
         |> put_flash(:error, "Something went wrong")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="{@project_title} - {@page_title}"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh]">
        <div class="card bg-base-100 w-full max-w-md shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-2">Register via Magic Link</h1>
            <p class="text-center text-base-content/60 text-sm mb-6">
              Enter your email to receive a registration link. No password required!
            </p>

            <%= if @email_sent do %>
              <%!-- Success state --%>
              <div class="alert alert-success">
                <PhoenixKitWeb.Components.Core.Icons.icon_check_circle_filled class="fill-current shrink-0 h-6 w-6" />
                <div>
                  <h3 class="font-bold">Email Sent!</h3>
                  <p class="text-sm">We've sent a registration link to {@email}</p>
                </div>
              </div>

              <div class="bg-base-200 rounded-lg p-4 mt-4">
                <p class="text-sm text-base-content/80">
                  <strong>Next steps:</strong>
                </p>
                <ol class="list-decimal list-inside text-sm text-base-content/70 mt-2 space-y-1">
                  <li>Check your email inbox</li>
                  <li>Click the registration link</li>
                  <li>Complete your profile</li>
                </ol>
              </div>

              <div class="text-center mt-6">
                <p class="text-sm text-base-content/60 mb-2">Didn't receive the email?</p>
                <button
                  phx-click={JS.push("send_magic_link", value: %{email: @email})}
                  class="btn btn-sm btn-ghost"
                >
                  Resend Link
                </button>
              </div>
            <% else %>
              <%!-- Email input form --%>
              <form phx-submit="send_magic_link" class="space-y-4">
                <%= if @error_message do %>
                  <div class="alert alert-error text-sm">
                    <PhoenixKitWeb.Components.Core.Icons.icon_error_circle class="stroke-current shrink-0 h-5 w-5" />
                    <span>{@error_message}</span>
                  </div>
                <% end %>

                <div>
                  <label class="label" for="email">
                    <span class="label-text flex items-center">
                      <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-4 h-4 mr-2" />
                      Email Address
                    </span>
                  </label>
                  <input
                    id="email"
                    name="email"
                    type="email"
                    value={@email}
                    placeholder="you@example.com"
                    class="input input-bordered w-full transition-colors focus:input-primary"
                    required
                    autofocus
                  />
                </div>

                <button
                  type="submit"
                  phx-disable-with="Sending..."
                  disabled={@loading}
                  class="btn btn-primary w-full transition-all hover:scale-[1.02] active:scale-[0.98]"
                >
                  <%= if @loading do %>
                    <span class="loading loading-spinner loading-sm"></span>
                    <span>Sending...</span>
                  <% else %>
                    <PhoenixKitWeb.Components.Core.Icons.icon_email class="w-5 h-5 mr-2" />
                    <span>Send Magic Link</span>
                    <span aria-hidden="true">→</span>
                  <% end %>
                </button>
              </form>

              <%!-- Info box --%>
              <div class="bg-info/10 border border-info/20 rounded-lg p-4 mt-4">
                <div class="flex items-start gap-2">
                  <PhoenixKitWeb.Components.Core.Icons.icon_info class="stroke-current shrink-0 h-5 w-5 text-info mt-0.5" />
                  <div class="text-sm text-base-content/70">
                    <p class="font-semibold text-base-content mb-1">Passwordless Registration</p>
                    <p>
                      We'll send you a secure link to complete your registration. The link expires in 30 minutes.
                    </p>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Alternative options --%>
            <div class="divider mt-6">Other options</div>

            <div class="space-y-2">
              <.link
                navigate={Routes.path("/users/register")}
                class="btn btn-outline w-full"
              >
                <PhoenixKitWeb.Components.Core.Icons.icon_user_add class="w-5 h-5 mr-2" />
                Register with Password
              </.link>

              <.link
                navigate={Routes.path("/users/log-in")}
                class="btn btn-ghost w-full"
              >
                Already have an account? Sign in
              </.link>
            </div>
          </div>
        </div>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end
end
