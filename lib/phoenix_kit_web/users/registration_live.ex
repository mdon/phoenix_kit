defmodule PhoenixKitWeb.Users.RegistrationLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Create account"
    >
      <div class="flex items-center justify-center py-8 min-h-[80vh] bg-base-200">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <h1 class="text-2xl font-bold text-center mb-6">Create account</h1>

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

    changeset = Auth.change_user_registration(%User{})

    socket =
      socket
      |> assign(trigger_submit: false, check_errors: false)
      |> assign_form(changeset)

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case Auth.register_user(user_params) do
      {:ok, user} ->
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
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Auth.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")

    if changeset.valid? do
      assign(socket, form: form, check_errors: false)
    else
      assign(socket, form: form)
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
