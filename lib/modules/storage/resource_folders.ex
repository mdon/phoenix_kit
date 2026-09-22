defmodule PhoenixKit.Modules.Storage.ResourceFolders do
  @moduledoc """
  The folder convention for modules that keep one media folder per record
  (a catalogue item, a location, a CRM contact, a staff person, a
  project): the host hooks, the lookup order, race-safe find-or-create,
  and the rules for putting files in and taking them out — written once,
  so every module places, finds and lists a record's files the same way.

  ## Host hooks

      config :my_module, :attachments_parent_folder, {MyApp.Media, :parent_for}
      config :my_module, :attachments_folder_name, {MyApp.Media, :folder_name}

  The parent hook is called as `fun(kind, actor_uuid, subject)`, or as
  `fun(kind, actor_uuid)` when the host exports only that arity, and
  answers `{:ok, parent_folder_uuid}`, or `nil` / `{:ok, nil}` for the
  media root. The name hook is called as `fun(subject, actor_uuid)` and
  answers `{:ok, name}`, or `nil` / `{:ok, nil}` for the module's
  deterministic name.

  `parent_hook/4` and `name_hook/3` tell a hook that is not configured
  (`:unconfigured`) from one that FAILED (`{:error, reason}`: it raised,
  threw, exited, is not exported, or answered anything else — a parent
  that is not a uuid included). A media reorganizer must never read a
  failure as "the root". `parent_uuid/4` and `host_name/3` are the forms
  for everything else: a failure is logged and falls back to the root /
  the deterministic name, so an upload never fails on a host hook. Logs
  name a failure's shape only (`describe_failure/1`) — an exit reason or
  an exception message can carry the hook's arguments.

  ## Lookup order

  `resolve/1` finds a record's folder by the folder uuid the record
  stores, then by the host's name under the parent, then by the
  deterministic name under the parent, then at the root — and, for a name
  that embeds the record's uuid, anywhere. Only live folders count:
  `(name, parent_uuid)` is unique among live folders only, so a trashed
  twin can sit beside the live one, and a record whose folder was trashed
  gets a new one rather than uploads nobody can see.

  A host name carries no uuid, so another record's folder can have it —
  `claimed?/3` asks whether one points at it, and `ensure/4` falls back
  to the uuid-bearing name when the host's is taken.

  Moving existing folders is the media reorganizer's business; nothing
  here moves a folder or creates one for people's own use.

  ## Files

  A file is IN a folder when the folder is its home (`file.folder_uuid`)
  or a `FolderLink` puts it there, and it is live (not trashed, not
  system-managed). `attach/2` and `detach/2` follow core's rules
  (`Storage.attach_file_to_folder/2`, `Storage.remove_file_from_folder/2`):
  a file homed elsewhere is linked, never moved; a removed file is
  unlinked, re-homed or trashed, never deleted.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}

  @typedoc "A hook's answer: a value, not configured, or failed."
  @type hook_answer(value) :: {:ok, value} | :unconfigured | {:error, term()}

  @typedoc """
  Where a record keeps its folder uuid: a key of one of its JSONB map
  fields (`{:data, "files_folder_uuid"}`), or a column (`{:column, :folder_uuid}`).
  """
  @type pointer :: {:column, atom()} | {atom(), String.t()}

  @list_limit 200

  # ── Host hooks ──────────────────────────────────────────────────────

  @doc """
  Asks `app`'s `:attachments_parent_folder` hook where a `kind` folder
  for `subject` belongs: `{:ok, uuid}` (cast to its canonical form) or
  `{:ok, nil}` for the root; `:unconfigured`; or `{:error, reason}`.
  """
  @spec parent_hook(atom(), atom(), String.t() | nil, term()) :: hook_answer(String.t() | nil)
  def parent_hook(app, kind, actor_uuid, subject) do
    with {:ok, {mod, fun}} <- configured(app, :attachments_parent_folder) do
      guarded(fn ->
        cond do
          exported?(mod, fun, 3) -> {:answer, apply(mod, fun, [kind, actor_uuid, subject])}
          exported?(mod, fun, 2) -> {:answer, apply(mod, fun, [kind, actor_uuid])}
          true -> {:error, {:not_exported, {mod, fun}}}
        end
      end)
      |> parent_answer()
    end
  end

  @doc """
  The parent folder for a new `kind` folder: `parent_hook/4`'s uuid, with
  a failure logged and the media root (`nil`) in its place.
  """
  @spec parent_uuid(atom(), atom(), String.t() | nil, term()) :: String.t() | nil
  def parent_uuid(app, kind, actor_uuid, subject) do
    case parent_hook(app, kind, actor_uuid, subject) do
      {:ok, uuid} ->
        uuid

      :unconfigured ->
        nil

      {:error, reason} ->
        Logger.warning(
          "[#{app}] attachments_parent_folder hook failed for #{inspect(kind)}: " <>
            describe_failure(reason)
        )

        nil
    end
  end

  @doc """
  Asks `app`'s `:attachments_folder_name` hook what to call `subject`'s
  folder: `{:ok, name}` (trimmed), `{:ok, nil}` for the deterministic
  name, `:unconfigured`, or `{:error, reason}`.
  """
  @spec name_hook(atom(), term(), String.t() | nil) :: hook_answer(String.t() | nil)
  def name_hook(app, subject, actor_uuid) do
    with {:ok, {mod, fun}} <- configured(app, :attachments_folder_name) do
      guarded(fn ->
        if exported?(mod, fun, 2),
          do: {:answer, apply(mod, fun, [subject, actor_uuid])},
          else: {:error, {:not_exported, {mod, fun}}}
      end)
      |> name_answer()
    end
  end

  @doc """
  The host's name for `subject`'s folder: `name_hook/3`'s name, with a
  failure logged and `nil` (use the deterministic name) in its place.
  """
  @spec host_name(atom(), term(), String.t() | nil) :: String.t() | nil
  def host_name(app, subject, actor_uuid) do
    case name_hook(app, subject, actor_uuid) do
      {:ok, name} ->
        name

      :unconfigured ->
        nil

      {:error, reason} ->
        Logger.warning(
          "[#{app}] attachments_folder_name hook failed: #{describe_failure(reason)}"
        )

        nil
    end
  end

  @doc "Whether `app` sets `key` (the parent hook by default) at all."
  @spec hook_configured?(atom(), atom()) :: boolean()
  def hook_configured?(app, key \\ :attachments_parent_folder),
    do: Application.get_env(app, key) != nil

  @doc """
  A one-line description of a hook failure, or of any error reason, that
  leaves out its payload: an exception is named but not rendered (its
  message interpolates values), an exit reason by its shape.
  """
  @spec describe_failure(term()) :: String.t()
  def describe_failure({:bad_config, _value}), do: "the config is not a {module, function} pair"
  def describe_failure({:not_exported, {mod, fun}}), do: "#{inspect(mod)}.#{fun} is not exported"
  def describe_failure({:bad_answer, _answer}), do: "the hook answered something else"
  def describe_failure({:exit, reason}), do: "exited: " <> exit_shape(reason)
  def describe_failure({:throw, _value}), do: "threw"
  def describe_failure(%{__exception__: true, __struct__: mod}), do: "raised #{inspect(mod)}"
  def describe_failure(reason) when is_atom(reason), do: inspect(reason)

  def describe_failure(%Ecto.Changeset{errors: errors}),
    do: "invalid #{inspect(Keyword.keys(errors))}"

  def describe_failure(reason) when is_tuple(reason), do: shape(reason)
  def describe_failure(_reason), do: "failed"

  defp exit_shape({:timeout, {GenServer, :call, _args}}), do: "GenServer.call timeout"
  defp exit_shape({:noproc, {GenServer, :call, _args}}), do: "GenServer.call to a dead process"

  defp exit_shape({reason, {GenServer, :call, _args}}) when is_atom(reason),
    do: "GenServer.call #{inspect(reason)}"

  defp exit_shape(reason) when is_atom(reason), do: inspect(reason)
  defp exit_shape(%{__struct__: mod}), do: inspect(mod)
  defp exit_shape(reason) when is_tuple(reason), do: shape(reason)
  defp exit_shape(_reason), do: "(details omitted)"

  defp shape(tuple) when tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
    do: "#{inspect(elem(tuple, 0))} (details omitted)"

  defp shape(_tuple), do: "(details omitted)"

  defp configured(app, key) do
    case Application.get_env(app, key) do
      nil -> :unconfigured
      {mod, fun} when is_atom(mod) and is_atom(fun) -> {:ok, {mod, fun}}
      other -> {:error, {:bad_config, other}}
    end
  end

  defp exported?(mod, fun, arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp parent_answer({:answer, nil}), do: {:ok, nil}
  defp parent_answer({:answer, {:ok, nil}}), do: {:ok, nil}

  defp parent_answer({:answer, {:ok, uuid} = answer}) when is_binary(uuid) do
    case cast(uuid) do
      nil -> {:error, {:bad_answer, answer}}
      uuid -> {:ok, uuid}
    end
  end

  defp parent_answer({:answer, {:error, _reason} = error}), do: error
  defp parent_answer({:answer, other}), do: {:error, {:bad_answer, other}}
  defp parent_answer({:error, _reason} = error), do: error

  defp name_answer({:answer, nil}), do: {:ok, nil}
  defp name_answer({:answer, {:ok, nil}}), do: {:ok, nil}

  defp name_answer({:answer, {:ok, name} = answer}) when is_binary(name) do
    case String.trim(name) do
      "" -> {:error, {:bad_answer, answer}}
      name -> {:ok, name}
    end
  end

  defp name_answer({:answer, {:error, _reason} = error}), do: error
  defp name_answer({:answer, other}), do: {:error, {:bad_answer, other}}
  defp name_answer({:error, _reason} = error), do: error

  # ── Finding folders ─────────────────────────────────────────────────

  @doc "The live folder `uuid` points at, or `nil`; anything not a uuid points nowhere."
  @spec live_folder(term()) :: Folder.t() | nil
  def live_folder(uuid) do
    case cast(uuid) do
      nil -> nil
      uuid -> repo().one(from(f in Folder, where: f.uuid == ^uuid and is_nil(f.trashed_at)))
    end
  end

  @doc "The live folder named `name` directly under `parent_uuid` (`nil` = the root)."
  @spec find_under(String.t(), String.t() | nil) :: Folder.t() | nil
  def find_under(name, parent_uuid) when is_binary(name) do
    from(f in Folder, where: f.name == ^name and is_nil(f.trashed_at), limit: 1)
    |> directly_under(parent_uuid)
    |> repo().one()
  end

  @doc """
  The live folder named `name`: under `parent_uuid` first, then at the
  root, then — with `anywhere: true`, for a name that embeds the record's
  uuid so that every folder carrying it is that record's — under any
  other parent. Oldest first within a place, so the answer never depends
  on who asks.
  """
  @spec find_named(String.t(), String.t() | nil, keyword()) :: Folder.t() | nil
  def find_named(name, parent_uuid, opts \\ []) when is_binary(name) do
    [name]
    |> find_named_all(parent_uuid, opts)
    |> Map.get(name)
  end

  @doc """
  `find_named/3` for many names in one query: `%{name => folder}`, a
  name with no live folder left out.
  """
  @spec find_named_all([String.t()], String.t() | nil, keyword()) :: %{String.t() => Folder.t()}
  def find_named_all(names, parent_uuid, opts \\ [])
  def find_named_all([], _parent_uuid, _opts), do: %{}

  def find_named_all(names, parent_uuid, opts) when is_list(names) do
    parent_uuid = cast(parent_uuid)

    from(f in Folder,
      where: f.name in ^Enum.uniq(names) and is_nil(f.trashed_at),
      order_by: [asc: f.inserted_at, asc: f.uuid]
    )
    |> near(parent_uuid, Keyword.get(opts, :anywhere, false))
    |> repo().all()
    |> Enum.group_by(& &1.name)
    |> Map.new(fn {name, folders} ->
      {name, Enum.min_by(folders, &place_rank(&1, parent_uuid))}
    end)
  end

  defp near(query, _parent_uuid, true), do: query
  defp near(query, nil, false), do: where(query, [f], is_nil(f.parent_uuid))

  defp near(query, parent_uuid, false),
    do: where(query, [f], is_nil(f.parent_uuid) or f.parent_uuid == ^parent_uuid)

  # `Enum.min_by/2` keeps the first of equal ranks, and the rows come
  # oldest first.
  defp place_rank(%Folder{parent_uuid: parent}, parent), do: 0
  defp place_rank(%Folder{parent_uuid: nil}, _parent), do: 1
  defp place_rank(%Folder{}, _parent), do: 2

  @doc """
  A record's folder, in the convention's order, or `nil` when it has none
  yet:

    1. `:pointer` — the folder uuid the record stores, if that folder is live;
    2. `:host_name` directly under `:parent`, unless `:claimed?` (a
       `fun(folder) -> boolean`) says another record owns that folder;
    3. `:name`, the deterministic name, by `find_named/3` — pass
       `anywhere: true` when it embeds the record's uuid.

  Give an unsaved record no names: a folder found by name is one some
  saved record already owns.
  """
  @spec resolve(keyword()) :: Folder.t() | nil
  def resolve(opts) do
    parent = cast(Keyword.get(opts, :parent))
    name = Keyword.get(opts, :name)
    claimed? = Keyword.get(opts, :claimed?, fn _folder -> false end)

    live_folder(Keyword.get(opts, :pointer)) ||
      host_named(Keyword.get(opts, :host_name), name, parent, claimed?) ||
      (is_binary(name) && find_named(name, parent, anywhere: Keyword.get(opts, :anywhere, false))) ||
      nil
  end

  defp host_named(host_name, name, parent, claimed?)
       when is_binary(host_name) and host_name != name do
    case find_under(host_name, parent) do
      nil -> nil
      folder -> if claimed?.(folder), do: nil, else: folder
    end
  end

  defp host_named(_host_name, _name, _parent, _claimed?), do: nil

  @doc """
  Whether a record other than `own_uuid` points at `folder_uuid` through
  one of `pointers` (`[{schema, pointer}]`, see `t:pointer/0`) — the
  check that keeps a record from adopting another's host-named folder.
  Fails closed: an error answers `true`.
  """
  @spec claimed?(String.t(), String.t() | nil, [{module(), pointer()}]) :: boolean()
  def claimed?(folder_uuid, own_uuid, pointers) when is_binary(folder_uuid) do
    Enum.any?(pointers, fn {schema, pointer} ->
      schema
      |> pointing_at(pointer, folder_uuid)
      |> except_uuid(cast(own_uuid))
      |> repo().exists?()
    end)
  rescue
    error ->
      Logger.warning("Folder claim check failed for #{folder_uuid}: #{describe_failure(error)}")
      true
  catch
    :exit, reason ->
      Logger.warning("Folder claim check failed for #{folder_uuid}: #{exit_shape(reason)}")
      true
  end

  defp pointing_at(schema, {:column, column}, folder_uuid),
    do: from(r in schema, where: field(r, ^column) == ^folder_uuid)

  defp pointing_at(schema, {map_field, key}, folder_uuid) when is_binary(key),
    do: from(r in schema, where: fragment("?->>?", field(r, ^map_field), ^key) == ^folder_uuid)

  defp except_uuid(query, nil), do: query
  defp except_uuid(query, uuid), do: where(query, [r], r.uuid != ^uuid)

  # ── Creating folders ────────────────────────────────────────────────

  @doc """
  The folder named `name` under `parent_uuid`, created when missing —
  race-safe: a create that loses to a concurrent one takes the winner.
  Never raises.

  ## Options

    * `:lookup` — a 0-arity function finding the existing folder
      (default: the live `name` directly under `parent_uuid`). It runs
      before creating and again after a create is refused, so a caller
      that resolves through `resolve/1` passes that here.
    * `:fallback_name` — when `name` is taken under this parent by a
      folder `:lookup` does not adopt (another record's), or core refuses
      it, create this one instead: the uuid-bearing deterministic name,
      which cannot collide. A name known to be taken is not tried at all.
    * `:claim` — a 1-arity function recording the folder as the record's
      (writing its pointer, `write_pointer/4`), answering `:ok`,
      `{:ok, _}` or `{:error, _}`. With it, the lookup, the create and
      the claim run in one transaction under a lock on `{parent, name}`:
      a folder found by a name that carries no uuid is claimed before
      anyone else can look for it, so two same-named records resolving
      at once never share one folder. A claim that fails rolls the create
      back.
  """
  @spec ensure(String.t(), String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, Folder.t()} | {:error, term()}
  def ensure(name, parent_uuid, actor_uuid, opts \\ []) when is_binary(name) do
    case Keyword.get(opts, :claim) do
      nil ->
        safely("ensure folder", fn -> find_or_create(name, parent_uuid, actor_uuid, opts) end)

      claim when is_function(claim, 1) ->
        safely("ensure folder", fn -> claimed(name, parent_uuid, actor_uuid, opts, claim) end)
    end
  end

  defp claimed(name, parent_uuid, actor_uuid, opts, claim) do
    repo().transaction(fn ->
      lock_name(parent_uuid, name)

      with {:ok, folder} <- find_or_create(name, parent_uuid, actor_uuid, opts),
           :ok <- claim_result(claim.(folder)) do
        folder
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  defp claim_result(:ok), do: :ok
  defp claim_result({:ok, _}), do: :ok
  defp claim_result({:error, _reason} = error), do: error
  defp claim_result(other), do: {:error, {:bad_claim, other}}

  # A transaction-scoped advisory lock on the name under the parent, so
  # every resolver of one host name queues behind the one claiming it.
  defp lock_name(parent_uuid, name) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "pk_resource_folder:#{parent_uuid || "root"}:#{name}"
    ])
  end

  defp find_or_create(name, parent_uuid, actor_uuid, opts) do
    lookup = Keyword.get(opts, :lookup, fn -> find_under(name, parent_uuid) end)
    fallback = Keyword.get(opts, :fallback_name)

    case lookup.() do
      %Folder{} = folder ->
        {:ok, folder}

      nil ->
        if fallback?(name, fallback) and find_under(name, parent_uuid),
          do: find_or_create(fallback, parent_uuid, actor_uuid, []),
          else: create(name, parent_uuid, actor_uuid, lookup, fallback)
    end
  end

  defp create(name, parent_uuid, actor_uuid, lookup, fallback) do
    case insert_folder(%{name: name, parent_uuid: parent_uuid, user_uuid: actor_uuid}) do
      {:ok, folder} ->
        {:ok, folder}

      {:error, %Ecto.Changeset{} = changeset} ->
        case lookup.() do
          %Folder{} = folder ->
            {:ok, folder}

          nil ->
            if name_refused?(changeset) and fallback?(name, fallback),
              do: find_or_create(fallback, parent_uuid, actor_uuid, []),
              else: {:error, changeset}
        end
    end
  end

  # Inside a transaction a refused insert would abort it, so the insert
  # gets a savepoint of its own there.
  defp insert_folder(attrs) do
    opts = if repo().in_transaction?(), do: [mode: :savepoint], else: []
    %Folder{} |> Folder.changeset(attrs) |> repo().insert(opts)
  end

  @doc """
  Points record `uuid` of `schema` at `folder_uuid` through `pointer`
  (`t:pointer/0`) — one UPDATE of that key or column only, no changeset,
  no callbacks, the rest of the row untouched; `nil` removes the pointer.
  `{:error, :not_found}` when no such record exists.
  """
  @spec write_pointer(module(), String.t(), pointer(), String.t() | nil) ::
          :ok | {:error, :not_found}
  def write_pointer(schema, uuid, pointer, folder_uuid) do
    case repo().update_all(
           from(r in schema,
             where: r.uuid == ^uuid,
             update: ^pointer_update(pointer, folder_uuid)
           ),
           []
         ) do
      {0, _} -> {:error, :not_found}
      {_n, _} -> :ok
    end
  end

  defp pointer_update({:column, column}, folder_uuid), do: [set: [{column, folder_uuid}]]

  # `jsonb_set` with a NULL value answers NULL for the whole map, so
  # clearing a pointer removes its key instead.
  defp pointer_update({map_field, key}, nil) when is_binary(key) do
    [
      set: [
        {map_field,
         dynamic([r], fragment("coalesce(?, '{}'::jsonb) - ?", field(r, ^map_field), ^key))}
      ]
    ]
  end

  defp pointer_update({map_field, key}, folder_uuid) when is_binary(key) do
    [
      set: [
        {map_field,
         dynamic(
           [r],
           fragment(
             "jsonb_set(coalesce(?, '{}'::jsonb), ARRAY[?]::text[], to_jsonb(?::text))",
             field(r, ^map_field),
             ^key,
             ^folder_uuid
           )
         )}
      ]
    ]
  end

  defp name_refused?(%Ecto.Changeset{errors: errors}), do: Keyword.has_key?(errors, :name)

  defp fallback?(name, fallback), do: is_binary(fallback) and fallback != name

  @doc """
  Names a pending folder — one created for a record before it was saved,
  its name starting with `prefix` — after its record. A folder that is
  not pending is left alone. Always `:ok`; a failure is logged.

  ## Options

    * `:fallback_name` — used when core refuses `name` (taken under the
      folder's parent)
    * `:move_to` — also move the folder under this parent (`nil` = the
      root), for a module whose parent depends on the saved record. Pass
      only a definite answer (`parent_hook/4`'s `{:ok, parent}`), never
      the root a failed hook fell back to. Without it only the name
      changes: an explicit parent in an update is a move.
  """
  @spec name_pending(String.t() | nil, String.t(), String.t(), keyword()) :: :ok
  def name_pending(folder_uuid, prefix, name, opts \\ [])
      when is_binary(prefix) and is_binary(name) and is_list(opts) do
    with %Folder{name: current} = folder <-
           safely("load pending folder", fn -> live_folder(folder_uuid) end),
         true <- String.starts_with?(current, prefix),
         {:error, reason} <- safely("name pending folder", fn -> rename(folder, name, opts) end) do
      Logger.warning("Pending folder #{folder.uuid} was not named: #{describe_failure(reason)}")
      :ok
    else
      _ -> :ok
    end
  end

  defp rename(folder, name, opts) do
    fallback = Keyword.get(opts, :fallback_name)
    move = if Keyword.has_key?(opts, :move_to), do: %{parent_uuid: opts[:move_to]}, else: %{}

    case Storage.update_folder(folder, Map.put(move, :name, name)) do
      {:error, %Ecto.Changeset{} = changeset} = error ->
        if name_refused?(changeset) and fallback?(name, fallback),
          do: Storage.update_folder(folder, Map.put(move, :name, fallback)),
          else: error

      result ->
        result
    end
  end

  @doc """
  Deletes for good every folder named `name` — wherever it sits, trashed
  or not — with everything inside it, for a record deleted for good whose
  folder name embeds its uuid. A file some other folder links keeps
  living there (`Storage.delete_folder_completely/1`). Always `:ok`; a
  failure is logged.
  """
  @spec purge_named(String.t()) :: :ok
  def purge_named(name) when is_binary(name) do
    safely("purge folders", fn ->
      from(f in Folder, where: f.name == ^name, order_by: [asc: f.inserted_at])
      |> repo().all()
      |> Enum.each(&Storage.delete_folder_completely/1)
    end)

    :ok
  end

  # ── Files in a folder ───────────────────────────────────────────────

  @doc """
  The files `folder_uuid` holds — home there or linked in — that are
  live: not trashed and not system-managed (tile chunks, an edited
  image's hidden original, which are never listed). Unordered and
  uncapped, for counting or for a caller's own order.
  """
  @spec files_query(String.t()) :: Ecto.Query.t()
  def files_query(folder_uuid) when is_binary(folder_uuid) do
    linked = from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    from(f in StorageFile,
      where: f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked)
    )
    |> live_files()
  end

  @doc """
  The files `folder_uuid` holds (`files_query/1`); `[]` for `nil`.

  ## Options

    * `:only` — `:images`, `:non_images`, `{:type, file_type}`,
      `{:not_type, file_type}` or `:all` (default)
    * `:order` — `:newest` first (default) or `:oldest` first
    * `:limit` — at most this many (default #{@list_limit})
  """
  @spec list_files(String.t() | nil, keyword()) :: [StorageFile.t()]
  def list_files(folder_uuid, opts \\ [])
  def list_files(nil, _opts), do: []

  def list_files(folder_uuid, opts) when is_binary(folder_uuid) do
    folder_uuid
    |> files_query()
    |> only(Keyword.get(opts, :only, :all))
    |> ordered(Keyword.get(opts, :order, :newest))
    |> limit(^Keyword.get(opts, :limit, @list_limit))
    |> repo().all()
  end

  @doc """
  The files of many folders in two queries: `%{folder_uuid => [file]}`,
  each list in `:order` (`:newest` first by default), a folder holding
  nothing left out. Takes `:only` like `list_files/2`; uncapped.
  """
  @spec files_by_folder([String.t()], keyword()) :: %{String.t() => [StorageFile.t()]}
  def files_by_folder(folder_uuids, opts \\ [])
  def files_by_folder([], _opts), do: %{}

  def files_by_folder(folder_uuids, opts) when is_list(folder_uuids) do
    uuids = folder_uuids |> Enum.map(&cast/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    kind = Keyword.get(opts, :only, :all)

    home =
      from(f in StorageFile, where: f.folder_uuid in ^uuids, select: {f.folder_uuid, f})
      |> live_files()
      |> only(kind)

    linked =
      from(f in StorageFile,
        join: fl in FolderLink,
        on: fl.file_uuid == f.uuid,
        where: fl.folder_uuid in ^uuids,
        select: {fl.folder_uuid, f}
      )
      |> live_files()
      |> only(kind)

    (repo().all(home) ++ repo().all(linked))
    |> Enum.uniq_by(fn {folder_uuid, file} -> {folder_uuid, file.uuid} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {folder_uuid, files} ->
      {folder_uuid, sort_files(files, Keyword.get(opts, :order, :newest))}
    end)
  end

  @doc """
  How many live files each of `folder_uuids` holds, in two grouped
  queries: `%{folder_uuid => count}`, an empty folder left out. Takes
  `:only` like `list_files/2`; counts exactly what `files_query/1` holds
  (`list_files/2` lists the same set, up to its `:limit`)
  (a file linked into its own home folder once).
  """
  @spec count_by_folder([String.t()], keyword()) :: %{String.t() => pos_integer()}
  def count_by_folder(folder_uuids, opts \\ [])
  def count_by_folder([], _opts), do: %{}

  def count_by_folder(folder_uuids, opts) when is_list(folder_uuids) do
    uuids = folder_uuids |> Enum.map(&cast/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    kind = Keyword.get(opts, :only, :all)

    home =
      from(f in StorageFile,
        where: f.folder_uuid in ^uuids,
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count(f.uuid)}
      )
      |> live_files()
      |> only(kind)

    # A link naming the file's own home is read once by `files_query/1`'s
    # `home OR linked`, so it is not counted twice here either.
    linked =
      from(f in StorageFile,
        join: fl in FolderLink,
        on: fl.file_uuid == f.uuid,
        where: fl.folder_uuid in ^uuids,
        where: is_nil(f.folder_uuid) or f.folder_uuid != fl.folder_uuid,
        group_by: fl.folder_uuid,
        select: {fl.folder_uuid, count(f.uuid)}
      )
      |> live_files()
      |> only(kind)

    Enum.reduce(repo().all(home) ++ repo().all(linked), %{}, fn {folder, n}, acc ->
      Map.update(acc, folder, n, &(&1 + n))
    end)
  end

  @doc """
  Whether live file `file_uuid` is in `folder_uuid` — the check that
  authorizes pointing a record at one of its own files (an avatar, a
  featured image). Takes `:only` like `list_files/2`.
  """
  @spec holds_file?(String.t() | nil, String.t() | nil, keyword()) :: boolean()
  def holds_file?(folder_uuid, file_uuid, opts \\ []) do
    case {cast(folder_uuid), cast(file_uuid)} do
      {folder, file} when is_binary(folder) and is_binary(file) ->
        folder
        |> files_query()
        |> where([f], f.uuid == ^file)
        |> only(Keyword.get(opts, :only, :all))
        |> repo().exists?()

      _ ->
        false
    end
  end

  defp live_files(query),
    do: where(query, [f], f.status != "trashed" and f.system_managed == false)

  defp only(query, :images), do: only(query, {:type, "image"})
  defp only(query, :non_images), do: only(query, {:not_type, "image"})
  defp only(query, :all), do: query
  defp only(query, {:type, type}), do: where(query, [f], f.file_type == ^type)
  defp only(query, {:not_type, type}), do: where(query, [f], f.file_type != ^type)

  defp ordered(query, :oldest), do: order_by(query, [f], asc: f.inserted_at, asc: f.uuid)
  defp ordered(query, :newest), do: order_by(query, [f], desc: f.inserted_at, desc: f.uuid)

  defp sort_files(files, :oldest), do: Enum.sort_by(files, &{&1.inserted_at, &1.uuid}, :asc)
  defp sort_files(files, :newest), do: Enum.sort_by(files, &{&1.inserted_at, &1.uuid}, :desc)

  # ── Putting files in and taking them out ────────────────────────────

  @doc """
  Puts a file into `folder_uuid` by core's attach rule: a file with no
  home is adopted (`:adopted`), a file homed elsewhere is linked
  (`:linked`), a file already home or linked there is left alone
  (`:already_attached`). A folder that is not live is refused
  (`{:error, :folder_unavailable}`), and so is a trashed file
  (`{:error, :file_trashed}`) — either would be listed nowhere. Never
  raises.
  """
  @spec attach(StorageFile.t() | String.t(), String.t()) ::
          {:ok, :adopted | :linked | :already_attached} | {:error, term()}
  def attach(file_or_uuid, folder_uuid) when is_binary(folder_uuid) do
    safely("attach file", fn ->
      with_locked_file(file_or_uuid, {:error, :not_found}, &attach_locked(&1, folder_uuid))
    end)
  end

  defp attach_locked(file, folder_uuid) do
    with %Folder{uuid: folder_uuid} <- live_folder(folder_uuid) || {:error, :folder_unavailable} do
      cond do
        file.status == "trashed" -> {:error, :file_trashed}
        file.folder_uuid == folder_uuid -> {:ok, :already_attached}
        Storage.folder_link(folder_uuid, file.uuid) -> {:ok, :already_attached}
        true -> attach_new(file, folder_uuid)
      end
    end
  end

  defp attach_new(file, folder_uuid) do
    outcome = if is_nil(file.folder_uuid), do: :adopted, else: :linked

    case Storage.attach_file_to_folder(file, folder_uuid) do
      {:ok, _file} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Files a just-stored upload into `folder_uuid`, given what
  `Storage.store_file_in_buckets/6` (or `store_file/2`) answered. Storage
  de-duplicates by content, so the answer can be an existing file:

    * a trashed duplicate is restored — the person removed it and is
      uploading it again — and attached as if new;
    * a duplicate already in the folder is `{:already_attached, file}`,
      so the uploader hears that nothing was added;
    * anything else is attached: `{:ok, file}`.

  Never raises.
  """
  @spec place_stored(term(), String.t()) ::
          {:ok, StorageFile.t()} | {:already_attached, StorageFile.t()} | {:error, term()}
  def place_stored({:ok, %StorageFile{} = file}, folder_uuid), do: place(file, folder_uuid, false)

  # Restored and attached together: a restore whose attach then fails
  # would leave the file active in its old (trashed) home, in no listing
  # and not in the file trash either.
  def place_stored({:ok, %StorageFile{status: "trashed"} = file, :duplicate}, folder_uuid) do
    safely("restore file", fn ->
      repo().transaction(fn ->
        with {:ok, restored} <- Storage.restore_file(file),
             {:ok, placed} <- place(restored, folder_uuid, false) do
          placed
        else
          {:error, reason} -> repo().rollback(reason)
        end
      end)
    end)
  end

  def place_stored({:ok, %StorageFile{} = file, :duplicate}, folder_uuid),
    do: place(file, folder_uuid, true)

  def place_stored({:error, reason}, _folder_uuid), do: {:error, reason}

  defp place(file, folder_uuid, duplicate?) do
    case attach(file, folder_uuid) do
      {:ok, :already_attached} when duplicate? -> {:already_attached, file}
      {:ok, _outcome} -> {:ok, file}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Takes a file out of `folder_uuid` by core's removal rule
  (`Storage.remove_file_from_folder/2`): a link is dropped (`:unlinked`);
  a file homed here moves to a live folder that also links it
  (`:rehomed`), or is trashed when nothing else holds it (`:trashed`).
  `:absent` when the file is gone or was never in the folder — including
  `nil` for the folder, which holds nothing. Never a hard delete; never
  raises.
  """
  @spec detach(StorageFile.t() | String.t(), String.t() | nil) ::
          {:ok, :unlinked | :rehomed | :trashed | :absent} | {:error, term()}
  def detach(_file_or_uuid, nil), do: {:ok, :absent}

  def detach(file_or_uuid, folder_uuid) when is_binary(folder_uuid) do
    safely("detach file", fn ->
      with_locked_file(file_or_uuid, {:ok, :absent}, fn file ->
        case Storage.remove_file_from_folder(file, folder_uuid) do
          {:ok, outcome, _file} -> {:ok, outcome}
          {:error, :not_in_folder} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end
      end)
    end)
  end

  # The file's row, read fresh and locked for the rest of the transaction:
  # a caller's struct can be stale (the file re-homed since), and deciding
  # from it — two removals at once, the second still seeing the old home —
  # trashed a file another folder still held. A logical refusal writes
  # nothing, so it is returned as is rather than rolled back (which would
  # abort a caller's own transaction).
  defp with_locked_file(file_or_uuid, missing, fun) do
    case cast(file_uuid(file_or_uuid)) do
      nil ->
        missing

      uuid ->
        {:ok, result} =
          repo().transaction(fn ->
            case repo().one(from(f in StorageFile, where: f.uuid == ^uuid, lock: "FOR UPDATE")) do
              nil -> missing
              file -> fun.(file)
            end
          end)

        result
    end
  end

  defp file_uuid(%StorageFile{uuid: uuid}), do: uuid
  defp file_uuid(uuid), do: uuid

  # ── Helpers ─────────────────────────────────────────────────────────

  # A soft-failure path: an unreachable database raises on an unowned
  # checkout but EXITS on a dead pool, so both become `{:error, _}`.
  defp safely(what, fun) do
    fun.()
  rescue
    error ->
      Logger.warning("[ResourceFolders] #{what} failed: #{describe_failure(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning("[ResourceFolders] #{what} failed: #{exit_shape(reason)}")
      {:error, {:exit, reason}}
  end

  defp directly_under(query, nil), do: where(query, [f], is_nil(f.parent_uuid))

  defp directly_under(query, parent_uuid) do
    case cast(parent_uuid) do
      nil -> where(query, [_f], false)
      uuid -> where(query, [f], f.parent_uuid == ^uuid)
    end
  end

  # The text form only: `Ecto.UUID.cast/1` also takes any 16-byte binary
  # as a raw uuid, which would turn a 16-character folder name into one.
  defp cast(<<_::binary-size(36)>> = value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast(_value), do: nil

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
