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

  ## URL sync (shareable folder links)

  Pass `url_sync: true` (or `url_sync: [id: "your-component-id"]`) to make
  the embedded browser reflect the current folder / search / page / view
  in the page URL — so a deep link like `…?folder=<uuid>` reopens that
  folder on reload and can be shared with someone else.

      use PhoenixKitWeb.Components.MediaBrowser.Embed, url_sync: true

      # multiple browsers, or a non-default component id:
      use PhoenixKitWeb.Components.MediaBrowser.Embed,
        url_sync: [id: "my-media-browser"]

  With `url_sync` on, the host template must pass the controlled-mode
  attrs through to the component:

      <.live_component
        module={PhoenixKitWeb.Components.MediaBrowser}
        id="media-browser"
        on_navigate={:navigate}
        initial_params={@initial_params}
        parent_uploads={@uploads}
      />

  Everything else is automatic: `initial_params` is parsed from the URL
  in `on_mount`, folder navigation `push_patch`es the new params into the
  address bar, and a reload feeds them back to the component. The folder
  is tracked by **uuid** (stable across renames); an unknown / out-of-scope
  uuid falls back to root. The base path is taken from the live URL, so
  any router prefix is respected.

  Single-browser-per-page is assumed: the query keys (`folder`, `q`,
  `page`, `orphaned`, `view`) are not namespaced per component, so two
  url-synced browsers on one page would fight over them. Give only one
  the `url_sync` option in that case.

  Note: `url_sync` injects `handle_params/3`. Don't also define your own
  `handle_params/3` on a url-synced LiveView — call
  `MediaBrowser.Embed.parse_nav_params/1` from yours instead and pass the
  result to the component via `send_update(.., nav_params: ...)`.

  ## What gets injected

  * `on_mount` — calls `MediaBrowser.setup_uploads/1` so `@uploads.media_files`
    is available on every mount of this LiveView. With `url_sync`, also
    assigns `:initial_params` parsed from the mount params.
  * Fallback `handle_event("validate", _, socket)` — absorbs the upload
    channel's `phx-change` events. User-defined clauses with other event
    names still win because they are defined first.
  * With `url_sync`: `handle_params/3` (feeds URL params to the component)
    and a `handle_info({MediaBrowser, id, {:navigate, _}}, socket)` clause
    that `push_patch`es — injected before the generic fallback so it wins.
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

  # ── on_mount ────────────────────────────────────────────────────
  # `:default` — uploads only (the no-url_sync path; unchanged).
  def on_mount(:default, _params, _session, socket) do
    {:cont, MediaBrowser.setup_uploads(socket)}
  end

  # `{:embed, false}` — same as :default. `{:embed, %{...}}` — url_sync on:
  # parse the URL params into :initial_params so the component opens the
  # shared folder on first render (controlled mode reads @initial_params).
  def on_mount({:embed, false}, _params, _session, socket) do
    {:cont, MediaBrowser.setup_uploads(socket)}
  end

  def on_mount({:embed, %{}}, params, _session, socket) do
    socket =
      socket
      |> MediaBrowser.setup_uploads()
      |> Phoenix.Component.assign(:initial_params, parse_nav_params(params))

    {:cont, socket}
  end

  # ── Shared URL <-> nav-params helpers (public so a host with its own
  # handle_params can reuse the exact parse/build the macro uses) ──────

  @doc """
  Parse a LiveView params map into the `nav_params` shape MediaBrowser's
  controlled mode expects (`folder`, `q`, `page`, `filter_orphaned`,
  `view`).
  """
  def parse_nav_params(params) do
    %{
      folder: params["folder"],
      q: params["q"] || "",
      page: parse_page(params["page"]),
      filter_orphaned: params["orphaned"] == "1",
      view: params["view"]
    }
  end

  @doc """
  Build the query-string map from a `{:navigate, params}` payload —
  omitting defaults so a root, unsearched, first-page view yields a clean
  bare URL.
  """
  def build_nav_query(p) do
    folder = p[:folder]
    q = p[:q] || ""
    page = p[:page] || 1
    filter_orphaned = p[:filter_orphaned] || false
    view = p[:view]

    %{}
    |> then(&if(folder, do: Map.put(&1, "folder", folder), else: &1))
    |> then(&if(q != "", do: Map.put(&1, "q", q), else: &1))
    |> then(&if(page > 1, do: Map.put(&1, "page", page), else: &1))
    |> then(&if(filter_orphaned, do: Map.put(&1, "orphaned", "1"), else: &1))
    |> then(&if(view == "all", do: Map.put(&1, "view", "all"), else: &1))
  end

  defp parse_page(p) do
    case Integer.parse(p || "1") do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defmacro __using__(opts) do
    sync =
      case Keyword.get(opts, :url_sync, false) do
        false -> false
        true -> %{id: "media-browser"}
        kw when is_list(kw) -> %{id: Keyword.get(kw, :id, "media-browser")}
      end

    on_mount_arg = if sync, do: {:embed, sync}, else: :default

    quote do
      @phoenix_kit_mb_url_sync unquote(Macro.escape(sync))
      on_mount({PhoenixKitWeb.Components.MediaBrowser.Embed, unquote(Macro.escape(on_mount_arg))})
      @before_compile PhoenixKitWeb.Components.MediaBrowser.Embed
    end
  end

  # URL-sync clauses (only when enabled). The {:navigate} handle_info must
  # precede the generic {MediaBrowser, _, _} fallback or the fallback's
  # handle_parent_info would swallow it. Extracted from __before_compile__
  # to keep that macro's complexity down. Fully-qualified refs on purpose:
  # this is injected into the caller's module.
  defp url_sync_clauses(false), do: quote(do: nil)

  defp url_sync_clauses(%{id: component_id}) do
    quote do
      def handle_params(params, uri, socket) do
        socket =
          Phoenix.Component.assign(socket, :__phoenix_kit_mb_path__, URI.parse(uri).path)

        if Phoenix.LiveView.connected?(socket) do
          # credo:disable-for-next-line Credo.Check.Design.AliasUsage
          nav = PhoenixKitWeb.Components.MediaBrowser.Embed.parse_nav_params(params)
          # credo:disable-for-next-line Credo.Check.Design.AliasUsage
          Phoenix.LiveView.send_update(PhoenixKitWeb.Components.MediaBrowser,
            id: unquote(component_id),
            nav_params: nav
          )
        end

        {:noreply, socket}
      end

      # credo:disable-for-next-line Credo.Check.Design.AliasUsage
      def handle_info(
            {PhoenixKitWeb.Components.MediaBrowser, unquote(component_id), {:navigate, nav}},
            socket
          ) do
        # credo:disable-for-next-line Credo.Check.Design.AliasUsage
        qs = PhoenixKitWeb.Components.MediaBrowser.Embed.build_nav_query(nav)
        base = socket.assigns[:__phoenix_kit_mb_path__] || "/"
        url = if qs == %{}, do: base, else: base <> "?" <> URI.encode_query(qs)
        {:noreply, Phoenix.LiveView.push_patch(socket, to: url)}
      end
    end
  end

  defmacro __before_compile__(env) do
    sync = Module.get_attribute(env.module, :phoenix_kit_mb_url_sync, false)
    url_sync_quoted = url_sync_clauses(sync)

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
      require Logger

      def handle_event("validate", _params, socket), do: {:noreply, socket}

      unquote(url_sync_quoted)

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
            {:noreply, _} = result ->
              result

            :pass ->
              {:noreply, socket}

            other ->
              # Optional cross-package contract: forward_leaf_event/2 is
              # expected to return {:noreply, socket} or :pass. Anything
              # else shouldn't crash the host LiveView — degrade gracefully
              # and log so a contract drift in phoenix_kit_comments is
              # diagnosable.
              Logger.warning(
                "PhoenixKitComments.Web.CommentsComponent.forward_leaf_event/2 " <>
                  "returned an unexpected value (#{inspect(other)}); ignoring."
              )

              {:noreply, socket}
          end
        else
          {:noreply, socket}
        end
      end
    end
  end
end
