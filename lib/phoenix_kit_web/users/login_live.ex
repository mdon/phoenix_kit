defmodule PhoenixKitWeb.Users.LoginLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.Presence

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Welcome back"
    >
      <div class="hero bg-base-200 py-8 min-h-[80vh]">
        <div class="hero-content flex-col lg:flex-row-reverse">
          <!-- Welcome Section (Left side on desktop) -->
          <div class="text-center lg:text-left">
            <h1 class="text-5xl font-bold">Welcome back!</h1>
            <p class="py-6">
              Access your PhoenixKit account to continue using authentication features.
              Sign in securely with your email and password.
            </p>
            <div class="text-sm opacity-75">
              Don't have an account?
              <.link
                navigate="/phoenix_kit/users/register"
                class="font-semibold text-primary hover:underline"
              >
                Sign up for free
              </.link>
            </div>
          </div>
          
    <!-- Login Form Card (Right side on desktop) -->
          <div class="card bg-base-100 w-full max-w-sm shrink-0 shadow-2xl">
            <div class="card-body">
              <h2 class="card-title justify-center">Log in to account</h2>
              
    <!-- Traditional Password Login -->
              <.form
                for={@form}
                id="login_form"
                action="/phoenix_kit/users/log-in"
                phx-update="ignore"
              >
                <fieldset class="fieldset">
                  <legend class="fieldset-legend">Login with Password</legend>

                  <label class="label" for="user_email">Email</label>
                  <input
                    id="user_email"
                    name="user[email]"
                    type="email"
                    class="input input-bordered validator w-full"
                    placeholder="Email"
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
                    placeholder="Password"
                    minlength="8"
                    title="Password must be at least 8 characters long"
                    required
                  />
                  <p class="validator-hint">Password must be at least 8 characters long</p>

                  <div class="form-control mt-4">
                    <label class="label cursor-pointer">
                      <span class="label-text">Keep me logged in</span>
                      <input
                        id="user_remember_me"
                        name="user[remember_me]"
                        type="checkbox"
                        class="checkbox checkbox-info"
                      />
                    </label>
                  </div>

                  <div class="text-center mt-2">
                    <.link
                      href="/phoenix_kit/users/reset-password"
                      class="text-sm font-semibold text-primary hover:underline"
                    >
                      Forgot your password?
                    </.link>
                  </div>

                  <button
                    type="submit"
                    phx-disable-with="Logging in..."
                    class="btn btn-primary w-full mt-4"
                  >
                    Log in <span aria-hidden="true">→</span>
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
                  Development mode: Authentication testing active
                </span>
              </div>
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
        current_page: "/phoenix_kit/users/log-in"
      })
    end

    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email}, as: "user")
    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
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
