defmodule PhoenixKitWeb.Users.ConfirmationInstructionsLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  def render(assigns) do
    ~H"""
    <PhoenixKitWeb.Components.LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={assigns[:phoenix_kit_current_scope]}
      page_title="Resend confirmation"
    >
      <div class="mx-auto max-w-sm">
        <.header class="text-center">
          No confirmation instructions received?
          <:subtitle>We'll send a new confirmation link to your inbox</:subtitle>
        </.header>

        <.simple_form for={@form} id="resend_confirmation_form" phx-submit="send_instructions">
          <.input field={@form[:email]} type="email" placeholder="Email" required />
          <:actions>
            <.button phx-disable-with="Sending..." class="w-full">
              Resend confirmation instructions
            </.button>
          </:actions>
        </.simple_form>

        <p class="text-center mt-4">
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

  def handle_event("send_instructions", %{"user" => %{"email" => email}}, socket) do
    if user = Auth.get_user_by_email(email) do
      Auth.deliver_user_confirmation_instructions(
        user,
        &Routes.path("/users/confirm/#{&1}")
      )
    end

    info =
      "If your email is in our system and it has not been confirmed yet, you will receive an email with instructions shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> redirect(to: "/")}
  end
end
