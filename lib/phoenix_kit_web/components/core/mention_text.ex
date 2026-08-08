defmodule PhoenixKitWeb.Components.Core.MentionText do
  @moduledoc """
  Renders free text that may contain `@` and `#` mentions, resolved for the
  person looking at it.

      <.mention_text text={@comment.content} scope={@phoenix_kit_current_scope} />

  Each mention becomes one of three things, and which one is a permission
  decision made per viewer, at render:

    * **a link** — they may open it, so they get the live title and a real
      deep-link. The title is re-resolved rather than taken from the text,
      so a renamed record reads correctly.

    * **plain text** — it is gone, or its module was uninstalled. They get
      the label the author saw, unlinked. This is the case that justifies
      keeping the label in the text at all.

    * **a redacted chip** — it exists and they may not see it. They are told
      that much and nothing more: no title, no uuid in the markup, no href.
      Clicking asks the owners for access.

  The third case is a deliberate product choice, and it has a cost worth
  knowing: showing "you don't have access to this" reveals that *something*
  is there. That is the Discord model, chosen because the alternative —
  silently dropping the mention — leaves a sentence with a hole in it and no
  way to act. What is never revealed is the title, and a refreshed title is
  never shown to someone who cannot open the record.

  ## Wiring the request-access click

  The chip pushes `"pk_request_access"` with `type` and `uuid`. Handle it
  yourself, or get the handler and the dialog for free:

      use PhoenixKit.Mentions.RequestAccess

  Without either, the click is inert — the chip still renders and still
  tells the reader why they cannot see the thing.

  ## No JavaScript

  Everything here is server-rendered. The typeahead that *inserts* mentions
  is a progressive enhancement; reading them has never needed JS.
  """
  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token
  alias PhoenixKit.Utils.Routes

  attr :text, :string, default: nil
  attr :scope, :any, default: nil, doc: "the viewer — decides what resolves"
  attr :class, :any, default: nil

  attr :allow_request, :boolean,
    default: true,
    doc: "offer \"ask for access\" on a redacted mention"

  attr :rest, :global

  def mention_text(assigns) do
    assigns =
      assign_new(assigns, :pieces, fn ->
        %{text: text, scope: scope} = assigns
        context = Mentions.context(text, user_uuid: user_uuid(scope), scope: scope)

        text
        |> Token.split()
        |> Enum.map(fn
          %Token{} = token ->
            {token, Map.get(context, {token.type, token.uuid}, %{state: :missing})}

          piece ->
            piece
        end)
      end)

    ~H"""
    <span class={@class} {@rest}><%= for piece <- @pieces do %>
      <.piece
        piece={piece}
        allow_request={@allow_request}
      />
    <% end %></span>
    """
  end

  # One rendered fragment: either a run of ordinary text or a resolved
  # mention. Kept as its own component so the three mention states are
  # readable side by side rather than nested in a comprehension.
  attr :piece, :any, required: true
  attr :allow_request, :boolean, required: true

  defp piece(%{piece: text} = assigns) when is_binary(text) do
    ~H"{@piece}"
  end

  defp piece(%{piece: {%Token{} = token, %{state: :ok} = info}} = assigns) do
    assigns = assign(assigns, token: token, info: info)

    ~H"""
    <.link
      :if={@info[:path]}
      navigate={href(@info)}
      class="link link-primary font-medium no-underline hover:underline"
    >{prefix_for(@token)}{@info[:title]}</.link><span
      :if={is_nil(@info[:path])}
      class="font-medium"
    >{prefix_for(@token)}{@info[:title]}</span>
    """
  end

  # Deleted, or the module that owned it is no longer installed. The
  # author's words survive; the link does not.
  defp piece(%{piece: {%Token{} = token, %{state: :missing}}} = assigns) do
    assigns = assign(assigns, token: token)

    ~H"""
    <span class="opacity-70" title={gettext("No longer available")}>{prefix_for(@token)}{@token.label}</span>
    """
  end

  defp piece(%{piece: {%Token{} = token, %{state: :forbidden}}} = assigns) do
    assigns = assign(assigns, token: token)

    ~H"""
    <button
      :if={@allow_request}
      type="button"
      phx-click="pk_request_access"
      phx-value-type={@token.type}
      phx-value-uuid={@token.uuid}
      class="badge badge-ghost badge-sm gap-1 align-baseline cursor-pointer"
    >
      <.icon name="hero-lock-closed" class="w-3 h-3" />
      {gettext("No access")}
    </button><span
      :if={not @allow_request}
      class="badge badge-ghost badge-sm gap-1 align-baseline"
    >
      <.icon name="hero-lock-closed" class="w-3 h-3" />
      {gettext("No access")}
    </span>
    """
  end

  # An `@` keeps its sigil so a ping reads as a ping; a `#` does not,
  # because the record's own title is the better label in a sentence.
  defp prefix_for(%Token{kind: :user}), do: "@"
  defp prefix_for(_), do: ""

  defp href(%{path: path, prefixed: false}), do: path
  defp href(%{path: path}), do: Routes.path(path)

  defp user_uuid(%{user: %{uuid: uuid}}), do: uuid
  defp user_uuid(_), do: nil
end
