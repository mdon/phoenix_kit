defmodule PhoenixKit.Mentions do
  @moduledoc """
  Cross-module `@` pings and `#` record links.

  Typing `@` anywhere a person can write free text offers people; typing `#`
  offers records from every installed module. The picked result is stored as
  a self-contained token (`PhoenixKit.Mentions.Token`), indexed for reverse
  lookup (`PhoenixKit.Mentions.Mention`), and rendered per viewer.

  ## The three halves

    * **Search** — `search/2` fans out across every module that declares a
      searchable resource type, in parallel, with a hard deadline. A module
      that is slow, raises, or has no index costs its own results and
      nothing else: the popup shows what came back.

    * **Resolve** — reuses `PhoenixKit.ResourceLinks`, which already turns
      `(type, uuid)` into a title and a deep-link for the Activity feed and
      Comments. Batched per type, so a page of mentions costs one call per
      distinct type, not one per mention.

    * **Visibility** — `visible/3` asks each type's handler which of these
      uuids THIS viewer may see. Separate from resolution on purpose: the
      searcher and the later reader are different people, and a record that
      was visible when it was linked may not be when it is read.

  ## What a viewer sees

  | Situation | Rendered as |
  |---|---|
  | Resolves, viewer may see it | live title, real deep-link |
  | Gone, or its module uninstalled | the author's stored label, plain text |
  | Exists, viewer may NOT see it | a redacted chip — never the title |

  The middle row is why the label lives in the text. The bottom row is the
  rule that matters: a mention must never show a viewer a title they are not
  allowed to know, and it must never *refresh* one. What it does show is
  that something is there — the Discord model — with a way to ask for
  access, because "you can't see this" is only useful with a next step.

  ## Making a module's records mentionable

  Add the type to `resource_links/0` pointing at a handler module, then give
  that handler two functions beyond the `resolve_comment_resources/1` it
  already needs for Activity and Comments:

      defmodule MyApp.Widgets.Links do
        # Already required for deep-linking in Activity/Comments
        def resolve_comment_resources(uuids), do: %{...}

        # New: the `#` typeahead. MUST scope to the searcher.
        def search_resources(query, opts) do
          user_uuid = opts[:user_uuid]
          ...
          [%{type: "widget", uuid: w.uuid, title: w.name, subtitle: "Widget"}]
        end

        # New: which of these may this viewer see? Batched.
        def visible_resource_uuids(uuids, opts), do: [...]
      end

  A handler without `search_resources/2` is resolvable but not offerable —
  reasonable for a type that should be linkable from an activity row yet
  never suggested by the typeahead.

  `visible_resource_uuids/2` is what makes a type mentionable at all.
  Without it, a mention of that type renders REDACTED, because a token can
  be typed by hand into any textarea and "the module didn't implement the
  check" must never mean "show it to everyone". The only exception is
  `user`: the `@` typeahead already lists every pingable account to anyone
  who can reach the admin area, so a name is not something a mention can
  leak.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Activity
  alias PhoenixKit.Mentions.{Mention, Token, Users}
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.ResourceLinks
  alias PhoenixKit.Settings

  # A typeahead that takes longer than this is worse than one with fewer
  # results: the popup has to keep up with typing. Whatever has answered by
  # the deadline is what gets shown.
  @search_deadline_ms 250
  @search_concurrency 6
  @default_limit 8

  @enabled_setting "mentions_enabled"

  defp repo, do: RepoHelper.repo()

  @doc """
  Master switch. Defaults ON — the feature is additive and inert until
  someone actually types a trigger.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Settings.get_boolean_setting(@enabled_setting, true)
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @spec enabled_setting_key() :: String.t()
  def enabled_setting_key, do: @enabled_setting

  # ── Search ──────────────────────────────────────────────────────────

  @doc """
  Candidates for the typeahead.

  `kind` is `:user` for `@` (core's users only — a ping is always a person)
  or `:resource` for `#` (every module that opted in).

  Options:

    * `:user_uuid` — who is searching. Handlers MUST scope to this; a
      typeahead that offers records the searcher cannot open is itself the
      leak.
    * `:limit` — max results overall (default #{@default_limit}).

  Never raises: a handler that blows up contributes nothing and is logged.
  """
  @spec search(:user | :resource, String.t(), keyword()) :: [map()]
  def search(kind, query, opts \\ [])

  def search(_kind, query, _opts) when not is_binary(query), do: []

  def search(kind, query, opts) do
    query = String.trim(query)
    limit = Keyword.get(opts, :limit, @default_limit)

    cond do
      not enabled?() -> []
      kind == :user -> search_users(query, limit, opts)
      true -> search_resources(query, limit, opts)
    end
  end

  defp search_users(query, limit, opts) do
    Users.search(query, Keyword.put(opts, :limit, limit))
  rescue
    e ->
      Logger.warning("[Mentions] user search failed: #{Exception.message(e)}")
      []
  end

  defp search_resources(query, limit, opts) do
    # One call per MODULE, not per type. A handler that owns several types
    # (projects owns both `project` and `project_task`) answers for all of
    # them in one call and stamps each result with its own type — calling
    # it once per registered type ran the same search twice and returned
    # every row twice.
    handlers =
      searchable_handlers()
      |> Enum.group_by(fn {_type, mod} -> mod end, fn {type, _mod} -> type end)
      |> Enum.map(fn {mod, types} -> {List.first(Enum.sort(types)), mod} end)

    handlers
    |> Task.async_stream(
      fn {type, mod} -> safe_search(mod, type, query, opts) end,
      max_concurrency: @search_concurrency,
      timeout: @search_deadline_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, results} -> results
      # A module that timed out or died costs only its own results. The
      # popup showing three of four modules beats showing nothing.
      {:exit, _} -> []
    end)
    # A handler that stamps its own types can still hand back the same
    # record twice; the popup must never show a duplicate row.
    |> Enum.uniq_by(&{&1[:type], &1[:uuid]})
    |> rank(query)
    |> Enum.take(limit)
  end

  defp safe_search(mod, type, query, opts) do
    # apply/3, not a direct call: the module is discovered at runtime and
    # may not exist in this install at all.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    results = apply(mod, :search_resources, [query, opts])

    results
    |> List.wrap()
    |> Enum.map(fn result ->
      result
      |> Map.take([:type, :uuid, :title, :subtitle, :icon])
      |> Map.put_new(:type, type)
      |> Map.put(:kind, :resource)
    end)
    |> Enum.filter(&(is_binary(&1[:uuid]) and is_binary(&1[:title])))
  rescue
    e ->
      Logger.warning(
        "[Mentions] #{inspect(mod)} search_resources failed: #{Exception.message(e)}"
      )

      []
  catch
    :exit, _ -> []
  end

  # Exact title, then prefix, then the rest — alphabetical inside each tier
  # so the order is stable between keystrokes. Cross-module relevance
  # scoring is a thing to add when there is real usage to tune it against;
  # inventing weights now would be guessing.
  defp rank(results, query) do
    q = String.downcase(query)

    Enum.sort_by(results, fn r ->
      title = String.downcase(r[:title] || "")

      tier =
        cond do
          title == q -> 0
          String.starts_with?(title, q) -> 1
          true -> 2
        end

      {tier, title}
    end)
  end

  @doc """
  Handler modules that can be searched, as `%{resource_type => module}`.

  Derived from the same `resource_links/0` registry that powers deep-linking
  — a type is offerable only if it is already resolvable, so a mention can
  never be created that cannot later be rendered.
  """
  @spec searchable_handlers() :: %{String.t() => module()}
  def searchable_handlers do
    ResourceLinks.handlers()
    |> Enum.filter(fn {_type, mod} -> exports?(mod, :search_resources, 2) end)
    |> Map.new()
  end

  # ── Visibility ──────────────────────────────────────────────────────

  @doc """
  Of `uuids` for `type`, the ones this viewer may see.

  A handler with no `visible_resource_uuids/2` is treated as public — see
  the moduledoc. Anything that raises fails CLOSED (nothing visible): a
  broken permission check must not become an open door.
  """
  # Types whose records are not secret, and which therefore need no
  # per-viewer check. Only people: the `@` typeahead already lists every
  # pingable account to anyone who can reach the admin area, so a name is
  # not something a mention can leak. Everything else must opt in.
  @public_types ~w(user)

  # A plain list, not a MapSet: dialyzer treats MapSet as opaque and flags
  # every spec that names it (the same false positive the flag resolver
  # works around). Callers that need membership build their own set.
  #
  # FAIL-CLOSED for anything not on @public_types. A token can be typed by
  # hand into any textarea, so "this type didn't implement the check" must
  # not mean "show it to everyone" — most registered types (posts, files,
  # CRM contacts and companies, integrations) declare no check at all, and
  # treating silence as consent renders their titles and live links to any
  # reader who is handed a uuid.
  @spec visible(String.t(), [String.t()], keyword()) :: [String.t()]
  def visible(_type, [], _opts), do: []

  def visible(type, uuids, opts) do
    cond do
      type in @public_types ->
        uuids

      mod = Map.get(ResourceLinks.handlers(), type) ->
        if exports?(mod, :visible_resource_uuids, 2) do
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          mod |> apply(:visible_resource_uuids, [uuids, opts]) |> List.wrap()
        else
          []
        end

      true ->
        # No handler at all: nothing can resolve it either, so this renders
        # as the author's stored label — plain text, no link, no leak.
        uuids
    end
  rescue
    e ->
      Logger.warning("[Mentions] visibility check for #{type} failed: #{Exception.message(e)}")
      []
  catch
    :exit, _ -> []
  end

  # ── Resolution for rendering ────────────────────────────────────────

  @doc """
  Everything a renderer needs for the mentions in `text`, in one pass.

  Returns `%{{type, uuid} => %{state, title, path, prefixed}}` where `state`
  is `:ok`, `:missing`, or `:forbidden`. Batched per type: a page with
  thirty mentions across three types costs three resolve calls and three
  visibility calls.
  """
  @spec context(String.t() | nil, keyword()) :: map()
  def context(text, opts \\ []) do
    tokens = Token.parse(text)

    if tokens == [] do
      %{}
    else
      tokens
      |> Enum.group_by(& &1.type)
      |> Enum.reduce(%{}, fn {type, group}, acc ->
        uuids = group |> Enum.map(& &1.uuid) |> Enum.uniq()
        allowed = type |> visible(uuids, opts) |> MapSet.new()

        # Resolve ONLY what the viewer may see. Resolving the rest would
        # pull titles nobody is allowed to read into memory a template
        # could accidentally print.
        resolved = allowed |> Enum.to_list() |> resolve_titles(type)

        Enum.reduce(group, acc, fn token, inner ->
          Map.put_new(inner, {type, token.uuid}, state_for(token, allowed, resolved))
        end)
      end)
    end
  end

  defp state_for(token, allowed, resolved) do
    cond do
      not MapSet.member?(allowed, token.uuid) ->
        %{state: :forbidden}

      info = Map.get(resolved, token.uuid) ->
        %{
          state: :ok,
          title: info[:title] || token.label,
          path: info[:path],
          prefixed: Map.get(info, :prefixed, true)
        }

      true ->
        %{state: :missing}
    end
  end

  defp resolve_titles([], _type), do: %{}

  defp resolve_titles(uuids, type) do
    uuids
    |> Enum.map(&%{resource_type: type, resource_uuid: &1})
    |> ResourceLinks.resolve()
    |> Map.new(fn {{_type, uuid}, info} -> {uuid, info} end)
  rescue
    e ->
      Logger.warning("[Mentions] resolve for #{type} failed: #{Exception.message(e)}")
      %{}
  end

  # ── Index ───────────────────────────────────────────────────────────

  @doc """
  Rebuilds the index for one field of one record from its text, and returns
  the mentions that are NEW since last time.

  Call this from the durable save — creating or updating the comment, the
  task, the note. Never from a keystroke or an autosave draft: the return
  value is what gets notified, and a debounce would ping on every pause.

  The delete-then-insert is scoped to this `source_field`, so a record with
  two mentionable fields keeps them independent.
  """
  @spec sync(String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, [Mention.t()]} | {:error, term()}
  def sync(source_type, source_uuid, text, opts \\ []) do
    field = Keyword.get(opts, :field, "body")
    actor_uuid = Keyword.get(opts, :actor_uuid)
    tokens = text |> Token.parse() |> Enum.uniq_by(&{&1.type, &1.uuid})

    existing = list_for_source(source_type, source_uuid, field)
    existing_keys = MapSet.new(existing, &{&1.target_type, &1.target_uuid})

    repo().transaction(fn ->
      from(m in Mention,
        where:
          m.source_type == ^source_type and m.source_uuid == ^source_uuid and
            m.source_field == ^field
      )
      |> repo().delete_all()

      Enum.map(tokens, fn token ->
        %Mention{}
        |> Mention.changeset(%{
          source_type: source_type,
          source_uuid: source_uuid,
          source_field: field,
          kind: Atom.to_string(token.kind),
          target_type: token.type,
          target_uuid: token.uuid,
          label: token.label,
          actor_uuid: actor_uuid,
          # Carry the delivered mark across a re-save: the row is recreated
          # every time the text is saved, and without this every edit would
          # look like a brand-new mention and ping again.
          notified_at: previously_notified_at(existing, token)
        })
        |> repo().insert!()
      end)
    end)
    |> case do
      {:ok, inserted} ->
        {:ok,
         Enum.reject(inserted, &MapSet.member?(existing_keys, {&1.target_type, &1.target_uuid}))}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[Mentions] sync failed: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  end

  defp previously_notified_at(existing, token) do
    Enum.find_value(existing, fn m ->
      if m.target_type == token.type and m.target_uuid == token.uuid, do: m.notified_at
    end)
  end

  @doc "Every mention recorded for one field of one record."
  @spec list_for_source(String.t(), String.t(), String.t()) :: [Mention.t()]
  def list_for_source(source_type, source_uuid, field \\ "body") do
    from(m in Mention,
      where:
        m.source_type == ^source_type and m.source_uuid == ^source_uuid and
          m.source_field == ^field
    )
    |> repo().all()
  rescue
    _ -> []
  end

  @doc """
  What links here: every record mentioning this one, newest first.

  The backlink panel on a record's own page. Not permission-filtered — the
  caller knows who is asking and what their own module's rules are.
  """
  @spec list_backlinks(String.t(), String.t(), keyword()) :: [Mention.t()]
  def list_backlinks(target_type, target_uuid, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(m in Mention,
      where: m.target_type == ^target_type and m.target_uuid == ^target_uuid,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> repo().all()
  rescue
    _ -> []
  end

  @doc """
  Delivers the `@` pings among `mentions` and marks them sent.

  Call it with what `sync/4` returned — those are the ones that are new.
  Everything else is filtered here rather than by the caller:

    * `#` links never notify. Telling a record's watchers it was referenced
      is a different product (and a noisy one); the reverse index is enough
      to build a "mentioned in" panel when that is actually wanted.
    * mentioning yourself does nothing.
    * someone who cannot open the containing record is not told about it.
      An email about a comment that 403s on click is worse than silence.

  Delivery itself is core's activity → notification bridge, so a ping lands
  wherever that person already reads things and obeys their existing
  preferences and channels.
  """
  @spec notify(list(), keyword()) :: :ok
  def notify(mentions, opts \\ [])

  def notify([], _opts), do: :ok

  def notify(mentions, opts) do
    source_type = Keyword.get(opts, :source_type)
    source_uuid = Keyword.get(opts, :source_uuid)
    preview = opts |> Keyword.get(:preview) |> preview_text()

    mentions
    |> Enum.filter(&(&1.kind == "user" and is_nil(&1.notified_at)))
    |> Enum.reject(&(&1.target_uuid == &1.actor_uuid))
    |> Enum.filter(&can_open_source?(&1, source_type, source_uuid))
    # Claim BEFORE sending: whoever wins the conditional update sends, and
    # a concurrent save of the same text wins nothing and sends nothing.
    |> claim_for_delivery()
    |> Enum.each(fn mention ->
      Activity.log(%{
        action: "mention.created",
        module: "mentions",
        mode: "manual",
        actor_uuid: mention.actor_uuid,
        resource_type: source_type || mention.source_type,
        resource_uuid: source_uuid || mention.source_uuid,
        target_uuid: mention.target_uuid,
        metadata: %{
          "notification_text" => "You were mentioned",
          "preview" => preview
        }
      })
    end)

    :ok
  rescue
    e ->
      Logger.warning("[Mentions] notify failed: #{Exception.message(e)}")
      :ok
  end

  # Can the mentioned person actually open the thing they'd be notified
  # about? Asked through the same per-type visibility contract everything
  # else uses. A source type with no handler is assumed reachable — the
  # same documented fail-open as `visible/3`, and the alternative would
  # silently drop every ping in every module that hasn't opted in yet.
  defp can_open_source?(mention, source_type, source_uuid) do
    type = source_type || mention.source_type
    uuid = source_uuid || mention.source_uuid

    case Map.get(ResourceLinks.handlers(), type) do
      nil ->
        true

      mod ->
        if exports?(mod, :visible_resource_uuids, 2) do
          args = [[uuid], [user_uuid: mention.target_uuid]]
          # credo:disable-for-next-line Credo.Check.Refactor.Apply
          allowed = apply(mod, :visible_resource_uuids, args)
          uuid in List.wrap(allowed)
        else
          true
        end
    end
  rescue
    _ -> false
  end

  defp preview_text(nil), do: nil

  defp preview_text(text) do
    text
    |> Token.to_plain_text()
    |> String.trim()
    |> String.slice(0, 140)
  end

  @doc """
  CLAIMS delivery for these mentions, returning the ones this caller won.

  `WHERE notified_at IS NULL` is what makes it a claim rather than a
  stamp: two saves of the same field racing (a double submit, two tabs)
  both see an unnotified row and would both send. Only the update that
  actually changes a row may deliver.
  """
  @spec claim_for_delivery([Mention.t()]) :: [Mention.t()]
  def claim_for_delivery([]), do: []

  def claim_for_delivery(mentions) do
    uuids = Enum.map(mentions, & &1.uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_count, claimed} =
      from(m in Mention, where: m.uuid in ^uuids and is_nil(m.notified_at), select: m.uuid)
      |> repo().update_all([set: [notified_at: now]], returning: false)
      |> case do
        {count, nil} -> {count, []}
        other -> other
      end

    claimed = MapSet.new(claimed || [])
    Enum.filter(mentions, &MapSet.member?(claimed, &1.uuid))
  rescue
    _ -> []
  end

  defp exports?(mod, fun, arity) do
    is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end
end
