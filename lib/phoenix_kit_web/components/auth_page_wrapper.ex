defmodule PhoenixKitWeb.Components.AuthPageWrapper do
  @moduledoc """
  Wrapper component for all auth pages (login, registration, etc.).

  Reads branding settings (logo, background image/color) from Settings
  and renders a consistent layout with optional custom branding.
  Supports separate background images for desktop and mobile viewports.
  """
  use Phoenix.Component

  import Phoenix.HTML, only: [raw: 1]

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.Components.Core.DevNotice
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher
  alias PhoenixKitWeb.Components.LayoutWrapper

  attr :flash, :map, required: true
  attr :phoenix_kit_current_scope, :any, default: nil
  attr :page_title, :string, required: true
  attr :current_path, :string, default: nil

  attr :dev_mailbox_message, :string,
    default: nil,
    doc:
      "If set, renders <.dev_mailbox_notice message={...} /> below the card in local-mailer dev mode."

  slot :inner_block, required: true

  def auth_page_wrapper(assigns) do
    assigns =
      assigns
      |> assign_new(:auth_logo_url, fn ->
        case Settings.get_logo_uuid() do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "medium")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_image, fn ->
        case Settings.get_setting("auth_background_image_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "original")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_image_mobile, fn ->
        case Settings.get_setting("auth_background_image_mobile_file_uuid", "") do
          uuid when is_binary(uuid) and uuid != "" -> URLSigner.signed_url(uuid, "original")
          _ -> ""
        end
      end)
      |> assign_new(:auth_bg_color, fn -> Settings.get_setting("auth_background_color", "") end)
      |> assign_new(:project_title, fn -> Settings.get_project_title() end)
      |> assign_new(:show_language_switcher, fn ->
        Languages.enabled?() and length(Languages.get_enabled_languages()) > 1
      end)

    assigns = assign(assigns, :bg_style_tag, bg_style_tag(assigns))

    ~H"""
    <LayoutWrapper.app_layout
      flash={@flash}
      phoenix_kit_current_scope={@phoenix_kit_current_scope}
      page_title={@page_title}
      current_path={@current_path}
    >
      {raw(@bg_style_tag)}
      <div class="auth-bg min-h-[calc(100vh-4rem)] flex items-center justify-center px-4 -mx-[calc(50vw-50%)] w-[100vw] -my-8">
        <div class="card bg-base-100 w-full max-w-sm shadow-2xl">
          <div class="card-body">
            <%= if @auth_logo_url != "" do %>
              <div class="flex justify-center mb-6">
                <img src={@auth_logo_url} alt={@project_title} class="h-20 object-contain" />
              </div>
            <% end %>
            {render_slot(@inner_block)}
            <%= if @show_language_switcher do %>
              <div class="flex justify-center mt-4">
                <LanguageSwitcher.language_switcher_dropdown
                  current_path={@current_path}
                  show_current={true}
                />
              </div>
            <% end %>
            <%= if @dev_mailbox_message do %>
              <DevNotice.dev_mailbox_notice message={@dev_mailbox_message} />
            <% end %>
          </div>
        </div>
      </div>
    </LayoutWrapper.app_layout>
    """
  end

  defp bg_style_tag(assigns) do
    desktop = bg_css(assigns.auth_bg_image, assigns.auth_bg_color)

    mobile =
      if assigns.auth_bg_image_mobile != "" do
        "@media (max-width: 768px) { .auth-bg { background-image: url('#{assigns.auth_bg_image_mobile}'); } }"
      else
        ""
      end

    "<style>.auth-bg { #{desktop} background-size: cover; background-position: center; } #{mobile}</style>"
  end

  defp bg_css("", ""), do: ""

  defp bg_css(image_url, _color) when image_url != "",
    do: "background-image: url('#{image_url}');"

  defp bg_css("", color), do: "background: #{color};"
end
