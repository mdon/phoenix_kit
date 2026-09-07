defmodule PhoenixKit.WebsiteAccess.Notice do
  @moduledoc """
  The visitor notice: a banner at the top of every page — an icon, a line of
  text, an optional link. "This is the development site; the live one is at
  …". Everyone sees it, admins included, so they see what visitors see.

  It is injected into every HTML response by the website-access plug (the
  same way core injects its websocket fix), so a host's own layouts carry
  it without any work; `PhoenixKitWeb.Components.Core.WebsiteAccess.notice/1`
  renders the same banner for a layout that wants to place it itself.
  """

  alias PhoenixKit.Settings

  @enabled_key "website_access_notice_enabled"
  @icon_key "website_access_notice_icon"
  @text_key "website_access_notice_text"
  @link_key "website_access_notice_link"
  @icons ~w(construction info warning none)

  def enabled_key, do: @enabled_key
  def icon_key, do: @icon_key
  def text_key, do: @text_key
  def link_key, do: @link_key
  def icons, do: @icons

  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting(@enabled_key, false) and text() != ""

  @spec switched_on?() :: boolean()
  def switched_on?, do: Settings.get_boolean_setting(@enabled_key, false)

  @spec text() :: String.t()
  def text, do: Settings.get_setting(@text_key, "") |> String.trim()

  @spec link() :: String.t() | nil
  def link do
    case Settings.get_setting(@link_key, "") |> String.trim() do
      "http://" <> _ = url -> url
      "https://" <> _ = url -> url
      "/" <> _ = path -> path
      _ -> nil
    end
  end

  @spec icon() :: String.t()
  def icon do
    case Settings.get_setting(@icon_key, "info") do
      i when i in @icons -> i
      _ -> "info"
    end
  end

  @doc """
  The banner as safe HTML, or nil when the notice is off. `preview: true`
  renders it from the saved text whether or not the switch is on (the
  settings page shows what it will look like before switching it on).
  """
  @spec html() :: String.t() | nil
  def html(opts \\ []) do
    if enabled?() or (Keyword.get(opts, :preview, false) and text() != "") do
      symbol =
        case icon() do
          "construction" -> "🚧"
          "warning" -> "⚠️"
          "info" -> "ℹ️"
          _ -> ""
        end

      text = Plug.HTML.html_escape(text())

      link =
        case link() do
          nil ->
            ""

          url ->
            ~s( <a href="#{Plug.HTML.html_escape(url)}" style="color:inherit;text-decoration:underline">#{Plug.HTML.html_escape(url)}</a>)
        end

      # Inline styles on purpose: this lands in host layouts that may not
      # ship core's CSS. `data-phoenix-kit-notice` lets a host hide or restyle
      # it. Fixed along the BOTTOM: a bar at the top sat on top of every
      # site's fixed header (core's admin header included) and hid it.
      # A preview sits in the page; the real bar is fixed along the bottom.
      position =
        if Keyword.get(opts, :preview, false),
          do: "position:static",
          else: "position:fixed;left:0;right:0;bottom:0"

      ~s(<div data-phoenix-kit-notice role="status" style="#{position};z-index:9999;background:#fde68a;color:#1f2937;padding:.6rem 1rem;text-align:center;font:14px/1.4 system-ui,sans-serif;box-shadow:0 -1px 4px rgba\(0,0,0,.15\)">) <>
        symbol <> " " <> text <> link <> "</div>"
    end
  end
end
