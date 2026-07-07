defmodule PhoenixKitWeb.Components.Core.ResourceLink do
  @moduledoc """
  Renders a resolved resource (from `PhoenixKit.ResourceLinks`) as a compact,
  clickable chip that deep-links to where the resource lives — the record an
  activity happened on, or a comment is attached to.

  Mirrors the comments moderation chip: a thumbnail (when the handler supplies
  `thumb_url`) or a type badge, plus the truncated title. Prefixed phoenix_kit
  routes SPA-navigate; host-template paths render as a real `href` (they may
  point at a controller page or external URL, where live navigation can't reach).

  Render only when a resolved info map is present:

      <.resource_link :if={@info} info={@info} />
  """
  use Phoenix.Component

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.ResourceLinks

  @doc """
  Renders the resource chip for a resolved `info` map.
  """
  attr :info, :map, required: true
  attr :class, :string, default: ""

  def resource_link(assigns) do
    ~H"""
    <.link
      :if={@info[:prefixed]}
      navigate={ResourceLinks.url(@info)}
      class={[chip_class(), @class]}
      title={@info[:full_title] || @info.title}
    >
      <.chip_body info={@info} />
    </.link>
    <.link
      :if={!@info[:prefixed]}
      href={ResourceLinks.url(@info)}
      class={[chip_class(), @class]}
      title={@info[:full_title] || @info.title}
    >
      <.chip_body info={@info} />
    </.link>
    """
  end

  @doc """
  Renders a plain-text label (e.g. an email) as a link to a resolved resource,
  falling back to plain text when `info` is `nil` (unresolved).

  Lighter than `resource_link/1` — no chip/thumbnail — for inline "who did it /
  who it's for" links in dense tables (the activity feed's actor/target).
  """
  attr :info, :map, default: nil
  attr :label, :string, required: true
  attr :class, :string, default: ""

  def resource_email_link(assigns) do
    ~H"""
    <.link
      :if={@info && @info[:prefixed]}
      navigate={ResourceLinks.url(@info)}
      class={["link link-hover", @class]}
      title={@info[:full_title] || @info[:title]}
    >
      {@label}
    </.link>
    <.link
      :if={@info && !@info[:prefixed]}
      href={ResourceLinks.url(@info)}
      class={["link link-hover", @class]}
      title={@info[:full_title] || @info[:title]}
    >
      {@label}
    </.link>
    <span :if={is_nil(@info)} class={@class}>{@label}</span>
    """
  end

  defp chip_class do
    "inline-flex items-center gap-1.5 max-w-[240px] py-0.5 pl-1 pr-2.5 rounded-full " <>
      "bg-base-200 hover:bg-base-300 transition-colors no-underline align-middle"
  end

  # The chip's inner content. The thumbnail is a CSS background (not an
  # `<img onerror=…>`): inline JS is blocked by a strict `script-src` CSP, and a
  # missing background image simply falls back to the placeholder colour.
  attr :info, :map, required: true

  defp chip_body(assigns) do
    ~H"""
    <span
      :if={@info[:thumb_url]}
      class="w-5 h-5 rounded-full bg-base-300 bg-cover bg-center shrink-0"
      style={"background-image: url('#{@info.thumb_url}')"}
    ></span>
    <.icon
      :if={!@info[:thumb_url]}
      name="hero-arrow-top-right-on-square"
      class="w-3.5 h-3.5 text-base-content/50 shrink-0 ml-1"
    />
    <span class="truncate text-xs text-base-content/80 min-w-0">
      {@info.title}
    </span>
    """
  end
end
