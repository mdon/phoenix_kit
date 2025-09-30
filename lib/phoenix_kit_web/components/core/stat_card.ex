defmodule PhoenixKitWeb.Components.Core.StatCard do
  @moduledoc """
  Provides a statistics card UI component for dashboard metrics.

  This component renders a gradient card with an icon, main statistic value,
  title, and subtitle. Commonly used in admin dashboards to display KPIs
  and real-time statistics.
  """

  use Phoenix.Component

  @doc """
  Renders a statistics card with gradient background.

  ## Examples

      <.stat_card
        gradient_from="purple-500"
        gradient_via="purple-600"
        gradient_to="indigo-600"
        value={@session_stats.total_active}
        title="Active Sessions"
        subtitle="Currently logged in"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_activity />
        </:icon>
      </.stat_card>

      <.stat_card
        gradient_from="green-500"
        gradient_via="green-600"
        gradient_to="emerald-600"
        rounded="2xl"
        value={@stats.active_users}
        title="Active Users"
        subtitle="Currently online"
      >
        <:icon>
          <PhoenixKitWeb.Components.Core.Icons.icon_check_circle_filled />
        </:icon>
      </.stat_card>
  """
  attr :gradient_from, :string, required: true, doc: "Starting gradient color (e.g., 'purple-500')"
  attr :gradient_via, :string, required: true, doc: "Middle gradient color (e.g., 'purple-600')"
  attr :gradient_to, :string, required: true, doc: "Ending gradient color (e.g., 'indigo-600')"
  attr :rounded, :string, default: "xl", doc: "Border radius size (xl, 2xl, etc.)"
  attr :value, :any, required: true, doc: "The main statistic value to display"
  attr :title, :string, required: true, doc: "The card title text"
  attr :subtitle, :string, required: true, doc: "The smaller descriptive text"

  slot :icon, required: true, doc: "Icon to display in the card header"

  def stat_card(assigns) do
    ~H"""
    <div class={"bg-gradient-to-br from-#{@gradient_from} via-#{@gradient_via} to-#{@gradient_to} text-white rounded-#{@rounded} p-6 shadow-xl hover:shadow-2xl transition-all duration-300 transform hover:scale-105"}>
      <div class="flex items-center justify-between mb-4">
        <div class="p-2 bg-white/20 rounded-lg">
          {render_slot(@icon)}
        </div>
      </div>
      <div class="text-3xl font-bold mb-2">{@value}</div>
      <div class={"text-#{String.split(@gradient_from, "-") |> hd()}-100 font-medium"}>{@title}</div>
      <div class={"text-#{String.split(@gradient_from, "-") |> hd()}-200 text-xs mt-1"}>{@subtitle}</div>
    </div>
    """
  end
end
