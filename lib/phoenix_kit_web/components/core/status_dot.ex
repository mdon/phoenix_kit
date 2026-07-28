defmodule PhoenixKitWeb.Components.Core.StatusDot do
  @moduledoc """
  A tiny semantic status indicator: a coloured dot with an optional
  label. The generic companion to the domain-specific badges in
  `PhoenixKitWeb.Components.Core.Badge` — for "online/offline",
  "connected", "live socket up", "syncing" and every other place a
  little coloured circle keeps getting hand-rolled.

  Origin: extracted from NordSwitch (device online state, websocket
  health, account connection state).
  """

  use Phoenix.Component

  @doc """
  Renders a status dot, optionally with a label.

  ## Examples

      <.status_dot variant={:success} label="online" />
      <.status_dot variant={:error} label="socket down" size={:sm} />
      <.status_dot variant={:info} pulse />

      <%!-- boolean convenience for the overwhelmingly common case --%>
      <.status_dot up={@device.online} label={if @device.online, do: "online", else: "offline"} />
  """
  attr :variant, :atom,
    default: nil,
    values: [:success, :error, :warning, :info, :neutral, nil],
    doc: "Semantic colour; overrides `up` when set"

  attr :up, :boolean,
    default: nil,
    doc: "Boolean convenience: true → success, false → error (ignored when `variant` set)"

  attr :label, :string, default: nil, doc: "Optional text next to the dot"
  attr :size, :atom, default: :md, values: [:xs, :sm, :md], doc: "Dot size"
  attr :pulse, :boolean, default: false, doc: "Animate the dot (attention/live state)"
  attr :class, :string, default: nil, doc: "Extra classes for the wrapper"

  def status_dot(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]}>
      <span class="relative flex">
        <span
          :if={@pulse}
          class={[
            "absolute inline-flex h-full w-full rounded-full opacity-60 animate-ping",
            dot_color(@variant, @up)
          ]}
        />
        <span class={["relative inline-flex rounded-full", dot_size(@size), dot_color(@variant, @up)]} />
      </span>
      <span :if={@label} class={["opacity-70", label_size(@size)]}>{@label}</span>
    </span>
    """
  end

  defp dot_color(nil, true), do: "bg-success"
  defp dot_color(nil, false), do: "bg-error"
  defp dot_color(nil, nil), do: "bg-neutral"
  defp dot_color(:success, _), do: "bg-success"
  defp dot_color(:error, _), do: "bg-error"
  defp dot_color(:warning, _), do: "bg-warning"
  defp dot_color(:info, _), do: "bg-info"
  defp dot_color(:neutral, _), do: "bg-neutral"

  defp dot_size(:xs), do: "size-1.5"
  defp dot_size(:sm), do: "size-2"
  defp dot_size(:md), do: "size-2.5"

  defp label_size(:xs), do: "text-xs"
  defp label_size(:sm), do: "text-xs"
  defp label_size(:md), do: "text-sm"
end
