defmodule PhoenixKitWeb.Components.Core.DateNav do
  @moduledoc ~S"""
  Previous / next / today navigation over a date kept in the URL — the
  header of a page that shows one day at a time (a day's analytics, a
  schedule, a log).

  Stateless: the buttons are `<.link patch>`es built by the `path` function
  you pass, so the date lives in the URL and the page's `handle_params/3`
  reads it (parse it with `parse_param/2`). Previous and next are disabled
  at `min` / `max`; "Today" shows only when you are not already on it.

      <.date_nav
        date={@date}
        today={@today}
        max={@today}
        path={&Routes.path("/admin/analytics?date=#{&1}")}
      />

      def handle_params(params, _uri, socket) do
        today = MyApp.local_today()
        {:noreply, assign(socket, date: DateNav.parse_param(params["date"], today: today, max: today))}
      end

  ## The date picker

  With `picker` (default `true`) a native date input sits between the
  arrows. A date input only reaches the server inside a form, so it is
  wrapped in one that sends `pick_event` (default `"date_nav_pick"`) with
  `%{"date" => "YYYY-MM-DD"}`; handle it with a patch:

      def handle_event("date_nav_pick", %{"date" => value}, socket) do
        date = DateNav.parse_param(value, today: socket.assigns.today)
        {:noreply, push_patch(socket, to: Routes.path("/admin/analytics?date=#{date}"))}
      end

  The date is written with `PhoenixKit.Utils.Date.short_with_year/1`, in
  the viewer's language.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Utils.Date, as: UtilsDate

  attr :date, Date, required: true
  attr :path, :any, required: true, doc: "1-arity function: `Date.t()` → the URL for that date"
  attr :today, Date, default: nil, doc: "The viewer's today (default: UTC today)"
  attr :min, Date, default: nil
  attr :max, Date, default: nil
  attr :picker, :boolean, default: true
  attr :pick_event, :string, default: "date_nav_pick"
  attr :id, :string, default: "date-nav"
  attr :class, :any, default: nil
  attr :rest, :global

  def date_nav(assigns) do
    today = assigns.today || Date.utc_today()
    prev = Date.add(assigns.date, -1)
    next = Date.add(assigns.date, 1)

    assigns =
      assigns
      |> assign(:today_date, today)
      |> assign(:prev, if(before_min?(prev, assigns.min), do: nil, else: prev))
      |> assign(:next, if(after_max?(next, assigns.max), do: nil, else: next))

    ~H"""
    <div id={@id} class={["flex flex-wrap items-center gap-2", @class]} {@rest}>
      <div class="join">
        <.link
          :if={@prev}
          patch={@path.(@prev)}
          class="btn btn-sm join-item"
          aria-label={gettext("Previous day")}
          title={gettext("Previous day")}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </.link>
        <span
          :if={is_nil(@prev)}
          class="btn btn-sm join-item btn-disabled"
          aria-disabled="true"
          aria-label={gettext("Previous day")}
        >
          <.icon name="hero-chevron-left" class="w-4 h-4" />
        </span>

        <form
          :if={@picker}
          id={"#{@id}-picker"}
          phx-change={@pick_event}
          class="join-item"
          onsubmit="return false"
        >
          <input
            type="date"
            name="date"
            value={Date.to_iso8601(@date)}
            min={@min && Date.to_iso8601(@min)}
            max={@max && Date.to_iso8601(@max)}
            aria-label={gettext("Date")}
            class="input input-sm join-item rounded-none w-38"
          />
        </form>
        <span :if={!@picker} class="btn btn-sm join-item pointer-events-none font-normal">
          {UtilsDate.short_with_year(@date)}
        </span>

        <.link
          :if={@next}
          patch={@path.(@next)}
          class="btn btn-sm join-item"
          aria-label={gettext("Next day")}
          title={gettext("Next day")}
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </.link>
        <span
          :if={is_nil(@next)}
          class="btn btn-sm join-item btn-disabled"
          aria-disabled="true"
          aria-label={gettext("Next day")}
        >
          <.icon name="hero-chevron-right" class="w-4 h-4" />
        </span>
      </div>

      <.link
        :if={
          @date != @today_date and not after_max?(@today_date, @max) and
            not before_min?(@today_date, @min)
        }
        patch={@path.(@today_date)}
        class="btn btn-sm btn-ghost"
      >
        {gettext("Today")}
      </.link>
      <span :if={@date == @today_date} class="text-sm text-base-content/60">
        {gettext("Today")}
      </span>
    </div>
    """
  end

  @doc """
  Reads a `"YYYY-MM-DD"` URL or form value into a date. Anything that is
  not a date — missing, garbage — is `today`; a date outside `min` / `max`
  is clamped to the nearer end.

  Options: `:today` (default UTC today), `:min`, `:max`.
  """
  @spec parse_param(term(), keyword()) :: Date.t()
  def parse_param(value, opts \\ []) do
    today = Keyword.get(opts, :today) || Date.utc_today()

    date =
      case is_binary(value) && Date.from_iso8601(String.trim(value)) do
        {:ok, date} -> date
        _ -> today
      end

    date
    |> clamp_min(opts[:min])
    |> clamp_max(opts[:max])
  end

  defp clamp_min(date, nil), do: date
  defp clamp_min(date, min), do: if(Date.compare(date, min) == :lt, do: min, else: date)

  defp clamp_max(date, nil), do: date
  defp clamp_max(date, max), do: if(Date.compare(date, max) == :gt, do: max, else: date)

  defp before_min?(_date, nil), do: false
  defp before_min?(date, min), do: Date.compare(date, min) == :lt

  defp after_max?(_date, nil), do: false
  defp after_max?(date, max), do: Date.compare(date, max) == :gt
end
