defmodule PhoenixKit.Modules.Storage.Reorganizer.ResourceSource do
  @moduledoc """
  A reorganizer `PhoenixKit.Modules.Storage.Reorganizer.Source` built from a
  declaration, for a module that keeps one media folder per record through
  `PhoenixKit.Modules.Storage.ResourceFolders`. The module states what its
  records are; this module applies the whole `Source` contract to them —
  one implementation of the rules instead of one per module:

      defmodule MyModule.MediaReorganizer do
        alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource

        def plan(actor_uuid, opts \\\\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

        defp spec do
          %{
            source: "my_module",
            app: :my_module,
            pending_prefix: "my-module-attachment-pending-",
            kinds: [
              %{
                kind: :item,
                schema: MyModule.Item,
                prefix: "my-module-item-",
                pointer: {:data, "files_folder_uuid"},
                live: &where(&1, [r], r.status != "deleted")
              }
            ]
          }
        end
      end

  ## The declaration

    * `:source` — the source name on every action
    * `:app` — the OTP app whose `:attachments_parent_folder` /
      `:attachments_folder_name` hooks decide where folders belong
    * `:kinds` — the record kinds, parents first (their folders move in
      this order)
    * `:pending_prefix` — the name prefix of folders made for unsaved
      records, when the module makes any; stale empty ones are trashed
    * `:noun` — what a record is called in reports (default `"record"`)
    * `:name_hook` — `false` for a module whose runtime never asks the
      `:attachments_folder_name` hook (it finds folders by the
      deterministic name only): the plan then never proposes a host name
      its uploads would not follow (default `true`)
    * `:extra` — `fun(actor_uuid, opts) -> [action]` for reports only this
      module can make, appended to the plan

  Each kind:

    * `:kind`, `:schema` — the atom the parent hook receives, the schema
    * `:prefix` — the deterministic folder name is `prefix <> uuid`
    * `:pointer` — where the record stores its folder uuid
      (`t:PhoenixKit.Modules.Storage.ResourceFolders.pointer/0`), or `nil`
      for a module that finds folders by name only
    * `:live` — `fun(query) -> query` keeping the records that are live
      (default: every row); a record that is not live is an orphan's owner
    * `:subject` — what the parent hook's third argument is: `:record` (the
      full row, the default) or `:uuid`
    * `:label` — the field naming a record in reports (default `:name`)
    * `:fields` — further columns candidate detection reads (default `[]`)
    * `:order` — `fun(records) -> records` reordering a kind's records
      (e.g. parents before children within the kind)
    * `:orphan` — `:not_live` (default) reports the folder of a missing or
      not-live record; `:missing` only a missing one

  ## Rules applied

  The `Source` moduledoc is the contract; how each case is decided:

    * No parent hook configured → report-only (orphans, pending folders);
      a configured hook that is not callable is one `:hook_error`.
    * A candidate is a record with a live folder — through its pointer or
      by its deterministic name anywhere; nothing else reaches a hook, and
      candidates are reloaded as full rows before any hook sees them.
    * The parent hook failing (raise, throw, exit, anything but
      `{:ok, uuid}` / `{:ok, nil}` / `nil`) skips the record into one
      `:hook_error`; so does a failing name hook. Logs name the failure's
      shape only.
    * A pointer-found folder keeps its name unless it still has the
      deterministic or a pending name; then the host name is proposed.
    * By name: the host name directly under the parent (not adopted when
      another record's pointer claims it — the deterministic name is
      wanted instead), then the deterministic name under the parent, then
      at the root. Two of these live at once is a `:duplicate`; a copy
      anywhere else is `:relocated`, never moved. With a root answer and
      no copy at the root, a single copy elsewhere is adopted in place
      (`:hook_nil`) and several are a `:duplicate`.
    * A root answer never moves a folder that has a parent (`:hook_nil`).
    * Two records on one folder, or two moves onto one target, are one
      `:duplicate` each; neither moves.
    * Orphans: deterministic-named folders at the root or under a parent a
      hook named, whose record is missing or not live, and no record
      claims. Pending folders: empty and older than `pending_days` →
      `:trash` (report-only without a hook); not empty → a report naming
      their files.
    * A module with a pointer back-fills it (`after_move`) and renames a
      taken target `"name (N)"`; one without reports the conflict.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink, ResourceFolders}
  alias PhoenixKit.Modules.Storage.Reorganizer.Action

  @default_pending_days 7
  @max_listed 10
  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @type kind_spec :: %{
          required(:kind) => atom(),
          required(:schema) => module(),
          required(:prefix) => String.t(),
          optional(:pointer) => ResourceFolders.pointer() | nil,
          optional(:live) => (Ecto.Queryable.t() -> Ecto.Query.t()),
          optional(:subject) => :record | :uuid,
          optional(:label) => atom(),
          optional(:fields) => [atom()],
          optional(:order) => ([struct()] -> [struct()]),
          optional(:orphan) => :not_live | :missing
        }

  @type spec :: %{
          required(:source) => String.t(),
          required(:app) => atom(),
          required(:kinds) => [kind_spec()],
          optional(:pending_prefix) => String.t() | nil,
          optional(:noun) => String.t(),
          optional(:name_hook) => boolean(),
          optional(:extra) => (String.t() | nil, keyword() -> [map()])
        }

  @doc "The plan for `spec` (see the moduledoc) — `Source.plan/2`'s answer."
  @spec plan(spec(), String.t() | nil, keyword()) :: [map()]
  def plan(spec, actor_uuid, opts \\ []) do
    spec = normalize(spec)
    records = light_records(spec)
    pointer_claims = pointer_claims(records)

    {resource_actions, resolved_claims, scope_parents, hook_on?} =
      case hook_status(spec.app) do
        :ok ->
          {actions, claims, parents} = resource_plan(spec, records, pointer_claims, actor_uuid)
          {actions, claims, parents, true}

        {:invalid, reason} ->
          {[invalid_hook_action(spec, reason)], %{}, [], false}

        :none ->
          {[], %{}, [], false}
      end

    claimed = Map.merge(pointer_claims, resolved_claims)

    resource_actions ++
      orphan_actions(spec, scope_parents, claimed) ++
      pending_actions(
        spec,
        Keyword.get(opts, :pending_days, @default_pending_days),
        claimed,
        hook_on?
      ) ++
      spec.extra.(actor_uuid, opts)
  end

  defp normalize(spec) do
    kinds =
      Enum.map(spec.kinds, fn kind ->
        Map.merge(
          %{
            pointer: nil,
            live: & &1,
            subject: :record,
            label: :name,
            fields: [],
            order: & &1,
            orphan: :not_live
          },
          kind
        )
      end)

    %{
      source: spec.source,
      app: spec.app,
      kinds: kinds,
      pending_prefix: Map.get(spec, :pending_prefix),
      noun: Map.get(spec, :noun, "record"),
      name_hook?: Map.get(spec, :name_hook, true),
      extra: Map.get(spec, :extra, fn _actor, _opts -> [] end),
      pointer?: Enum.any?(kinds, & &1.pointer)
    }
  end

  # ── Records ─────────────────────────────────────────────────────────

  # Only the columns candidate detection needs, one query per kind, in the
  # kinds' order and then by `inserted_at`/uuid (or the kind's own order).
  defp light_records(spec) do
    Enum.flat_map(spec.kinds, fn kind ->
      fields = Enum.uniq([:uuid, :inserted_at, kind.label | kind.fields] ++ status_field(kind))

      kind.schema
      |> kind.live.()
      |> order_by([r], asc: r.inserted_at, asc: r.uuid)
      |> select_light(fields, kind.pointer)
      |> repo().all()
      |> order_kind(kind)
      |> Enum.map(fn {record, pointer} ->
        %{
          kind: kind,
          record: record,
          pointer: cast(pointer),
          name: kind.prefix <> record.uuid
        }
      end)
    end)
  end

  defp status_field(kind),
    do: if(:status in kind.schema.__schema__(:fields), do: [:status], else: [])

  defp select_light(query, fields, nil),
    do: select(query, [r], {struct(r, ^fields), nil})

  defp select_light(query, fields, {:column, column}),
    do: select(query, [r], {struct(r, ^fields), field(r, ^column)})

  defp select_light(query, fields, {map_field, key}),
    do: select(query, [r], {struct(r, ^fields), fragment("?->>?", field(r, ^map_field), ^key)})

  defp order_kind(rows, kind) do
    by_uuid = Map.new(rows, fn {record, _pointer} = row -> {record.uuid, row} end)

    rows
    |> Enum.map(&elem(&1, 0))
    |> kind.order.()
    |> Enum.map(&Map.fetch!(by_uuid, &1.uuid))
  end

  # Every live folder a record points at — claimed whether or not a hook
  # is configured, so no plan ever trashes or orphans it.
  defp pointer_claims(records) do
    case records |> Enum.map(& &1.pointer) |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        from(f in Folder, where: f.uuid in ^uuids and is_nil(f.trashed_at), select: f.uuid)
        |> repo().all()
        |> set()
    end
  end

  # ── Hooks ───────────────────────────────────────────────────────────

  defp hook_status(app) do
    case Application.get_env(app, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if Code.ensure_loaded?(mod) and
             (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2)),
           do: :ok,
           else: {:invalid, {:not_callable, mod, fun}}

      other ->
        {:invalid, {:bad_config, other}}
    end
  end

  defp invalid_hook_action(spec, reason) do
    %{
      source: spec.source,
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: invalid_hook_reason(reason)
    }
  end

  defp invalid_hook_reason({:not_callable, mod, fun}),
    do: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"

  defp invalid_hook_reason({:bad_config, other}),
    do:
      "configured parent hook #{inspect(other)} is not a {module, function} tuple — " <>
        "invalid config, not callable"

  defp parent_answer(spec, entry, actor_uuid) do
    subject = if entry.kind.subject == :uuid, do: entry.record.uuid, else: entry.record

    case ResourceFolders.parent_hook(spec.app, entry.kind.kind, actor_uuid, subject) do
      {:ok, parent_uuid} ->
        {:ok, parent_uuid}

      {:error, reason} ->
        log_hook_failure(spec, :parent, entry, reason)
        :error
    end
  end

  # The host's name for the record's folder, the deterministic one when the
  # host has none to give.
  defp host_name(%{name_hook?: false}, entry, _actor_uuid), do: {:ok, entry.name}

  defp host_name(spec, entry, actor_uuid) do
    case ResourceFolders.name_hook(spec.app, entry.record, actor_uuid) do
      {:ok, nil} ->
        {:ok, entry.name}

      {:ok, name} ->
        {:ok, name}

      :unconfigured ->
        {:ok, entry.name}

      {:error, reason} ->
        log_hook_failure(spec, :name, entry, reason)
        :error
    end
  end

  # Which hook, for which record, and the failure's shape — never the
  # exception's message or the hook's answer, which can carry its arguments.
  defp log_hook_failure(spec, hook, entry, reason) do
    key = if hook == :parent, do: :attachments_parent_folder, else: :attachments_folder_name

    Logger.warning(
      "[#{spec.source}] attachments #{hook} hook #{inspect(Application.get_env(spec.app, key))} " <>
        "failed for #{inspect(entry.kind.kind)} #{entry.record.uuid}: " <>
        ResourceFolders.describe_failure(reason)
    )
  end

  # ── Candidates and their folders ────────────────────────────────────

  defp resource_plan(spec, records, pointer_claims, actor_uuid) do
    by_pointer = folders_by_uuid(Enum.map(records, & &1.pointer))
    by_name = folders_by_name(Enum.map(records, & &1.name))

    candidates =
      records
      |> Enum.filter(fn r ->
        (r.pointer && Map.has_key?(by_pointer, r.pointer)) || Map.has_key?(by_name, r.name)
      end)
      |> hydrate()
      |> Enum.with_index(fn entry, index -> Map.put(entry, :index, index) end)

    {parented, parent_errors} = resolve_parents(spec, candidates, actor_uuid)

    scope_parents =
      parented |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {pointer_track, name_track} =
      Enum.split_with(parented, &(&1.pointer && Map.has_key?(by_pointer, &1.pointer)))

    {pointer_entries, pointer_errors} =
      pointer_track
      |> Enum.map(
        &pointer_entry(spec, &1, Map.fetch!(by_pointer, &1.pointer), by_name, actor_uuid)
      )
      |> split_errors()

    {name_entries, name_errors} =
      name_entries(spec, name_track, by_name, pointer_claims, actor_uuid)

    entries =
      (pointer_entries ++ name_entries)
      |> Enum.sort_by(& &1.index)
      |> Enum.map(&root_guard/1)

    spec
    |> actions_for(
      entries,
      pointer_claims,
      holders(records, by_pointer),
      parent_errors ++ pointer_errors ++ name_errors
    )
    |> then(fn {actions, claims} -> {actions, claims, scope_parents} end)
  end

  # `folder_uuid => [{record_uuid, label}]` for every live record whose
  # pointer names a live folder — hook or no hook, so a co-owner whose hook
  # failed still keeps the folder from moving under the other.
  defp holders(records, by_pointer) do
    records
    |> Enum.filter(&(&1.pointer && Map.has_key?(by_pointer, &1.pointer)))
    |> Enum.group_by(& &1.pointer, &{&1.record.uuid, label(&1)})
  end

  # Hooks may read any column, so a candidate reaches them as its full row;
  # one query per kind, candidates only.
  defp hydrate(candidates) do
    full =
      candidates
      |> Enum.group_by(& &1.kind.schema, & &1.record.uuid)
      |> Enum.flat_map(fn {schema, uuids} ->
        from(r in schema, where: r.uuid in ^uuids)
        |> repo().all()
        |> Enum.map(&{{schema, &1.uuid}, &1})
      end)
      |> Map.new()

    Enum.flat_map(candidates, fn entry ->
      case Map.get(full, {entry.kind.schema, entry.record.uuid}) do
        nil -> []
        record -> [%{entry | record: record}]
      end
    end)
  end

  defp resolve_parents(spec, candidates, actor_uuid) do
    {ok, errors} =
      Enum.reduce(candidates, {[], []}, fn entry, {ok, errors} ->
        case parent_answer(spec, entry, actor_uuid) do
          {:ok, parent_uuid} -> {[Map.put(entry, :parent_uuid, parent_uuid) | ok], errors}
          :error -> {ok, [{label(entry), :parent} | errors]}
        end
      end)

    {Enum.reverse(ok), Enum.reverse(errors)}
  end

  defp split_errors(results) do
    {entries, errors} = Enum.split_with(results, &match?(%{}, &1))
    {entries, Enum.map(errors, fn {:error, error} -> error end)}
  end

  defp pointer_entry(spec, entry, folder, by_name, actor_uuid) do
    stray = by_name |> Map.get(entry.name, []) |> Enum.reject(&(&1.uuid == folder.uuid))
    base = Map.merge(entry, %{folder: folder, name: nil, ambiguous: nil, stray: stray})

    if module_named?(spec, folder.name, entry.name) do
      case host_name(spec, entry, actor_uuid) do
        {:ok, name} -> %{base | name: name}
        :error -> {:error, {label(entry), :name}}
      end
    else
      base
    end
  end

  defp module_named?(spec, folder_name, deterministic) do
    folder_name == deterministic or
      (is_binary(spec.pending_prefix) and String.starts_with?(folder_name, spec.pending_prefix))
  end

  defp name_entries(spec, candidates, by_name, pointer_claims, actor_uuid) do
    {named, errors} =
      Enum.reduce(candidates, {[], []}, fn entry, {named, errors} ->
        case host_name(spec, entry, actor_uuid) do
          {:ok, host} -> {[Map.put(entry, :host, host) | named], errors}
          :error -> {named, [{label(entry), :name} | errors]}
        end
      end)

    named = Enum.reverse(named)
    host_folders = host_folders(named)

    {Enum.map(named, &name_entry(&1, by_name, host_folders, pointer_claims)),
     Enum.reverse(errors)}
  end

  # A host-named folder directly under each candidate's parent (the root
  # included), one query for the plan.
  defp host_folders(entries) do
    pairs =
      entries
      |> Enum.filter(&(&1.host != &1.name))
      |> Enum.map(&{&1.host, &1.parent_uuid})
      |> Enum.uniq()

    case pairs do
      [] ->
        %{}

      pairs ->
        names = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        parents = pairs |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
        wanted = set(pairs)

        from(f in Folder, where: f.name in ^names and is_nil(f.trashed_at))
        |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parents)
        |> order_by([f], asc: f.inserted_at, asc: f.uuid)
        |> repo().all()
        |> Enum.filter(&Map.has_key?(wanted, {&1.name, &1.parent_uuid}))
        |> Enum.reduce(%{}, fn f, acc -> Map.put_new(acc, {f.name, f.parent_uuid}, f) end)
    end
  end

  defp name_entry(entry, by_name, host_folders, pointer_claims) do
    {host_folder, wanted} = host_folder(entry, host_folders, pointer_claims)
    matches = Map.get(by_name, entry.name, [])
    looked_at = looked_at(matches, entry.parent_uuid)
    base = Map.merge(entry, %{folder: nil, name: nil, ambiguous: nil, stray: []})

    case {host_folder, looked_at} do
      {%Folder{}, [_ | _]} ->
        %{base | ambiguous: [host_folder | looked_at], stray: without(matches, looked_at)}

      {nil, [_, _] = both} ->
        %{base | ambiguous: both, stray: without(matches, both)}

      {%Folder{}, []} ->
        %{base | folder: host_folder, name: wanted, stray: matches}

      {nil, [legacy]} ->
        %{base | folder: legacy, name: wanted, stray: without(matches, [legacy])}

      {nil, []} when is_nil(entry.parent_uuid) ->
        adopt_elsewhere(base, matches, wanted)

      {nil, []} ->
        %{base | stray: matches}
    end
  end

  # The host-named folder directly under the parent, unless another
  # record's pointer claims it — then the deterministic name is wanted.
  defp host_folder(entry, host_folders, pointer_claims) do
    case Map.get(host_folders, {entry.host, entry.parent_uuid}) do
      nil ->
        {nil, entry.host}

      folder ->
        if Map.has_key?(pointer_claims, folder.uuid),
          do: {nil, entry.name},
          else: {folder, entry.host}
    end
  end

  # The deterministic-named copies where the planner looks: under the
  # parent, then at the root.
  defp looked_at(matches, parent_uuid) do
    under = parent_uuid && Enum.find(matches, &(&1.parent_uuid == parent_uuid))
    Enum.reject([under, Enum.find(matches, &is_nil(&1.parent_uuid))], &is_nil/1)
  end

  # A root answer and no copy at the root: one copy under some parent is
  # the record's folder, left where it is (`root_guard/1`); several cannot
  # be told apart.
  defp adopt_elsewhere(base, [only], wanted), do: %{base | folder: only, name: wanted}
  defp adopt_elsewhere(base, [], _wanted), do: base
  defp adopt_elsewhere(base, matches, _wanted), do: %{base | ambiguous: matches}

  defp without(folders, excluded) do
    uuids = set(Enum.map(excluded, & &1.uuid))
    Enum.reject(folders, &Map.has_key?(uuids, &1.uuid))
  end

  # A root answer never moves a folder that has a parent: it stays, under
  # its own name, and only the pointer is back-filled.
  defp root_guard(%{folder: %Folder{parent_uuid: parent}, parent_uuid: nil} = entry)
       when not is_nil(parent),
       do: Map.merge(entry, %{parent_uuid: parent, name: nil, hook_nil: true})

  defp root_guard(entry), do: Map.put(entry, :hook_nil, false)

  # ── Actions ─────────────────────────────────────────────────────────

  defp actions_for(spec, entries, pointer_claims, holders, hook_errors) do
    {ambiguous, resolved} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(resolved, & &1.folder)
    {shared, unique} = shared_folders(with_folder, holders)
    movers = Enum.reject(unique, &in_place?/1)
    {converging, _solo} = groups(movers, &target/1)
    converging_indexes = converging |> List.flatten() |> Enum.map(& &1.index) |> set()

    moves =
      unique
      |> Enum.reject(&Map.has_key?(converging_indexes, &1.index))
      |> Enum.flat_map(&move_action(spec, &1))

    claims =
      set(
        Enum.map(unique, & &1.folder.uuid) ++
          Enum.flat_map(ambiguous, fn e -> Enum.map(e.ambiguous, & &1.uuid) end) ++
          Enum.map(shared, fn {folder, _labels} -> folder.uuid end) ++
          Enum.flat_map(converging, fn group -> Enum.map(group, & &1.folder.uuid) end)
      )

    strays =
      relocated_actions(
        spec,
        with_folder ++ without_folder ++ ambiguous,
        Map.merge(claims, pointer_claims)
      )

    actions =
      moves ++
        Enum.map(ambiguous, &ambiguous_action(spec, &1, pointer_claims)) ++
        Enum.map(shared, &shared_action(spec, &1)) ++
        Enum.map(converging, &converging_action(spec, &1)) ++
        strays ++
        hook_error_action(spec, hook_errors) ++
        hook_nil_action(spec, Enum.filter(entries, &Map.get(&1, :hook_nil)))

    {with_counts(actions), claims}
  end

  # Folders two or more records own — resolved to by several entries, or
  # pointed at by a record besides the entry's own — as `{folder, labels}`
  # in plan order, and the entries on a folder of their own.
  defp shared_folders(entries, holders) do
    by_folder = Enum.group_by(entries, & &1.folder.uuid)

    {shared, unique} =
      Enum.split_with(entries, fn entry ->
        on_folder = Map.fetch!(by_folder, entry.folder.uuid)
        own = Enum.map(on_folder, & &1.record.uuid)

        length(on_folder) > 1 or
          Enum.any?(Map.get(holders, entry.folder.uuid, []), fn {uuid, _} -> uuid not in own end)
      end)

    groups =
      shared
      |> Enum.group_by(& &1.folder.uuid)
      |> Map.values()
      |> Enum.sort_by(fn [first | _] -> first.index end)
      |> Enum.map(fn [first | _] = group ->
        labels =
          (Enum.map(group, &{&1.record.uuid, label(&1)}) ++
             Map.get(holders, first.folder.uuid, []))
          |> Enum.uniq_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        {first.folder, labels}
      end)

    {groups, unique}
  end

  # Groups of two or more entries sharing a key, in plan order, and the rest.
  defp groups(entries, key) do
    frequencies = Enum.frequencies_by(entries, key)
    {grouped, single} = Enum.split_with(entries, &(Map.get(frequencies, key.(&1)) > 1))

    groups =
      grouped
      |> Enum.group_by(key)
      |> Map.values()
      |> Enum.sort_by(fn [first | _] -> first.index end)

    {groups, single}
  end

  defp target(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  # Already at its target under the wanted name, or the `"name (N)"` a
  # previous run's rename-on-conflict gave it — the engine's own rule.
  defp in_place?(%{folder: folder} = entry),
    do: folder.parent_uuid == entry.parent_uuid and Action.matches_name?(folder.name, entry.name)

  defp move_action(spec, entry) do
    after_move = after_move(entry)

    if in_place?(entry) and is_nil(after_move) do
      []
    else
      [
        %{
          source: spec.source,
          kind: entry.kind.kind,
          label: label(entry),
          op: :move,
          folder: entry.folder,
          parent_uuid: entry.parent_uuid,
          name: entry.name,
          counts: nil,
          on_conflict: if(entry.kind.pointer, do: :suffix, else: :report),
          after_move: after_move
        }
      ]
    end
  end

  # The pointer back-fill, run by the engine inside the move's transaction:
  # the record is re-read and locked, and left alone when it is no longer
  # live.
  defp after_move(%{kind: %{pointer: nil}}), do: nil
  defp after_move(%{pointer: pointer, folder: %Folder{uuid: pointer}}), do: nil

  defp after_move(%{kind: kind, record: %{uuid: uuid}, pointer: planned} = entry) do
    folder_uuid = entry.folder.uuid

    fn ->
      # The row is locked on its own — a `live` filter may join other
      # tables, and FOR UPDATE refuses the nullable side of an outer join —
      # and its pointer re-read: one written since the plan (an upload, a
      # form's save) is newer than the plan and is not overwritten.
      case repo().one(locked_pointer(kind, uuid)) do
        nil ->
          {:error, :record_not_live}

        {_uuid, current} ->
          cond do
            cast(current) != planned -> {:error, :pointer_changed}
            not live?(kind, uuid) -> {:error, :record_not_live}
            true -> ResourceFolders.write_pointer(kind.schema, uuid, kind.pointer, folder_uuid)
          end
      end
    end
  end

  defp locked_pointer(%{schema: schema, pointer: {:column, column}}, uuid),
    do:
      from(r in schema,
        where: r.uuid == ^uuid,
        lock: "FOR UPDATE",
        select: {r.uuid, field(r, ^column)}
      )

  defp locked_pointer(%{schema: schema, pointer: {map_field, key}}, uuid),
    do:
      from(r in schema,
        where: r.uuid == ^uuid,
        lock: "FOR UPDATE",
        select: {r.uuid, fragment("?->>?", field(r, ^map_field), ^key)}
      )

  defp live?(kind, uuid),
    do:
      from(r in kind.schema, where: r.uuid == ^uuid, select: r.uuid)
      |> kind.live.()
      |> repo().exists?()

  defp ambiguous_action(spec, entry, pointer_claims) do
    %{
      source: spec.source,
      kind: :duplicate,
      label: label(entry),
      op: :report,
      counts: nil,
      reason: ambiguous_reason(spec, entry, pointer_claims)
    }
  end

  defp ambiguous_reason(spec, %{ambiguous: [a, b]} = entry, pointer_claims) do
    case {Map.has_key?(pointer_claims, a.uuid), Map.has_key?(pointer_claims, b.uuid)} do
      {true, false} -> owned_reason(spec, entry, a, b)
      {false, true} -> owned_reason(spec, entry, b, a)
      _ -> places_reason(entry)
    end
  end

  defp ambiguous_reason(_spec, entry, _pointer_claims), do: places_reason(entry)

  defp places_reason(%{ambiguous: folders} = entry) do
    "legacy #{entry.kind.kind} folder found live in #{length(folders)} places " <>
      "(#{Enum.map_join(folders, ", ", & &1.uuid)}) — pick one and remove the others"
  end

  defp owned_reason(spec, entry, owned, other) do
    "#{entry.kind.kind} folder found live in two places: #{owned.uuid} is already another " <>
      "#{spec.noun}'s folder, #{other.uuid} also matches — pick one and remove the other"
  end

  defp shared_action(spec, {folder, labels}) do
    %{
      source: spec.source,
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason:
        "folder #{folder.uuid} is claimed by more than one #{spec.noun}: #{Enum.join(labels, ", ")}"
    }
  end

  defp converging_action(spec, [entry | _] = group) do
    {parent_uuid, name} = target(entry)

    %{
      source: spec.source,
      kind: :duplicate,
      label: group_labels(group),
      op: :report,
      counts: nil,
      reason:
        "multiple #{spec.noun}s would move to the same destination " <>
          "(parent #{parent_uuid || "root"}, name #{name}): #{group_labels(group)}"
    }
  end

  defp group_labels(group), do: group |> Enum.map(&label/1) |> Enum.uniq() |> Enum.join(", ")

  defp relocated_actions(spec, entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray
        |> Enum.reject(&Map.has_key?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    names = parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      %{
        source: spec.source,
        kind: :relocated,
        label: label(entry),
        op: :report,
        folder: folder,
        counts: nil,
        reason: relocated_reason(entry, folder, names)
      }
    end)
  end

  # The name of each stray copy's parent that is neither the root nor the
  # record's target, in one query.
  defp parent_names(pairs) do
    uuids =
      pairs
      |> Enum.flat_map(fn {entry, folder} ->
        if folder.parent_uuid in [nil, entry.parent_uuid], do: [], else: [folder.parent_uuid]
      end)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        from(f in Folder, where: f.uuid in ^uuids, select: {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  @actor_note "whether it belongs there may depend on the acting user (the parent hook " <>
                "receives the actor and can resolve differently for another user)"

  defp relocated_reason(entry, %Folder{parent_uuid: nil} = folder, _names),
    do:
      "legacy #{entry.kind.kind} folder #{folder.uuid} is live at the media root — left " <>
        "alone, never adopted; " <> @actor_note

  defp relocated_reason(
         %{parent_uuid: parent} = entry,
         %Folder{parent_uuid: parent} = folder,
         _names
       ),
       do:
         "legacy #{entry.kind.kind} folder #{folder.uuid} is already live as a twin under the " <>
           "target parent — left alone; an eventual move there will collide, landing as " <>
           "\"name (N)\"; " <> @actor_note

  defp relocated_reason(entry, folder, names),
    do:
      "legacy #{entry.kind.kind} folder #{folder.uuid} is live under " <>
        "#{Map.get(names, folder.parent_uuid, folder.parent_uuid)} — left alone, never " <>
        "adopted; " <> @actor_note

  defp hook_error_action(_spec, []), do: []

  defp hook_error_action(spec, errors) do
    hooks = errors |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    [
      %{
        source: spec.source,
        kind: :hook_error,
        op: :report,
        label: hook_error_label(hooks),
        counts: nil,
        reason:
          "#{length(errors)} record(s) skipped: #{hook_error_subject(hooks)} raised, exited, " <>
            "or returned neither {:ok, uuid} nor nil (#{listed(Enum.map(errors, &elem(&1, 0)))})"
      }
    ]
  end

  defp hook_error_label([:parent]), do: "attachments parent hook"
  defp hook_error_label([:name]), do: "attachments folder-name hook"
  defp hook_error_label(_both), do: "attachments hooks"

  defp hook_error_subject([:parent]), do: "the configured parent hook"
  defp hook_error_subject([:name]), do: "the configured folder-name hook"
  defp hook_error_subject(_both), do: "the configured parent/folder-name hooks"

  defp hook_nil_action(_spec, []), do: []

  defp hook_nil_action(spec, entries) do
    [
      %{
        source: spec.source,
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(entries)} record(s): the parent hook answered root for a folder living " <>
            "under a parent — left in place; " <>
            @actor_note <> " (#{listed(Enum.map(entries, &label/1))})"
      }
    ]
  end

  # Up to ten names, then how many more.
  defp listed(labels) do
    case Enum.split(labels, @max_listed) do
      {shown, []} -> Enum.join(shown, ", ")
      {shown, rest} -> Enum.join(shown, ", ") <> ", … and #{length(rest)} more"
    end
  end

  defp label(%{kind: kind, record: record}) do
    case Map.get(record, kind.label) do
      value when is_binary(value) and value != "" -> value
      _ -> record.uuid
    end
  end

  # ── Orphans ─────────────────────────────────────────────────────────

  # Deterministic-named folders at the root or under a parent some hook
  # call named, that no record claims, whose record is missing or (per
  # kind) not live.
  defp orphan_actions(spec, scope_parents, claimed) do
    candidates =
      from(f in Folder,
        where: is_nil(f.trashed_at),
        where: is_nil(f.parent_uuid) or f.parent_uuid in ^scope_parents,
        order_by: [asc: f.inserted_at, asc: f.uuid]
      )
      |> where(^prefix_filter(spec.kinds))
      |> repo().all()
      |> Enum.reject(&Map.has_key?(claimed, &1.uuid))
      |> Enum.flat_map(fn folder ->
        case owner(spec, folder.name) do
          nil -> []
          {kind, uuid} -> [{folder, kind, uuid}]
        end
      end)

    case candidates do
      [] ->
        []

      candidates ->
        states = record_states(candidates)
        counts = counts_by_folder(Enum.map(candidates, &elem(&1, 0).uuid))

        Enum.flat_map(candidates, fn {folder, kind, uuid} ->
          case orphan_reason(kind, Map.get(states, {kind.schema, uuid})) do
            nil ->
              []

            why ->
              folder_counts = folder_counts(counts, folder.uuid)

              [
                %{
                  source: spec.source,
                  kind: :orphan,
                  op: :report,
                  label: folder.name,
                  folder: folder,
                  counts: folder_counts,
                  reason: "#{why}, #{elem(folder_counts, 0)} file(s)"
                }
              ]
          end
        end)
    end
  end

  defp prefix_filter(kinds) do
    Enum.reduce(kinds, dynamic(false), fn kind, acc ->
      dynamic([f], ^acc or like(f.name, ^(escape_like(kind.prefix) <> "%")))
    end)
  end

  defp escape_like(prefix), do: String.replace(prefix, ["\\", "%", "_"], &("\\" <> &1))

  # The kind whose prefix a folder name carries — the longest, so
  # `catalogue-item-` wins over `catalogue-` — and the uuid after it.
  # Pending folders belong to nobody here.
  defp owner(spec, name) do
    if is_binary(spec.pending_prefix) and String.starts_with?(name, spec.pending_prefix) do
      nil
    else
      spec.kinds
      |> Enum.filter(&String.starts_with?(name, &1.prefix))
      |> Enum.sort_by(&(-String.length(&1.prefix)))
      |> Enum.find_value(fn kind ->
        suffix = String.replace_prefix(name, kind.prefix, "")
        if Regex.match?(@uuid_regex, suffix), do: {kind, String.downcase(suffix)}
      end)
    end
  end

  # `{schema, uuid} => {:live | :not_live, status}` for the owners that
  # exist; a missing owner is absent.
  defp record_states(candidates) do
    candidates
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
    |> Enum.flat_map(fn {kind, uuids} ->
      uuids = Enum.uniq(uuids)

      live =
        from(r in kind.schema, where: r.uuid in ^uuids, select: r.uuid)
        |> kind.live.()
        |> repo().all()
        |> set()

      kind
      |> existing(uuids)
      |> Enum.map(fn {uuid, status} ->
        {{kind.schema, uuid}, {if(Map.has_key?(live, uuid), do: :live, else: :not_live), status}}
      end)
    end)
    |> Map.new()
  end

  defp existing(kind, uuids) do
    if status_field(kind) == [] do
      from(r in kind.schema, where: r.uuid in ^uuids, select: r.uuid)
      |> repo().all()
      |> Enum.map(&{&1, nil})
    else
      from(r in kind.schema, where: r.uuid in ^uuids, select: {r.uuid, r.status}) |> repo().all()
    end
  end

  defp orphan_reason(_kind, nil), do: "record missing"
  defp orphan_reason(_kind, {:live, _status}), do: nil
  defp orphan_reason(%{orphan: :missing}, {:not_live, _status}), do: nil

  defp orphan_reason(_kind, {:not_live, status}) when is_binary(status),
    do: "record status #{status}"

  defp orphan_reason(_kind, {:not_live, _status}), do: "record not live"

  # ── Pending folders ─────────────────────────────────────────────────

  defp pending_actions(%{pending_prefix: nil}, _days, _claimed, _hook_on?), do: []

  defp pending_actions(spec, pending_days, claimed, hook_on?) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      from(f in Folder,
        where: is_nil(f.trashed_at) and like(f.name, ^(escape_like(spec.pending_prefix) <> "%")),
        order_by: [asc: f.inserted_at, asc: f.uuid]
      )
      |> repo().all()
      |> Enum.reject(&Map.has_key?(claimed, &1.uuid))

    uuids = Enum.map(folders, & &1.uuid)
    counts = counts_by_folder(uuids)
    contents = pending_contents(uuids)

    Enum.flat_map(folders, fn folder ->
      case folder_counts(counts, folder.uuid) do
        {0, 0} ->
          if DateTime.compare(folder.inserted_at, cutoff) == :lt,
            do: [stale_pending(spec, folder, hook_on?)],
            else: []

        folder_counts ->
          [
            %{
              source: spec.source,
              kind: :pending,
              label: folder.name,
              op: :report,
              folder: folder,
              counts: folder_counts,
              reason:
                "pending folder still has #{pending_reason(Map.get(contents, folder.uuid, []))}"
            }
          ]
      end
    end)
  end

  defp stale_pending(spec, folder, true) do
    %{
      source: spec.source,
      kind: :pending,
      label: folder.name,
      op: :trash,
      folder: folder,
      counts: {0, 0},
      reason: "empty pending upload folder older than the retention window"
    }
  end

  defp stale_pending(spec, folder, false) do
    %{
      source: spec.source,
      kind: :pending,
      label: folder.name,
      op: :report,
      folder: folder,
      counts: {0, 0},
      reason:
        "empty pending upload folder older than the retention window " <>
          "(no attachments hook configured — not trashed)"
    }
  end

  # `folder_uuid => [{file name, status}]`, home and linked files alike.
  defp pending_contents([]), do: %{}

  defp pending_contents(uuids) do
    home =
      from(f in StorageFile,
        where: f.folder_uuid in ^uuids,
        select: {f.folder_uuid, f.uuid, f.original_file_name, f.status}
      )

    linked =
      from(l in FolderLink,
        join: f in StorageFile,
        on: f.uuid == l.file_uuid,
        where: l.folder_uuid in ^uuids,
        select: {l.folder_uuid, f.uuid, f.original_file_name, f.status}
      )

    # A file homed in the folder and linked into it too is one file.
    (repo().all(home) ++ repo().all(linked))
    |> Enum.uniq_by(fn {folder, file, _name, _status} -> {folder, file} end)
    |> Enum.group_by(&elem(&1, 0), fn {_folder, _file, name, status} -> {name, status} end)
  end

  defp pending_reason(rows) do
    case for({name, status} <- rows, status != "trashed", do: name) do
      [] -> "#{length(rows)} trashed file(s)"
      names -> "files: #{Enum.join(names, ", ")}"
    end
  end

  # ── Counts and lookups ──────────────────────────────────────────────

  # Every file row homed in the folder, any status, and every link into
  # it — the engine counts the same way before and after applying.
  defp with_counts(actions) do
    counts =
      actions
      |> Enum.flat_map(fn
        %{folder: %Folder{uuid: uuid}} -> [uuid]
        _ -> []
      end)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  defp counts_by_folder([]), do: {%{}, %{}}

  defp counts_by_folder(uuids) do
    uuids = Enum.uniq(uuids)

    files =
      from(f in StorageFile,
        where: f.folder_uuid in ^uuids,
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count(f.uuid)}
      )
      |> repo().all()
      |> Map.new()

    links =
      from(l in FolderLink,
        where: l.folder_uuid in ^uuids,
        group_by: l.folder_uuid,
        select: {l.folder_uuid, count(l.uuid)}
      )
      |> repo().all()
      |> Map.new()

    {files, links}
  end

  defp folder_counts({files, links}, uuid), do: {Map.get(files, uuid, 0), Map.get(links, uuid, 0)}

  defp folders_by_uuid(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        from(f in Folder, where: f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # Every live folder carrying one of `names`, anywhere, oldest first.
  defp folders_by_name(names) do
    case Enum.uniq(names) do
      [] ->
        %{}

      names ->
        from(f in Folder,
          where: f.name in ^names and is_nil(f.trashed_at),
          order_by: [asc: f.inserted_at, asc: f.uuid]
        )
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # A set as a map of `member => true` (MapSet trips dialyzer's opaqueness
  # check when it crosses these functions).
  defp set(members), do: Map.new(members, &{&1, true})

  defp cast(<<_::binary-size(36)>> = value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast(_value), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
