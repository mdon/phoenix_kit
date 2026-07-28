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

  use Gettext, backend: PhoenixKitWeb.Gettext

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
  attr :class, :any, default: nil, doc: "Extra classes for the wrapper"

  attr :state_label, :string,
    default: nil,
    doc:
      ~s|Overrides the announced state name. The defaults are generic | <>
        ~s|(`up` reads "online"/"offline"); anything else — a payment, a job — | <>
        ~s|should say so itself.|

  attr :rest, :global, doc: "Extra attributes for the wrapper (title, data-*, …)"

  def status_dot(assigns) do
    {color, state_name} = state(assigns.variant, assigns.up)

    assigns =
      assigns
      |> assign(:color, color)
      |> assign(:visible_label, presence(assigns.label))
      |> assign(:state_name, presence(assigns.state_label) || state_name)

    ~H"""
    <span class={["inline-flex items-center gap-1.5", @class]} {@rest}>
      <span class="relative flex">
        <span
          :if={@pulse}
          class={[
            "absolute inline-flex h-full w-full rounded-full opacity-60 motion-safe:animate-ping",
            @color
          ]}
        />
        <span class={["relative inline-flex rounded-full", dot_size(@size), @color]} />
      </span>
      <span :if={@visible_label} class={["opacity-70", label_size(@size)]}>{@visible_label}</span>
      <%!-- Colour alone carries the state, which is silent to a screen reader
           and indistinguishable to red/green colour-blind users. With no
           visible label, name the state for assistive tech instead. --%>
      <span :if={is_nil(@visible_label)} class="sr-only">{@state_name}</span>
    </span>
    """
  end

  # An empty string is truthy, so `label=""` — an ordinary result of
  # `label={@device.name}` — rendered an empty visible span AND suppressed the
  # hidden one, leaving a dot with no accessible name at all.
  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(value), do: value

  # One resolver returns BOTH the colour and the word for a state, so the two
  # can never drift out of step as separate lookup tables could.
  defp state(nil, true), do: {"bg-success", gettext("online")}
  defp state(nil, false), do: {"bg-error", gettext("offline")}
  defp state(nil, nil), do: {"bg-neutral", gettext("status unknown")}
  defp state(:success, _), do: {"bg-success", gettext("ok")}
  defp state(:error, _), do: {"bg-error", gettext("error")}
  defp state(:warning, _), do: {"bg-warning", gettext("warning")}
  defp state(:info, _), do: {"bg-info", gettext("info")}
  defp state(:neutral, _), do: {"bg-neutral", gettext("inactive")}

  defp dot_size(:xs), do: "size-1.5"
  defp dot_size(:sm), do: "size-2"
  defp dot_size(:md), do: "size-2.5"

  defp label_size(:xs), do: "text-xs"
  defp label_size(:sm), do: "text-xs"
  defp label_size(:md), do: "text-sm"
end
