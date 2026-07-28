defmodule PhoenixKitWeb.Components.Core.Chart do
  @moduledoc """
  Server-rendered SVG chart primitives — no JavaScript, no external
  libraries. Charts re-render when LiveView assigns change, which makes
  them naturally live; CSS transitions handle the rest.

  All charts are theme-aware by drawing in `currentColor`: set a text
  color class on the component (`class="text-primary"`) and both stroke
  and gradient fill follow it in light and dark themes.

  Data is plain numbers — callers map their domain (time, money, watts)
  to x/y before rendering. This keeps the primitives generic: a price
  curve, a CPU graph and a signup funnel are all just `{x, y}` pairs.

  Origin: extracted from NordSwitch's live price charts; also intended
  as the drawing layer for `phoenix_kit_dashboards` widgets.
  """

  use Phoenix.Component

  @doc """
  A line/area chart for a numeric series.

  ## Examples

      <%!-- a day of prices: x = minute of day, y = EUR/MWh --%>
      <.area_chart
        id="price-day"
        data={Enum.map(@slots, &{minute_of_day(&1.starts_at), &1.eur_mwh})}
        x_domain={{0, 1440}}
        step
        marker_x={minute_of_day(@now)}
        class="text-primary"
      />

      <%!-- plain line, auto domains --%>
      <.area_chart id="signups" data={@signups} area={false} />

  `data` is a list of `{x, y}` number tuples, sorted by x. With `step`
  each point holds its y until the next x (right-open steps — correct
  for slot/interval data like prices). `marker_x` draws a dashed
  vertical marker (a "now" line). Domains default to the data's min/max
  (y padded by 10%).
  """
  attr :id, :string, required: true, doc: "Unique id (namespaces the SVG gradient defs)"
  attr :data, :list, required: true, doc: "List of {x, y} number tuples, sorted by x"
  attr :step, :boolean, default: false, doc: "Step interpolation (interval data)"
  attr :area, :boolean, default: true, doc: "Fill a gradient area under the line"
  attr :x_domain, :any, default: nil, doc: "{min, max} for x, or nil to fit data"
  attr :y_domain, :any, default: nil, doc: "{min, max} for y, or nil to fit data (10% padded)"
  attr :marker_x, :any, default: nil, doc: "x position for a dashed vertical marker, or nil"
  attr :width, :integer, default: 960, doc: "viewBox width (the SVG scales to its container)"
  attr :height, :integer, default: 240, doc: "viewBox height"
  attr :gridlines, :integer, default: 3, doc: "Number of horizontal gridlines (0 disables)"
  attr :class, :string, default: nil, doc: "Classes for the wrapper (set text-* for color)"

  attr :label, :string,
    default: nil,
    doc:
      "Accessible name for the chart. `role=\"img\"` without one is an unlabelled " <>
        "graphic to a screen reader; pass what the chart shows (\"Electricity price today\")."

  slot :empty, doc: "Rendered instead of the SVG when data is empty"

  def area_chart(assigns) do
    assigns = assign(assigns, :geometry, area_geometry(assigns))

    ~H"""
    <div class={["pk-chart w-full", @class]}>
      <svg
        :if={@geometry}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="w-full h-full block"
        role="img"
        aria-label={@label}
        aria-hidden={is_nil(@label) && "true"}
      >
        <title :if={@label}>{@label}</title>
        <defs>
          <linearGradient id={"#{@id}-fill"} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="currentColor" stop-opacity="0.35" />
            <stop offset="100%" stop-color="currentColor" stop-opacity="0.02" />
          </linearGradient>
        </defs>

        <line
          :for={y <- @geometry.gridlines}
          x1="0"
          y1={y}
          x2={@width}
          y2={y}
          stroke="currentColor"
          stroke-opacity="0.08"
          stroke-width="1"
        />

        <path :if={@area} d={@geometry.area_path} fill={"url(##{@id}-fill)"} />

        <path
          d={@geometry.line_path}
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />

        <line
          :if={@geometry.marker_x}
          x1={@geometry.marker_x}
          y1="0"
          x2={@geometry.marker_x}
          y2={@height}
          stroke="currentColor"
          stroke-opacity="0.6"
          stroke-width="1.5"
          stroke-dasharray="4 4"
          vector-effect="non-scaling-stroke"
        />
      </svg>

      <div :if={!@geometry}>
        {render_slot(@empty) || nil}
      </div>
    </div>
    """
  end

  @doc """
  A minimal inline sparkline for a list of values.

  ## Examples

      <.sparkline values={Enum.map(@upcoming, & &1.eur_mwh)} class="w-full h-12 text-info" />
  """
  attr :values, :list, required: true, doc: "List of numbers, in order"
  attr :width, :integer, default: 200, doc: "viewBox width"
  attr :height, :integer, default: 48, doc: "viewBox height"
  attr :class, :string, default: nil

  attr :label, :string,
    default: nil,
    doc: "Accessible name. Left unset the sparkline is marked decorative (aria-hidden)."

  def sparkline(assigns) do
    assigns = assign(assigns, :points, sparkline_points(assigns))

    ~H"""
    <svg
      :if={@points}
      viewBox={"0 0 #{@width} #{@height}"}
      preserveAspectRatio="none"
      class={["pk-chart block", @class]}
      role="img"
      aria-label={@label}
      aria-hidden={is_nil(@label) && "true"}
    >
      <title :if={@label}>{@label}</title>
      <polyline
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  @doc """
  A simple vertical bar chart.

  ## Examples

      <.bar_chart
        id="daily-kwh"
        data={Enum.map(@days, &%{label: &1.date, value: &1.kwh})}
        class="text-secondary"
      />

  Bars are drawn in `currentColor`; labels render beneath when
  `show_labels` is set (keep them short).
  """
  attr :id, :string, required: true
  attr :data, :list, required: true, doc: "List of %{label: term, value: number}"
  attr :width, :integer, default: 960
  attr :height, :integer, default: 200
  attr :show_labels, :boolean, default: false
  attr :class, :string, default: nil

  attr :label, :string,
    default: nil,
    doc: "Accessible name for the chart (see `area_chart/1`)."

  slot :empty, doc: "Rendered instead of the SVG when data is empty"

  def bar_chart(assigns) do
    assigns = assign(assigns, :bars, bar_geometry(assigns))

    ~H"""
    <div class={["pk-chart w-full", @class]}>
      <svg
        :if={@bars}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="w-full h-full block"
        role="img"
        aria-label={@label}
        aria-hidden={is_nil(@label) && "true"}
      >
        <title :if={@label}>{@label}</title>
        <rect
          :for={bar <- @bars}
          x={bar.x}
          y={bar.y}
          width={bar.w}
          height={bar.h}
          rx="2"
          fill="currentColor"
          fill-opacity="0.75"
        />
      </svg>
      <div :if={@bars && @show_labels} class="flex justify-between text-xs opacity-60 font-mono mt-1">
        <span :for={item <- @data}>{item.label}</span>
      </div>
      <div :if={!@bars}>
        {render_slot(@empty) || nil}
      </div>
    </div>
    """
  end

  ## Geometry -----------------------------------------------------------

  defp area_geometry(%{data: []}), do: nil
  defp area_geometry(%{data: nil}), do: nil

  defp area_geometry(assigns) do
    %{data: data, width: width, height: height} = assigns

    {x_min, x_max} = assigns.x_domain || Enum.min_max_by(data, &elem(&1, 0)) |> minmax_x()
    {y_min, y_max} = assigns.y_domain || padded_y_domain(data)

    x_span = max(x_max - x_min, 1.0e-9)
    y_span = max(y_max - y_min, 1.0e-9)

    px = fn x -> Float.round((x - x_min) / x_span * width, 1) end
    py = fn y -> Float.round(height - (y - y_min) / y_span * height, 1) end

    points =
      if assigns.step do
        # right-open steps: each y holds until the next x, the last one
        # extends to the domain's right edge
        data
        |> Enum.chunk_every(2, 1)
        |> Enum.flat_map(fn
          [{x, y}, {x2, _}] -> [{px.(x), py.(y)}, {px.(x2), py.(y)}]
          [{x, y}] -> [{px.(x), py.(y)}, {Float.round(width * 1.0, 1), py.(y)}]
        end)
      else
        case data do
          # A lone point is a valid `M x,y` path that paints NOTHING. One
          # datum is a real case (the first slot of the day, a metric with a
          # single sample), so hold its value across the x range instead —
          # the same reading step mode gives it.
          [{_x, y}] -> [{0.0, py.(y)}, {Float.round(width * 1.0, 1), py.(y)}]
          _ -> Enum.map(data, fn {x, y} -> {px.(x), py.(y)} end)
        end
      end

    line_path =
      points
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {{x, y}, i} -> "#{if i == 0, do: "M", else: "L"}#{x},#{y}" end)

    {first_x, _} = List.first(points)
    {last_x, _} = List.last(points)

    %{
      line_path: line_path,
      area_path: "#{line_path} L#{last_x},#{height} L#{first_x},#{height} Z",
      gridlines:
        if(assigns.gridlines > 0,
          do:
            Enum.map(1..assigns.gridlines, &Float.round(height * &1 / (assigns.gridlines + 1), 1)),
          else: []
        ),
      marker_x:
        case assigns.marker_x do
          nil -> nil
          x -> if x >= x_min and x <= x_max, do: px.(x)
        end
    }
  end

  defp minmax_x({{x_min, _}, {x_max, _}}), do: {x_min, x_max}

  defp padded_y_domain(data) do
    {y_min, y_max} = data |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    pad = (y_max - y_min) * 0.1 + 1.0e-9
    {y_min - pad, y_max + pad}
  end

  defp sparkline_points(%{values: values}) when length(values) < 2, do: nil

  defp sparkline_points(%{values: values, width: width, height: height}) do
    {v_min, v_max} = Enum.min_max(values)
    span = max(v_max - v_min, 1.0e-9)
    n = length(values)

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {v, i} ->
      x = Float.round(i / (n - 1) * width, 1)
      y = Float.round(height - 4 - (v - v_min) / span * (height - 8), 1)
      "#{x},#{y}"
    end)
  end

  defp bar_geometry(%{data: []}), do: nil
  defp bar_geometry(%{data: nil}), do: nil

  # Bars are measured from a zero baseline, not from the smallest value, so
  # signed data works: negatives hang below the line, positives rise above it.
  # Scaling by `max(value)` alone produced a NEGATIVE rect height for negative
  # values — which SVG discards outright, so the bar silently vanished — and
  # an all-negative series divided by a 1.0e-9 floor, throwing the geometry to
  # astronomical numbers.
  defp bar_geometry(%{data: data, width: width, height: height}) do
    values = Enum.map(data, & &1.value)

    # The baseline is always inside the domain, even when every value sits on
    # one side of it.
    v_min = values |> Enum.min() |> min(0)
    v_max = values |> Enum.max() |> max(0)
    span = max(v_max - v_min, 1.0e-9)

    # Leave a little headroom so a full-height bar isn't flush with the edge.
    plot_h = height - 4
    scale = fn v -> (v - v_min) / span * plot_h end
    baseline = height - scale.(0)

    n = length(data)
    slot_w = width / n
    bar_w = Float.round(slot_w * 0.7, 1)

    data
    |> Enum.with_index()
    |> Enum.map(fn {%{value: value}, i} ->
      y_value = height - scale.(value)
      top = min(y_value, baseline)

      %{
        x: Float.round(i * slot_w + (slot_w - bar_w) / 2, 1),
        y: Float.round(top, 1),
        w: bar_w,
        h: Float.round(abs(y_value - baseline), 1)
      }
    end)
  end
end
