defmodule PhoenixKitWeb.Users.ForgotPasswordLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Users.Auth

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Forgot Password"
    >
      <div class="mx-auto max-w-sm">
        <.header class="text-center">
          Forgot your password?
          <:subtitle>We'll send a password reset link to your inbox</:subtitle>
        </.header>

        <.simple_form for={@form} id="reset_password_form" phx-submit="send_email">
          <.input field={@form[:email]} type="email" placeholder="Email" required />
          <:actions>
            <.button phx-disable-with="Sending..." class="w-full">
              Send password reset instructions
            </.button>
          </:actions>
        </.simple_form>
        <p class="text-center text-sm mt-4">
          <.link href={Routes.path("/users/register")}>Register</.link>
          | <.link href={Routes.path("/users/log-in")}>Log in</.link>
        </p>
      </div>
    </PhoenixKitWeb.Components.LayoutWrapper.app_layout>
    """
  end

  def mount(_params, _session, socket) do
    {:ok, assign(socket, form: to_form(%{}, as: "user"))}
  end

  def handle_event("send_email", %{"user" => %{"email" => email}}, socket) do
    if user = Auth.get_user_by_email(email) do
      Auth.deliver_user_reset_password_instructions(
        user,
        &Routes.path("/users/reset-password/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions to reset your password shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: "/")}
  end
end
