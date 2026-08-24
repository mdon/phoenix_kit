defmodule PhoenixKitWeb.Users.AuthFlashI18nTest do
  @moduledoc """
  Pins that auth-session user-visible errors actually resolve through gettext
  at the locale the request is in — not that the catalog *contains* a
  translation (that would pass if the string was never wrapped).

  The leftover case this file exists for: `#747` wrapped every `put_flash`
  literal it found, but two magic-link LiveViews also render an inline
  `:error` / `:error_message` assign. Those strings never appeared at a
  `put_flash` call site, so they stayed English on an otherwise-translated
  page (the registration-request form showed both copies at once).
  """
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Lifecycle
  alias Phoenix.LiveView.Socket
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth
  alias PhoenixKitWeb.Users.MagicLink
  alias PhoenixKitWeb.Users.MagicLinkRegistrationRequest

  @backend PhoenixKitWeb.Gettext

  setup do
    previous = Gettext.get_locale(@backend)
    on_exit(fn -> Gettext.put_locale(@backend, previous) end)
    :ok
  end

  defp lv_socket(extra \\ %{}) do
    %Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, extra),
      private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
    }
  end

  describe "on_mount(:phoenix_kit_ensure_admin) flash locale" do
    test "an anonymous visitor on an /et/ URL gets the Estonian login bounce" do
      path = Routes.path("/et/admin")

      {:halt, socket} =
        Auth.on_mount(
          :phoenix_kit_ensure_admin,
          %{"locale" => "et"},
          %{},
          %Socket{
            view: PhoenixKitWeb.Live.Dashboard,
            assigns: %{__changed__: %{}, flash: %{}},
            private: %{
              connect_params: %{},
              connect_info: %{uri: URI.parse("http://localhost" <> path)},
              lifecycle: %Lifecycle{},
              live_temp: %{}
            },
            router: PhoenixKitWeb.Router
          }
        )

      assert socket.assigns.flash["error"] == "Selle lehe vaatamiseks peate sisse logima."
    end
  end

  describe "magic-link request inline errors" do
    setup do
      Gettext.put_locale(@backend, "et")
      :ok
    end

    test "an invalid email is translated, not the English msgid" do
      {:noreply, socket} =
        MagicLink.handle_event(
          "send_magic_link",
          %{"magic_link" => %{"email" => "not-an-email"}},
          lv_socket()
        )

      assert socket.assigns.error == "Palun sisestage kehtiv e-posti aadress"
    end

    test "a crashed send is translated" do
      {:noreply, socket} =
        MagicLink.handle_async(
          :send_magic_link,
          {:exit, :boom},
          lv_socket(%{loading: true})
        )

      assert socket.assigns.loading == false
      assert socket.assigns.error == "Magic Linki saatmine ebaõnnestus. Palun proovige uuesti."
    end
  end

  describe "magic-link registration request inline errors" do
    setup do
      Gettext.put_locale(@backend, "et")
      :ok
    end

    test "invalid email translates the inline copy AND the flash" do
      {:noreply, socket} =
        MagicLinkRegistrationRequest.handle_async(
          :send_magic_link,
          {:ok, {:error, :invalid_email}},
          lv_socket(%{loading: true, error_message: nil})
        )

      assert socket.assigns.loading == false
      assert socket.assigns.error_message == "Palun sisestage kehtiv e-posti aadress."
      assert socket.assigns.flash["error"] == "Vigane e-posti vorming"
    end

    test "rate-limit translates the inline copy AND the flash" do
      {:noreply, socket} =
        MagicLinkRegistrationRequest.handle_async(
          :send_magic_link,
          {:ok, {:error, :rate_limit_exceeded}},
          lv_socket(%{loading: true, error_message: nil})
        )

      assert socket.assigns.error_message ==
               "Liiga palju registreerimiskatseid. Palun proovige hiljem uuesti."

      assert socket.assigns.flash["error"] == "Liiga palju katseid"
    end

    test "a crashed send translates the inline copy AND the flash" do
      {:noreply, socket} =
        MagicLinkRegistrationRequest.handle_async(
          :send_magic_link,
          {:exit, :boom},
          lv_socket(%{loading: true, error_message: nil})
        )

      assert socket.assigns.error_message ==
               "Registreerimislingi saatmine ebaõnnestus. Palun proovige uuesti."

      assert socket.assigns.flash["error"] == "Midagi läks valesti"
    end
  end
end
