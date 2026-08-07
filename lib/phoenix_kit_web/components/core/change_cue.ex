defmodule PhoenixKitWeb.Components.Core.ChangeCue do
  @moduledoc """
  Tells the reader that a choice they just made changed something they
  can't currently see.

  Long forms hide detail behind collapsed sections, and a choice in one
  place often rewrites another: picking a preset rewrites a checklist,
  enabling an extension adds a permission row. The change is real,
  correct, and invisible — it lands inside something nobody is looking at.

  Deliberately NOT called "flash": Phoenix already has flash messages,
  and the capability is "something over here changed", not an animation.

  ## Using it

  Mark the regions that can be cued — `<.accordion cue>` does this, or add
  `data-change-region` to any container yourself — give the things inside
  stable DOM ids, and push the ids that changed:

      # in the LiveView, after working out what actually changed
      {:noreply, ChangeCue.push(socket, ["ext-row-files", "authz-row-upload_files"],
        announce: gettext("Permissions updated"))}

  The server says WHAT changed. The client decides how to show it, because
  only the client knows what is on screen:

    * the region is open → the changed rows highlight;
    * the region is closed → the region highlights AND keeps a quiet
      "changed" marker. Opening it replays the row highlights and clears
      the marker.

  The marker is what makes this survive reality: a highlight that plays
  while the reader is scrolled elsewhere is simply lost, and a timer that
  forgets after N seconds turns "what changed here?" into a race. The
  marker persists until the region is opened.

  ## What it will not do

  Scroll the page, open a section, move focus, or raise a toast. A cue
  that moves the page under someone mid-form is worse than no cue.

  ## Accessibility

  A pulse tells a screen-reader user nothing, so a closed-region cue also
  writes to a polite live region — the region's own words (`:announce`),
  once per push, coalesced. Never assertive, never per-row, and never
  repeated when the deferred highlights replay.

  `prefers-reduced-motion` keeps the outline and the marker, drops the
  pulse.
  """

  use Phoenix.Component

  @event "pk:change-cue"

  @doc """
  Cues the elements whose ids are given.

  Options:

    * `:announce` — what a screen reader should hear when the change lands
      in a CLOSED region. Say the result ("Permissions updated"), not the
      mechanics. Omit it and nothing is announced.

  A push with no ids is a no-op, so callers can pipe an empty diff through
  without a conditional.
  """
  @spec push(Phoenix.LiveView.Socket.t(), [String.t()], keyword()) ::
          Phoenix.LiveView.Socket.t()
  def push(socket, ids, opts \\ [])

  def push(socket, [], _opts), do: socket

  def push(socket, ids, opts) when is_list(ids) do
    payload = %{targets: Enum.uniq(ids)}

    payload =
      case Keyword.get(opts, :announce) do
        text when is_binary(text) and text != "" -> Map.put(payload, :announce, text)
        _ -> payload
      end

    Phoenix.LiveView.push_event(socket, @event, payload)
  end

  @doc "The client event name, exposed so consumers can assert on it."
  @spec event() :: String.t()
  def event, do: @event

  @doc """
  The marker shown on a closed region that changed while it was closed.

  Rendered inside the region's own summary by `<.accordion cue>`; it stays
  hidden until the client sets `data-changed` on the region, and the CSS
  lives in the same stylesheet as the highlight so a consumer adds nothing.
  """
  attr :label, :string, default: nil

  def change_marker(assigns) do
    assigns = assign_new(assigns, :label, fn -> "Updated" end)

    ~H"""
    <span data-change-marker class="badge badge-primary badge-sm ml-2 hidden">
      {@label}
    </span>
    """
  end
end
