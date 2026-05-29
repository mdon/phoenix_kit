defmodule PhoenixKitWeb.Components.MediaBrowser.Embed do
  @moduledoc """
  One-line embedder for `PhoenixKitWeb.Components.MediaBrowser`.

  LiveView uploads must live on the parent socket (not the LiveComponent),
  so embedding the MediaBrowser requires three small pieces of plumbing on
  the parent: an `allow_upload`, a `"validate"` event stub for the upload
  channel, and a `handle_info` delegator for component→parent messages.

  This module bundles all three into a single `use` call.

  ## Usage

      defmodule MyAppWeb.MediaPage do
        use MyAppWeb, :live_view
        use PhoenixKitWeb.Components.MediaBrowser.Embed

        def mount(_params, _session, socket) do
          {:ok, socket}
        end
      end

  Then in the template:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        parent_uploads={@uploads}
      />

  ## What gets injected

  * `on_mount` — calls `MediaBrowser.setup_uploads/1` so `@uploads.media_files`
    is available on every mount of this LiveView.
  * Fallback `handle_event("validate", _, socket)` — absorbs the upload
    channel's `phx-change` events. User-defined clauses with other event
    names still win because they are defined first.
  * Fallback `handle_info({MediaBrowser, _, _}, socket)` — forwards to
    `MediaBrowser.handle_parent_info/2` for component registration and
    upload piping.
  * Fallback `handle_info({:leaf_changed, _}, socket)` — routes
    Leaf editor content updates from the sidebar comments (when
    PhoenixKitComments is installed) to
    `PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2`.
    Without this, comment Leaf editors render but the typed
    content never reaches the server. The clause only injects
    when `PhoenixKitComments.Web.CommentsComponent` is loaded —
    otherwise it's compiled away. User-defined `:leaf_changed`
    clauses (e.g. for a post-content editor on the same page)
    still win because they are defined first.

  All fallbacks are injected via `@before_compile`, so user clauses
  declared earlier in the module match before them.
  """

  alias PhoenixKitWeb.Components.MediaBrowser

  def on_mount(:default, _params, _session, socket) do
    {:cont, MediaBrowser.setup_uploads(socket)}
  end

  defmacro __using__(_opts) do
    quote do
      on_mount({PhoenixKitWeb.Components.MediaBrowser.Embed, :default})
      @before_compile PhoenixKitWeb.Components.MediaBrowser.Embed
    end
  end

  defmacro __before_compile__(_env) do
    # Fully-qualified references on purpose: this code is injected into the
    # caller's module, where aliasing from Embed wouldn't be in scope.
    #
    # The leaf-forwarder is always injected (not gated at MACRO-compile
    # time on Code.ensure_loaded?) because phoenix_kit_comments may not be
    # loaded yet when phoenix_kit compiles — they're sibling deps with no
    # compile-order guarantee. Runtime `Code.ensure_loaded?` inside the
    # clause does the right thing: when the comments package is installed,
    # the event is forwarded; when it isn't, the clause is a no-op.
    quote do
      def handle_event("validate", _params, socket), do: {:noreply, socket}

      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      def handle_info(
            {PhoenixKitWeb.Components.MediaBrowser, _, _} = msg,
            socket
          ) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        PhoenixKitWeb.Components.MediaBrowser.handle_parent_info(msg, socket)
      end

      def handle_info({:leaf_changed, _} = msg, socket) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        mod = PhoenixKitComments.Web.CommentsComponent

        if Code.ensure_loaded?(mod) and function_exported?(mod, :forward_leaf_event, 2) do
          # `apply/3` (instead of `mod.forward_leaf_event(...)`) so the
          # call doesn't compile-time-bind to a module that may not be
          # available — phoenix_kit_comments is an optional sibling
          # dep with no compile-order guarantee.
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          case apply(mod, :forward_leaf_event, [msg, socket]) do
            {:noreply, _} = result -> result
            :pass -> {:noreply, socket}
          end
        else
          {:noreply, socket}
        end
      end
    end
  end
end
