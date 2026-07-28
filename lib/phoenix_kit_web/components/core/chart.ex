defmodule PhoenixKitWeb.Components.Core.Chart do
  @moduledoc """
  Server-rendered SVG chart primitives — no JavaScript, no external
  libraries. Charts re-render whenever LiveView assigns change, so they
  are live by construction. (They snap rather than tween: SVG geometry
  attributes are not CSS-transitionable.)

  All charts draw in `currentColor`: set a text colour on the component
  (`class="text-primary"`) and stroke, fill and gradient all follow it in
  light and dark themes.

  ## Sizing

  Each chart fills its container. The SVG uses `preserveAspectRatio="none"`,
  so it stretches to whatever box you give it while strokes stay crisp via
  `vector-effect="non-scaling-stroke"`. **Give the wrapper a height** —
  otherwise you inherit the viewBox's intrinsic ratio, which is rarely what
  you want:

      <div class="h-48 w-full">
        <.line_chart id="p" data={@points} class="text-primary" />
      </div>

  Heavy stretching still distorts anything measured in user space: dash
  patterns and the bars' rounded corners. Strokes are protected; those are
  not.

  ## Data

  Values are plain numbers — callers map their domain (time, money, watts)
  to x/y first, which is what keeps these primitives generic: a price
  curve, a CPU graph and a signup funnel are all just `{x, y}` pairs.

  Points may be `{x, y}` tuples or `%{x: x, y: y}` maps, and `Decimal`
  values are converted automatically (money and metrics arrive that way
  from Ecto). Points that aren't numeric are dropped rather than crashing
  the page; if nothing usable is left, the `:empty` slot renders.

  Series are sorted by x, so out-of-order data plots correctly instead of
  zigzagging.

  Origin: extracted from NordSwitch's live price charts; also intended as
  the drawing layer for `phoenix_kit_dashboards` widgets.
  """

  use Phoenix.Component

  @doc """
  A line chart for a numeric series, optionally filled.

  ## Examples

      <%!-- a day of prices: x = minute of day, y = EUR/MWh --%>
      <.line_chart
        id="price-day"
        data={Enum.map(@slots, &{minute_of_day(&1.starts_at), &1.eur_mwh})}
        x_domain={{0, 1440}}
        step
        marker_x={minute_of_day(@now)}
        aria_label="Electricity price today"
        class="text-primary"
      />

      <%!-- a bare line, auto domains --%>
      <.line_chart id="signups" data={@signups} area={false} />

  With `step` each point holds its y until the next x (right-open steps —
  the correct reading for slot/interval data like prices). `marker_x`
  draws a dashed vertical "now" line. Domains default to the data's
  min/max, y padded by 10%; a reversed domain is normalised.
  """
  attr :id, :string, required: true, doc: "Unique id (namespaces the SVG gradient defs)"

  attr :data, :list,
    required: true,
    doc: "Points as {x, y} tuples or %{x: _, y: _} maps. Non-numeric points are dropped."

  attr :step, :boolean, default: false, doc: "Step interpolation (interval data)"
  attr :area, :boolean, default: true, doc: "Fill a gradient area under the line"
  attr :x_domain, :any, default: nil, doc: "{min, max} for x, or nil to fit data"
  attr :y_domain, :any, default: nil, doc: "{min, max} for y, or nil to fit data (10% padded)"
  attr :marker_x, :any, default: nil, doc: "x position for a dashed vertical marker, or nil"
  attr :width, :integer, default: 960, doc: "viewBox width (the SVG scales to its container)"
  attr :height, :integer, default: 240, doc: "viewBox height"
  attr :gridlines, :integer, default: 3, doc: "Number of horizontal gridlines (0 disables)"
  attr :class, :any, default: nil, doc: "Classes for the wrapper (set text-* for colour)"

  attr :aria_label, :string,
    default: nil,
    doc:
      "Accessible name. `role=\"img\"` without one is an unlabelled graphic to a " <>
        "screen reader; pass what the chart shows. Unlabelled charts are marked decorative."

  attr :rest, :global, doc: "Extra attributes for the wrapper"

  slot :empty, doc: "Rendered instead of the SVG when there is no usable data"

  def line_chart(assigns) do
    assigns = assign(assigns, :geometry, line_geometry(assigns))

    ~H"""
    <div class={["pk-chart w-full h-full", @class]} {@rest}>
      <svg
        :if={@geometry}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="w-full h-full block"
        role="img"
        aria-label={@aria_label}
        aria-hidden={is_nil(@aria_label) && "true"}
      >
        <title :if={@aria_label}>{@aria_label}</title>
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
          vector-effect="non-scaling-stroke"
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

        <circle
          :if={@geometry.dot}
          cx={@geometry.dot.x}
          cy={@geometry.dot.y}
          r="3"
          fill="currentColor"
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

      <div :if={!@geometry}>{render_slot(@empty)}</div>
    </div>
    """
  end

  @doc """
  A minimal inline sparkline for a list of values.

  ## Examples

      <.sparkline values={Enum.map(@upcoming, & &1.eur_mwh)} class="w-full h-12 text-info" />

  A single value draws a flat line rather than nothing — one sample is a
  real state, and an empty box reads as a rendering bug.
  """
  attr :values, :list, required: true, doc: "Numbers, in order. Non-numeric values are dropped."
  attr :width, :integer, default: 200, doc: "viewBox width"
  attr :height, :integer, default: 48, doc: "viewBox height"
  attr :class, :any, default: nil, doc: "Classes for the wrapper (set text-* for colour)"

  attr :aria_label, :string,
    default: nil,
    doc: "Accessible name. Left unset the sparkline is marked decorative."

  attr :rest, :global, doc: "Extra attributes for the wrapper"

  slot :empty, doc: "Rendered instead of the SVG when there is no usable data"

  def sparkline(assigns) do
    assigns = assign(assigns, :points, sparkline_points(assigns))

    ~H"""
    <div class={["pk-chart", @class]} {@rest}>
      <svg
        :if={@points}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="w-full h-full block"
        role="img"
        aria-label={@aria_label}
        aria-hidden={is_nil(@aria_label) && "true"}
      >
        <title :if={@aria_label}>{@aria_label}</title>
        <polyline
          points={@points}
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linejoin="round"
          vector-effect="non-scaling-stroke"
        />
      </svg>

      <div :if={!@points}>{render_slot(@empty)}</div>
    </div>
    """
  end

  @doc """
  A vertical bar chart, measured from a zero baseline.

  ## Examples

      <.bar_chart
        id="daily-kwh"
        data={Enum.map(@days, &%{label: &1.date, value: &1.kwh})}
        aria_label="Daily consumption"
        class="text-secondary"
      />

  Bars carry a native `<title>`, so hovering one shows its label and value
  with no JS. Negative values hang below the baseline instead of
  disappearing. A datum may set `class:` to colour one bar differently
  (`%{label: "Fri", value: 22, class: "text-error"}`).
  """
  attr :id, :string, required: true, doc: "Unique id (applied to the SVG element)"

  attr :data, :list,
    required: true,
    doc: "List of %{label: term, value: number, class: optional_string}"

  attr :width, :integer, default: 960
  attr :height, :integer, default: 200
  attr :show_labels, :boolean, default: false, doc: "Render labels beneath the bars"

  attr :baseline, :boolean,
    default: true,
    doc: "Draw the zero line when any value is negative (its position is not otherwise implied)"

  attr :class, :any, default: nil, doc: "Classes for the wrapper (set text-* for colour)"

  attr :aria_label, :string, default: nil, doc: "Accessible name for the chart"

  attr :value_format, :any,
    default: nil,
    doc:
      "1-arity fun formatting a value for its tooltip. No generic chart can infer " <>
        "units or locale, so pass your own. It receives the NUMBER, not your " <>
        "original struct — non-numeric values are dropped before this runs — so " <>
        "write `&\"$\#{&1}\"`, not `&Money.to_string/1`. Defaults to a compact " <>
        "numeric rendering."

  attr :rest, :global, doc: "Extra attributes for the wrapper"

  slot :empty, doc: "Rendered instead of the SVG when there is no usable data"

  def bar_chart(assigns) do
    assigns = assign(assigns, :geometry, bar_geometry(assigns))

    ~H"""
    <div class={["pk-chart w-full h-full flex flex-col", @class]} {@rest}>
      <svg
        :if={@geometry}
        id={@id}
        viewBox={"0 0 #{@width} #{@height}"}
        preserveAspectRatio="none"
        class="w-full flex-1 min-h-0 block"
        role="img"
        aria-label={@aria_label}
        aria-hidden={is_nil(@aria_label) && "true"}
      >
        <title :if={@aria_label}>{@aria_label}</title>

        <line
          :if={@baseline && @geometry.show_baseline?}
          x1="0"
          y1={@geometry.baseline}
          x2={@width}
          y2={@geometry.baseline}
          stroke="currentColor"
          stroke-opacity="0.25"
          stroke-width="1"
          vector-effect="non-scaling-stroke"
        />

        <rect
          :for={bar <- @geometry.bars}
          x={bar.x}
          y={bar.y}
          width={bar.w}
          height={bar.h}
          rx="2"
          fill="currentColor"
          fill-opacity="0.75"
          class={bar.class}
        >
          <title>{bar.title}</title>
        </rect>
      </svg>

      <div :if={@geometry && @show_labels} class="flex text-xs opacity-60 font-mono mt-1 shrink-0">
        <%!-- Each label owns exactly its bar's slot so it stays under the bar.
             `justify-between` drifted: it pinned the first and last labels to
             the container edges while the bars sit at slot centres. --%>
        <span
          :for={bar <- @geometry.bars}
          class="text-center truncate px-0.5"
          style={"width: #{@geometry.slot_percent}%"}
        >
          {bar.label}
        </span>
      </div>

      <div :if={!@geometry}>{render_slot(@empty)}</div>
    </div>
    """
  end

  ## Data normalisation ---------------------------------------------------

  # A library primitive must not take the page down over one bad point. An
  # Ecto-backed caller hands us Decimals; a JSON-backed one hands us strings
  # and nils. Coerce what we can, drop what we can't, and let the :empty slot
  # handle "nothing usable left".
  defp numeric(value) when is_integer(value) or is_float(value), do: value

  defp numeric(%Decimal{} = value) do
    Decimal.to_float(value)
  rescue
    _ -> nil
  end

  defp numeric(_), do: nil

  defp normalize_points(data) when is_list(data) do
    data
    |> Enum.map(&point/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp normalize_points(_), do: []

  defp point({x, y}), do: pair(numeric(x), numeric(y))
  defp point(%{x: x, y: y}), do: pair(numeric(x), numeric(y))
  defp point(%{"x" => x, "y" => y}), do: pair(numeric(x), numeric(y))
  defp point(_), do: nil

  defp pair(nil, _), do: nil
  defp pair(_, nil), do: nil
  defp pair(x, y), do: {x, y}

  ## Geometry -------------------------------------------------------------

  defp line_geometry(assigns) do
    %{width: width, height: height} = assigns

    case normalize_points(assigns.data) do
      [] ->
        nil

      data ->
        {x_min, x_max} = normalize_domain(assigns.x_domain, minmax_x(data))
        {y_min, y_max} = normalize_domain(assigns.y_domain, padded_y_domain(data))

        to_x = axis_scale(x_min, x_max, width)
        to_y = axis_scale(y_min, y_max, height)

        px = fn x -> round1(to_x.(x)) end
        py = fn y -> round1(height - to_y.(y)) end

        points = plot_points(data, assigns.step, px, py, x_max)
        line_path = to_path(points)
        {first_x, _} = List.first(points)
        {last_x, _} = List.last(points)

        %{
          line_path: line_path,
          area_path: "#{line_path} L#{last_x},#{height} L#{first_x},#{height} Z",
          gridlines: gridline_positions(assigns.gridlines, height),
          marker_x: marker_position(assigns.marker_x, x_min, x_max, px),
          # A path whose points all coincide is a valid `M x,y` that paints
          # NOTHING, and one datum is a real state (the day's first slot, a
          # metric with a single sample). Marking the point is the honest fix:
          # widening it into a full-width line asserts a reading across a range
          # that was never measured, and did exactly that for out-of-domain
          # data too.
          dot: collapsed_point(points)
        }
    end
  end

  # Right-open steps: each y holds until the next x, and the last extends to
  # the domain's right edge — the correct reading for interval data.
  defp plot_points(data, true = _step, px, py, x_max) do
    data
    |> Enum.chunk_every(2, 1)
    |> Enum.flat_map(fn
      [{x, y}, {x2, _}] -> [{px.(x), py.(y)}, {px.(x2), py.(y)}]
      # The tail runs to the domain's right EDGE, but never backwards: when the
      # last datum itself overshoots an explicit x_domain, extending to the
      # edge would draw a segment back leftward across the chart.
      [{x, y}] -> [{px.(x), py.(y)}, {max(px.(x), px.(x_max)), py.(y)}]
    end)
  end

  defp plot_points(data, false = _step, px, py, _x_max) do
    Enum.map(data, fn {x, y} -> {px.(x), py.(y)} end)
  end

  # A degenerate domain (one x, or an explicit zero-span) has no left or right:
  # every value belongs at the CENTRE, exactly as a flat y series centres
  # vertically. Dividing by a 1.0e-9 floor instead pinned everything to the
  # left edge, where half of each stroke is clipped away.
  defp axis_scale(lo, hi, extent) when hi > lo do
    span = hi - lo
    fn v -> (v - lo) / span * extent end
  end

  defp axis_scale(_lo, _hi, extent), do: fn _v -> extent / 2 end

  # Only a path whose points ALL coincide paints nothing. Two points sharing an
  # x still draw a vertical segment, and collapsing that to one y silently
  # threw the other value away.
  defp collapsed_point(points) do
    case Enum.uniq(points) do
      [{x, y}] -> %{x: x, y: y}
      _ -> nil
    end
  end

  defp to_path(points) do
    points
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {{x, y}, i} -> "#{if i == 0, do: "M", else: "L"}#{x},#{y}" end)
  end

  defp gridline_positions(count, _height) when not is_integer(count) or count <= 0, do: []

  defp gridline_positions(count, height) do
    Enum.map(1..count, &round1(height * &1 / (count + 1)))
  end

  defp marker_position(nil, _x_min, _x_max, _px), do: nil

  defp marker_position(x, x_min, x_max, px) do
    case numeric(x) do
      nil -> nil
      n -> if n >= x_min and n <= x_max, do: px.(n)
    end
  end

  defp minmax_x(data) do
    {{x_min, _}, {x_max, _}} = Enum.min_max_by(data, &elem(&1, 0))
    {x_min, x_max}
  end

  # A reversed domain ({10, 0}) otherwise drove the span negative, which the
  # 1.0e-9 floor turned into coordinates around 1.0e12 — the chart vanished
  # off-canvas instead of simply drawing.
  #
  # An unusable bound falls back to the DATA's own domain, never to a constant:
  # a {0, 1} fallback recreated exactly that failure, because every real x range
  # then scaled by a factor of thousands and left the canvas just as finally.
  defp normalize_domain(nil, fallback), do: fallback

  defp normalize_domain({a, b}, fallback) do
    case {numeric(a), numeric(b)} do
      {nil, _} -> fallback
      {_, nil} -> fallback
      {lo, hi} when lo > hi -> {hi, lo}
      {lo, hi} -> {lo, hi}
    end
  end

  defp normalize_domain(_, fallback), do: fallback

  defp padded_y_domain(data) do
    {y_min, y_max} = data |> Enum.map(&elem(&1, 1)) |> Enum.min_max()
    pad = y_pad(y_min, y_max)

    # Values within a hair of the float ceiling overflow on the way to
    # Infinity, which raises. Falling back to the unpadded domain draws a
    # clipped stroke; it does not take the page down.
    try do
      {y_min - pad, y_max + pad}
    rescue
      ArithmeticError -> {y_min, y_max}
    end
  end

  # A tenth of the range whenever there IS a range — a magnitude-relative pad
  # would swamp it, so a series of 1.0e12 counts differing by 100 flattened to
  # a single row of pixels. The magnitude term is the fallback for a genuinely
  # flat series, where an absolute 1.0e-9 is below one ULP past roughly 1.0e7
  # and disappears into the float, sinking the line onto the axis.
  defp y_pad(y_min, y_max) when y_max > y_min do
    range_pad = (y_max - y_min) * 0.1

    if y_max + range_pad > y_max, do: range_pad, else: magnitude_pad(y_min, y_max)
  end

  defp y_pad(y_min, y_max), do: magnitude_pad(y_min, y_max)

  defp magnitude_pad(y_min, y_max) do
    max(max(abs(y_max), abs(y_min)) * 1.0e-6, 1.0e-9)
  end

  defp sparkline_points(%{values: values, width: width, height: height}) do
    raw = List.wrap(values)
    n = length(raw)

    # Index BEFORE dropping: a survivor must keep the x it had. Rejecting first
    # re-spaced the whole axis, so removing one bad sample silently changed the
    # SHAPE of the line rather than leaving a gap in it.
    kept =
      raw
      |> Enum.with_index()
      |> Enum.filter(fn {v, _i} -> not is_nil(numeric(v)) end)
      |> Enum.map(fn {v, i} -> {numeric(v), i} end)

    case kept do
      [] ->
        nil

      [{_v, _i}] ->
        # One sample is a real state; an empty box reads as a broken chart.
        y = round1(height / 2)
        "0.0,#{y} #{round1(width * 1.0)},#{y}"

      kept ->
        {v_min, v_max} = kept |> Enum.map(&elem(&1, 0)) |> Enum.min_max()
        # Pad like the line chart, so a steady metric centres instead of
        # reading as "pinned at its minimum".
        pad = y_pad(v_min, v_max)
        lo = v_min - pad
        span = max(v_max + pad - lo, 1.0e-9)
        last = max(n - 1, 1)

        Enum.map_join(kept, " ", fn {v, i} ->
          x = round1(i / last * width)
          y = round1(height - 4 - (v - lo) / span * (height - 8))
          "#{x},#{y}"
        end)
    end
  end

  # Bars are measured from a zero baseline, not from the smallest value, so
  # signed data works: negatives hang below the line, positives rise above it.
  # Scaling by `max(value)` alone produced a NEGATIVE rect height for negative
  # values — which SVG discards outright, so the bar silently vanished — and
  # an all-negative series divided by a 1.0e-9 floor, throwing the geometry to
  # astronomical numbers.
  defp bar_geometry(%{data: data, width: width, height: height} = assigns) do
    formatter = Map.get(assigns, :value_format)

    case normalize_bars(data) do
      [] ->
        nil

      bars ->
        values = Enum.map(bars, & &1.value)

        # The baseline is always inside the domain, even when every value sits
        # on one side of it.
        v_min = values |> Enum.min() |> min(0)
        v_max = values |> Enum.max() |> max(0)
        span = max(v_max - v_min, 1.0e-9)

        plot_h = height - 4
        scale = fn v -> (v - v_min) / span * plot_h end
        baseline = height - scale.(0)

        n = length(bars)
        slot_w = width / n
        bar_w = max(round1(slot_w * 0.7), 0.5)

        %{
          baseline: round1(baseline),
          # Any negative value needs the zero line drawn: for an all-negative
          # series the baseline sits at the TOP, which nothing else implies.
          show_baseline?: v_min < 0,
          slot_percent: round1(100 / n),
          bars: position_bars(bars, slot_w, bar_w, height, baseline, scale, formatter)
        }
    end
  end

  defp position_bars(bars, slot_w, bar_w, height, baseline, scale, formatter) do
    bars
    |> Enum.with_index()
    |> Enum.map(fn {bar, i} ->
      y_value = height - scale.(bar.value)

      # A zero value has zero height, and SVG paints nothing at all for that —
      # an all-zero series rendered as a completely blank chart from perfectly
      # valid data. Keep a hairline so the category stays visible.
      h = max(round1(abs(y_value - baseline)), 1.0)

      # The floor has to move `y` too. For a non-negative series the baseline
      # IS the bottom edge, so pinning y there and adding the hairline drew the
      # rect from height..height+1 — just outside the viewBox, clipped, and
      # therefore still invisible. Non-negative bars hang from the baseline
      # upward; negatives drop from it. Both then get clamped into the viewBox:
      # a small negative among large positives puts the baseline ON the bottom
      # edge, so the hairline hung from height..height+1 and was clipped away
      # again — the same disappearing bar, on the other sign.
      y =
        if bar.value < 0, do: baseline, else: baseline - h

      y = y |> max(0.0) |> min(height - h)

      %{
        x: round1(i * slot_w + (slot_w - bar_w) / 2),
        y: round1(y),
        w: bar_w,
        h: h,
        label: label_text(bar.label),
        class: bar.class,
        title: bar_title(bar, formatter)
      }
    end)
  end

  # Accepts the same shapes as line_chart's points, plus {label, value} tuples —
  # a caller who reaches for one and gets a silently blank chart has no way to
  # tell the difference from "no data".
  defp normalize_bars(data) when is_list(data) do
    data
    |> Enum.map(&bar/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_bars(_), do: []

  defp bar(%{value: value} = datum),
    do: build_bar(value, Map.get(datum, :label), Map.get(datum, :class))

  defp bar(%{"value" => value} = datum),
    do: build_bar(value, Map.get(datum, "label"), Map.get(datum, "class"))

  defp bar({label, value}), do: build_bar(value, label, nil)
  defp bar(value) when is_number(value), do: build_bar(value, nil, nil)
  defp bar(_), do: nil

  defp build_bar(value, label, class) do
    case numeric(value) do
      nil -> nil
      n -> %{value: n, label: label, class: class}
    end
  end

  defp bar_title(%{label: nil, value: value}, formatter), do: display(value, formatter)

  defp bar_title(%{label: label, value: value}, formatter),
    do: "#{label_text(label)}: #{display(value, formatter)}"

  # `:label` is documented as `term`, and `bar/1` accepts anything — so a tuple
  # or a map would raise Protocol.UndefinedError from the interpolation and
  # take the page down. The module's contract is to survive one bad datum.
  #
  # The rescue is deliberately broad: `to_string/1` raises ArgumentError, not
  # Protocol.UndefinedError, for a keyword list — List.Chars IS implemented for
  # lists, it just fails on anything that isn't iodata. Naming one exception
  # left the most plausible bad label of all still crashing.
  defp label_text(nil), do: nil
  defp label_text(label) when is_binary(label), do: label

  defp label_text(label) do
    to_string(label)
  rescue
    _ -> inspect(label)
  end

  defp display(value, formatter) when is_function(formatter, 1) do
    to_string(formatter.(value))
  rescue
    _ -> format_value(value)
  end

  defp display(value, _formatter), do: format_value(value)

  # Tooltips show a computed number, and float arithmetic surfaces its own
  # noise: `0.1 + 0.2` renders as "0.30000000000000004". Round for DISPLAY only
  # — the geometry keeps full precision — and drop a trailing ".0" so whole
  # numbers read as whole numbers.
  defp format_value(value) when is_integer(value), do: Integer.to_string(value)

  defp format_value(value) when is_float(value) do
    rounded = Float.round(value, 4)

    cond do
      # Rounding a small magnitude to 4dp collapses it to "0" — a rate, a
      # fractional percentage or a sub-cent price would read as nothing.
      rounded == 0.0 and value != 0.0 -> :erlang.float_to_binary(value, [:short])
      value == trunc(value) and abs(value) < 1.0e15 -> value |> trunc() |> Integer.to_string()
      true -> :erlang.float_to_binary(rounded, [:short])
    end
  end

  defp format_value(value), do: to_string(value)

  # `Float.round/2` raises on an integer. Every current call site is protected
  # because `/` always yields a float in Elixir, but that is a property of the
  # arithmetic rather than of this function — one refactor to integer division
  # would turn it into a crash, so normalise here instead.
  defp round1(value), do: Float.round(value * 1.0, 1)
end
