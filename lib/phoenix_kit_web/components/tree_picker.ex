defmodule PhoenixKitWeb.Components.TreePicker do
  @moduledoc """
  A searchable, collapsible tree for picking one record — or several —
  out of a nested set (a parent category, a folder, a page), instead of an
  indented flat `<select>`. Build the tree with `PhoenixKit.Utils.Tree`.

  **Controlled.** The parent owns what is picked: it passes `value` and
  handles `{PhoenixKitWeb.Components.TreePicker, id, value}`, sent whenever
  the admin picks (a single id, or the new list with `multiple`). The
  component owns only the search text and which rows are open. The parent
  builds the `tree`, so what to leave out — a record's own subtree, the
  row being moved — is its call, and it must check a received id against
  live data before acting on it: the tree may be minutes old.

      <.live_component
        module={PhoenixKitWeb.Components.TreePicker}
        id="parent-picker"
        tree={[Tree.root(gettext("Top level"), @parent_tree)]}
        value={@parent_pick}
        field
        name="page[parent_uuid]"
      />

      def handle_info({TreePicker, "parent-picker", id}, socket),
        do: {:noreply, assign(socket, :parent_pick, id)}

  ## Attributes

    * `id` (required)
    * `tree` (required) — `PhoenixKit.Utils.Tree` nodes
    * `value` — the picked id (`nil` for none), or a list with `multiple`
    * `pickable` — the node `:type`s that can be picked, or `:all`
      (default); other rows only open and close
    * `multiple` — check any number of rows; a row that cannot be picked
      then carries a box that checks or clears every pickable row under it
    * `current` — the id to badge "Current" (where the record is now)
    * `field` — `true` shows the picked row's path and a Change button,
      the tree only while changing (for forms); `false` (default) shows the
      tree at once (for dialogs). Single pickers only
    * `path_skip` — node `:type`s left out of the shown path
    * `placeholder` — the path text while nothing is picked
    * `search_placeholder` — the search box's hint (default "Search...")
    * `disabled` — field mode only: shows the path, offers no Change and
      posts nothing, like a disabled `<select>`
    * `name` — renders hidden inputs so a surrounding form posts the value
    * `post` — what a hidden input posts for an id: `:id` (default; the
      `"root"` row posts `""`, "no parent") or a function of the id

  **Inside a form.** The search box has no `name`, and its hook
  (`TreePickerSearch`) keeps its `input`/`change` events and Enter from
  reaching the surrounding form — typing here must not run the form's
  `phx-change` or submit it. Every other control is a `type="button"`.
  """
  use PhoenixKitWeb, :live_component

  alias PhoenixKit.Utils.Tree

  @impl true
  def mount(socket) do
    {:ok, assign(socket, query: "", open: MapSet.new(), search_open: MapSet.new(), panel?: false)}
  end

  @impl true
  def update(assigns, socket) do
    before = Map.take(socket.assigns, [:tree, :value, :current])

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:value, fn -> nil end)
      |> assign_new(:pickable, fn -> :all end)
      |> assign_new(:multiple, fn -> false end)
      |> assign_new(:current, fn -> nil end)
      |> assign_new(:field, fn -> false end)
      |> assign_new(:path_skip, fn -> [] end)
      |> assign_new(:placeholder, fn -> "—" end)
      |> assign_new(:search_placeholder, fn -> gettext("Search...") end)
      |> assign_new(:name, fn -> nil end)
      |> assign_new(:post, fn -> :id end)
      |> assign_new(:disabled, fn -> false end)

    {:ok, socket |> reopen(before) |> assign_under() |> refilter()}
  end

  # The rows that show what is picked open on the first render, and again
  # whenever the parent hands in another value, current row or a refreshed
  # tree — a row picked elsewhere, or a tree that arrived late, must not sit
  # under a closed parent. The echo of this picker's own pick is not such a
  # change (picking a whole branch must not pop it open), and rows the admin
  # closed stay closed otherwise.
  defp reopen(socket, before) do
    now = Map.take(socket.assigns, [:tree, :value, :current])
    sent = socket.assigns[:sent]

    # The echo arrives once: forget the pick then, so the same value handed
    # in again later (after another one) counts as handed in.
    socket =
      if before != %{} and before.value != now.value and now.value == sent,
        do: assign(socket, :sent, :none),
        else: socket

    cond do
      before == %{} ->
        assign(socket, :open, opened_at(socket.assigns))

      handed_in?(before, now, sent) ->
        update(socket, :open, &MapSet.union(&1, opened_at(socket.assigns)))

      true ->
        socket
    end
  end

  defp handed_in?(before, now, sent) do
    before.tree != now.tree or before.current != now.current or
      (before.value != now.value and now.value != sent)
  end

  # Multiple mode: every branch's pickable rows, worked out once per tree
  # rather than walked again for each row on every render.
  defp assign_under(%{assigns: %{multiple: true}} = socket),
    do: assign(socket, :under, Tree.pickable_under(socket.assigns.tree, socket.assigns.pickable))

  defp assign_under(socket), do: assign(socket, :under, %{})

  # The rows above what is picked (or where the record is now) start open,
  # so the admin sees it in place; so does the current row itself, whose
  # children are the likeliest destination, and a root row, which only
  # holds the rest of the tree.
  defp opened_at(assigns) do
    ids = List.wrap(assigns.value) ++ List.wrap(assigns.current)
    roots = for %{id: id} = node <- assigns.tree, Map.get(node, :type) == :root, do: id

    MapSet.new(
      roots ++
        List.wrap(assigns.current) ++
        Enum.flat_map(ids, &Tree.ancestor_ids(assigns.tree, &1))
    )
  end

  defp refilter(socket) do
    {shown, open} = Tree.filter(socket.assigns.tree, socket.assigns.query)
    assign(socket, shown: shown, search_open: MapSet.new(open))
  end

  @impl true
  def handle_event("search", %{"value" => value}, socket) when is_binary(value) do
    {:noreply, socket |> assign(:query, value) |> refilter()}
  end

  def handle_event("toggle", %{"id" => id}, socket) when is_binary(id) do
    key = if searching?(socket.assigns), do: :search_open, else: :open
    set = Map.fetch!(socket.assigns, key)
    set = if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)

    {:noreply, assign(socket, key, set)}
  end

  # Only a row the tree offers, of a pickable type, is taken.
  def handle_event("pick", %{"id" => id}, socket) when is_binary(id) do
    %{tree: tree, pickable: pickable} = socket.assigns

    if Tree.member?(tree, id, pickable) do
      value =
        if socket.assigns.multiple, do: toggle(List.wrap(socket.assigns.value), id), else: id

      send(self(), {__MODULE__, socket.assigns.id, value})
      {:noreply, assign(socket, panel?: false, sent: value)}
    else
      {:noreply, socket}
    end
  end

  # A branch's box: every pickable row under it, checked when any is not,
  # else cleared. The whole branch counts — rows a search hides too.
  def handle_event("pick_all", %{"id" => id}, %{assigns: %{multiple: true}} = socket)
      when is_binary(id) do
    %{tree: tree, pickable: pickable} = socket.assigns

    case Tree.find(tree, id) do
      %{children: children} ->
        under = Tree.ids_of(children, pickable)
        value = List.wrap(socket.assigns.value)
        picked = MapSet.new(value)

        value =
          if Enum.all?(under, &MapSet.member?(picked, &1)) do
            drop = MapSet.new(under)
            Enum.reject(value, &MapSet.member?(drop, &1))
          else
            value ++ Enum.reject(under, &MapSet.member?(picked, &1))
          end

        send(self(), {__MODULE__, socket.assigns.id, value})
        {:noreply, assign(socket, :sent, value)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("open_panel", _params, %{assigns: %{disabled: true}} = socket),
    do: {:noreply, socket}

  def handle_event("open_panel", _params, socket), do: {:noreply, assign(socket, :panel?, true)}
  def handle_event("close_panel", _params, socket), do: {:noreply, assign(socket, :panel?, false)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp toggle(value, id), do: if(id in value, do: List.delete(value, id), else: value ++ [id])

  defp searching?(assigns), do: String.trim(assigns.query) != ""

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        shown_open: if(searching?(assigns), do: assigns.search_open, else: assigns.open),
        tree_visible?: not assigns.field or (assigns.panel? and not assigns.disabled),
        path: path(assigns),
        picked: MapSet.new(List.wrap(assigns.value))
      )

    ~H"""
    <div id={@id} class="flex flex-col gap-2 min-w-0" data-tree-picker>
      <input
        :for={value <- posted(@value, @post)}
        :if={@name && not @disabled}
        type="hidden"
        name={@name}
        value={value}
      />

      <div :if={@field} class="flex flex-wrap items-center gap-2">
        <.path_line id={"#{@id}-path"} names={@path} placeholder={@placeholder} />
        <button
          :if={not @panel? and not @disabled}
          type="button"
          id={"#{@id}-change"}
          phx-click="open_panel"
          phx-target={@myself}
          class="btn btn-outline btn-sm ml-auto"
        >
          <.icon name="hero-folder-open" class="w-4 h-4" />
          {gettext("Change")}
        </button>
        <button
          :if={@panel?}
          type="button"
          phx-click="close_panel"
          phx-target={@myself}
          class="btn btn-ghost btn-sm ml-auto"
        >
          {gettext("Cancel")}
        </button>
      </div>

      <div
        :if={@tree_visible?}
        class={["flex flex-col gap-2", @field && "rounded-box border border-base-300 p-2"]}
      >
        <label class="input input-sm w-full">
          <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-50" />
          <input
            id={"#{@id}-search"}
            type="text"
            value={@query}
            phx-hook="TreePickerSearch"
            phx-target={@myself}
            placeholder={@search_placeholder}
            aria-label={@search_placeholder}
            autocomplete="off"
            class="grow"
          />
        </label>

        <div class="max-h-72 overflow-y-auto">
          <p :if={@shown == []} class="px-2 py-3 text-sm text-base-content/50">
            {gettext("No matches.")}
          </p>
          <ul :if={@shown != []} id={"#{@id}-tree"} role="tree" class="text-sm">
            <.tree_row
              :for={node <- @shown}
              node={node}
              open={@shown_open}
              picked={@picked}
              current={@current}
              pickable={@pickable}
              multiple={@multiple}
              under={@under}
              myself={@myself}
            />
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp path(%{value: value} = assigns) when is_binary(value),
    do: Tree.path(assigns.tree, value, assigns.path_skip)

  defp path(_assigns), do: []

  # A single picker always posts its field (blank while nothing is picked);
  # a multiple one posts one per picked row.
  defp posted(value, post) when is_list(value), do: Enum.map(value, &post_value(&1, post))
  defp posted(nil, _post), do: [""]
  defp posted(value, post), do: [post_value(value, post)]

  defp post_value(id, :id), do: if(id == Tree.root_id(), do: "", else: id)
  defp post_value(id, fun) when is_function(fun, 1), do: fun.(id) || ""

  attr :id, :string, required: true
  attr :names, :list, required: true
  attr :placeholder, :string, required: true

  defp path_line(assigns) do
    ~H"""
    <nav id={@id} class="min-w-0">
      <span :if={@names == []} class="text-sm text-base-content/50">{@placeholder}</span>
      <ol :if={@names != []} class="flex flex-wrap items-center gap-1 text-sm">
        <li :for={{name, index} <- Enum.with_index(@names)} class="flex items-center gap-1">
          <.icon :if={index > 0} name="hero-chevron-right-mini" class="w-4 h-4 text-base-content/30" />
          <span class={
            if index == length(@names) - 1, do: "font-medium", else: "text-base-content/70"
          }>
            {name}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  attr :node, :map, required: true
  attr :open, :any, required: true
  attr :picked, :any, required: true
  attr :current, :string, default: nil
  attr :pickable, :any, required: true
  attr :multiple, :boolean, required: true
  attr :under, :map, required: true
  attr :myself, :any, required: true

  defp tree_row(assigns) do
    node = assigns.node

    assigns =
      assign(assigns,
        expanded?: MapSet.member?(assigns.open, node.id),
        branch?: node.children != [],
        pickable?: Tree.of_type?(node, assigns.pickable),
        selected?: MapSet.member?(assigns.picked, node.id),
        branch_check: branch_check(assigns)
      )

    ~H"""
    <li
      role="treeitem"
      aria-expanded={@branch? && to_string(@expanded?)}
      aria-selected={to_string(@selected?)}
    >
      <div class={[
        "flex items-center gap-1 rounded-field pr-2 hover:bg-base-200",
        (@selected? and not @multiple) && "bg-primary/10"
      ]}>
        <button
          :if={@branch?}
          type="button"
          phx-click="toggle"
          phx-value-id={@node.id}
          phx-target={@myself}
          class="btn btn-ghost btn-xs btn-square shrink-0"
          aria-label={if @expanded?, do: gettext("Collapse"), else: gettext("Expand")}
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="w-4 h-4"
          />
        </button>
        <span :if={not @branch?} class="w-6 shrink-0"></span>
        <button
          :if={@multiple and not @pickable? and @branch_check != nil}
          type="button"
          phx-click="pick_all"
          phx-value-id={@node.id}
          phx-target={@myself}
          data-pick-all={@node.id}
          class="shrink-0"
          aria-label={gettext("Select all")}
        >
          <.check_box state={@branch_check} />
        </button>
        <button
          type="button"
          phx-click={if @pickable?, do: "pick", else: "toggle"}
          phx-value-id={@node.id}
          phx-target={@myself}
          data-tree-node={@node.id}
          class={[
            "flex flex-1 items-center gap-2 py-1.5 text-left min-w-0",
            not @pickable? && "text-base-content/70"
          ]}
        >
          <.check_box :if={@multiple and @pickable?} state={if @selected?, do: :all, else: :none} />
          <.icon :if={@node[:icon]} name={@node.icon} class="w-4 h-4 shrink-0 text-base-content/50" />
          <span class="truncate">{@node.name}</span>
          <span :if={@node[:hint]} class="text-xs text-base-content/50 shrink-0">{@node.hint}</span>
          <span :if={@node[:badge]} class="badge badge-xs badge-ghost">{@node.badge}</span>
          <span :if={@node.id == @current} class="badge badge-xs badge-outline ml-auto shrink-0">
            {gettext("Current")}
          </span>
        </button>
      </div>
      <ul :if={@branch? and @expanded?} role="group" class="ml-3 pl-2 border-l border-base-content/10">
        <.tree_row
          :for={child <- @node.children}
          node={child}
          open={@open}
          picked={@picked}
          current={@current}
          pickable={@pickable}
          multiple={@multiple}
          under={@under}
          myself={@myself}
        />
      </ul>
    </li>
    """
  end

  # A branch's box in multiple mode: :all / :some / :none of the pickable
  # rows under it (in the whole tree, not only what a search shows), or
  # nil when there are none.
  defp branch_check(%{multiple: true, node: node, under: under, picked: picked}) do
    case Map.get(under, node.id, []) do
      [] ->
        nil

      ids ->
        case Enum.count(ids, &MapSet.member?(picked, &1)) do
          0 -> :none
          count when count == length(ids) -> :all
          _ -> :some
        end
    end
  end

  defp branch_check(_assigns), do: nil

  attr :state, :atom, required: true

  defp check_box(assigns) do
    ~H"""
    <span
      data-check={@state}
      aria-hidden="true"
      class={[
        "inline-flex w-4 h-4 shrink-0 items-center justify-center rounded-sm border",
        if(@state == :none,
          do: "border-base-content/30",
          else: "border-primary bg-primary text-primary-content"
        )
      ]}
    >
      <.icon :if={@state == :all} name="hero-check-mini" class="w-3.5 h-3.5" />
      <.icon :if={@state == :some} name="hero-minus-mini" class="w-3.5 h-3.5" />
    </span>
    """
  end
end
