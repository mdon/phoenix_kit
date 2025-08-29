defmodule PhoenixKitWeb.Users.RegistrationLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Join PhoenixKit"
    >
      <div class="hero bg-base-200 py-8 min-h-[80vh]">
        <div class="hero-content flex-col lg:flex-row-reverse">
          <!-- Welcome Section (Left side on desktop) -->
          <div class="text-center lg:text-left">
            <h1 class="text-5xl font-bold">Join PhoenixKit!</h1>
            <p class="py-6">
              Create your account to access authentication features.
              Get started with our intelligent authentication platform designed for Phoenix applications.
            </p>
            <div class="text-sm opacity-75">
              Already have an account?
              <.link
                navigate="/phoenix_kit/users/log-in"
                class="font-semibold text-primary hover:underline"
              >
                Sign in here
              </.link>
            </div>
          </div>
          
    <!-- Registration Form Card (Right side on desktop) -->
          <div class="card bg-base-100 w-full max-w-sm shrink-0 shadow-2xl">
            <div class="card-body">
              <h2 class="card-title justify-center">Create account</h2>

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
                  <legend class="fieldset-legend">Account Information</legend>

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
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def mount(_params, _session, socket) do
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
end
