defmodule PhoenixKit.Squash.MigrationRunner do
  @moduledoc """
  Runs version-bounded `PhoenixKit.Migrations.up/down` calls into a target
  prefix through `Ecto.Migrator`, for the squash verification tooling
  (spec 2026-07-14, section 8.3).

  ## Pattern

  The PhoenixKit migration DSL must execute inside an `Ecto.Migrator` runner
  context (the version modules use Ecto.Migration DSL). For each call we
  `Module.create/3` an ephemeral wrapper module and hand it to
  `Ecto.Migrator.up/4` with a synthetic microsecond version, mirroring
  production `PhoenixKit.Migration.ensure_current/2` +
  `PhoenixKit.Migration.Runner`.

  Two constraints shape the implementation:

  * `Ecto.Migrator` executes the migration body in a spawned `Task`
    (ecto_sql `migrator.ex` `async_migrate_maybe_in_transaction/7`), so
    runtime values CANNOT be smuggled to the wrapper via the caller's
    process dictionary — the June 2026 draft did exactly that and would
    have silently no-opped every run. The wrapped call's options are plain
    literals (version/prefix/create_schema), so they are baked into the
    generated module body as quoted literals instead.
  * `:prefix` is threaded into `Ecto.Migrator.up/4` so its
    `schema_migrations` bookkeeping rows land in the TARGET schema, never
    in a shared database's `public` (cf.
    `test/integration/prefix_migration_test.exs`). Consequence: the target
    schema must pre-exist for Ecto's bookkeeping, so it is ensured here
    (check-then-create, V01 semantics) and V01's own create-schema branch
    is not exercisable through this runner.

  ## Version parameterization

  Floor and current version are never hardcoded: `current_version/0` reads
  `PhoenixKit.Migrations.Postgres.current_version/0`; `floor/0` reads
  `PhoenixKit.Migrations.Postgres.initial_version/0` (post-squash,
  `@initial_version == floor`) and accepts a pre-squash override via the
  `PK_SQUASH_FLOOR` environment variable.

  Functions marked `[DB]` require a started repo pointed at a scratch
  database/schema (see `repo_helper.ex`); `check/0` and the version
  accessors are DB-free.
  """

  alias PhoenixKit.Migrations.Postgres
  alias PhoenixKit.Migrations.Postgres.Helpers

  @floor_env "PK_SQUASH_FLOOR"

  # ---------------------------------------------------------------------------
  # Version configuration (DB-free)
  # ---------------------------------------------------------------------------

  @doc """
  The squash floor: `#{@floor_env}` env override (pre-squash tooling runs),
  else `PhoenixKit.Migrations.Postgres.initial_version/0` (post-squash the
  registry's `@initial_version` IS the floor).
  """
  def floor do
    case System.get_env(@floor_env) do
      nil -> Postgres.initial_version()
      raw -> parse_version!(raw)
    end
  end

  @doc "Highest version of the compiled chain (never overridable)."
  def current_version, do: Postgres.current_version()

  # ---------------------------------------------------------------------------
  # Chain runners [DB]
  # ---------------------------------------------------------------------------

  @doc """
  Run the OLD (pre-squash) migration chain up to `:to_version` (default:
  `current_version/0`). Simulates a consumer wrapper migration on a fresh
  install using the currently compiled chain.

  Options: `:to_version`, `:create_schema` (default `prefix != "public"`;
  the bookkeeping schema is pre-created either way, see moduledoc).

  [DB]
  """
  def run_old_chain(repo, prefix, opts \\ []) do
    to_version = Keyword.get(opts, :to_version, current_version())
    validate_target_version!(to_version)
    create_schema = Keyword.get(opts, :create_schema, prefix != "public")

    run_via_wrapper(repo, prefix, :up,
      version: to_version,
      prefix: prefix,
      create_schema: create_schema
    )
  end

  @doc """
  Roll the chain DOWN to `:to_version` (default 0 = full teardown).

  [DB]
  """
  def run_old_chain_down(repo, prefix, opts \\ []) do
    to_version = Keyword.get(opts, :to_version, 0)

    unless is_integer(to_version) and to_version >= 0 and to_version <= current_version() do
      raise ArgumentError,
            "down target #{inspect(to_version)} outside 0..#{current_version()}"
    end

    run_via_wrapper(repo, prefix, :down,
      version: to_version,
      prefix: prefix
    )
  end

  @doc """
  Run the NEW (post-squash) chain on a fresh install: baseline `V{floor}`
  plus deltas, via the ordinary `PhoenixKit.Migrations.up/1` entry point.

  The baseline module is NOT invoked directly and no opts map is
  hand-built: `up/1` routes everything through its own `with_defaults/2`
  (prefix validation, `quoted_prefix`/`escaped_prefix`, `create_schema`
  default), and its fresh-install branch dispatches
  `@initial_version..version` — the baseline is simply the first module of
  that range and receives the exact same opts shape as every delta.

  Refuses to run against a pre-squash registry (`@initial_version <= 1`) or
  when `#{@floor_env}` contradicts the compiled `@initial_version`.

  Precondition (raises otherwise): the target schema holds NO PhoenixKit
  install — on a non-empty schema `up/1` silently degrades to a delta run
  and the S1 fresh-equivalence oracle compares garbage.

  Options: `:to_version` (default `current_version/0`), `:create_schema`.

  [DB]
  """
  def run_new_chain_fresh(repo, prefix, opts \\ []) do
    assert_squashed_registry!()
    to_version = Keyword.get(opts, :to_version, current_version())
    validate_target_version!(to_version)
    create_schema = Keyword.get(opts, :create_schema, prefix != "public")

    actual = migrated_version(repo, prefix)

    if actual != 0 do
      raise "scenario precondition failed: #{inspect(prefix)} already holds a " <>
              "PhoenixKit install at version #{actual}; fresh-install scenarios " <>
              "need an empty schema (use run_new_chain_existing/4 for upgrades)"
    end

    run_via_wrapper(repo, prefix, :up,
      version: to_version,
      prefix: prefix,
      create_schema: create_schema
    )
  end

  @doc """
  Run the NEW chain against an EXISTING install currently at
  `existing_version` (comment-verified precondition — a mismatch raises, so
  a mis-seeded scenario can never masquerade as a passing delta-only
  upgrade). Post-squash invariant under test: `up/1` applies only
  `V(existing+1)..to_version`, never the baseline.

  Options: `:to_version` (default `current_version/0`).

  [DB]
  """
  def run_new_chain_existing(repo, prefix, existing_version, opts \\ []) do
    assert_squashed_registry!()
    to_version = Keyword.get(opts, :to_version, current_version())
    validate_target_version!(to_version)

    if existing_version < floor() do
      raise ArgumentError,
            "existing_version #{existing_version} is below floor #{floor()}; " <>
              "use assert_below_floor_error/4 for the below-floor scenario"
    end

    actual = migrated_version(repo, prefix)

    if actual != existing_version do
      raise "scenario precondition failed: #{inspect(prefix)} is at version " <>
              "#{actual}, expected #{existing_version}; seed the schema first " <>
              "(e.g. run_old_chain(repo, prefix, to_version: #{existing_version}) " <>
              "on the bridge checkout)"
    end

    run_via_wrapper(repo, prefix, :up,
      version: to_version,
      prefix: prefix,
      create_schema: false
    )
  end

  @doc """
  Per-version stepping for the manifest generator: migrate ONE version at a
  time across `range` (an ascending `first..last` range), each step a
  SEPARATE `Ecto.Migrator` invocation, calling `callback.(version)` after
  each step commits.

  Separate invocations mean every version's immediate-query guards see
  fully flushed state — exactly the incrementally-upgraded install of spec
  section 3.7, which makes this end-state (not the bimodal single-run one)
  the canonical input for `since`/`revisions` tagging and lets the
  generator take a catalog snapshot between steps.

  Precondition (raises otherwise): the target schema is at `first - 1`
  (or fresh when `first == initial_version`), so each `up(version: v)`
  call resolves to exactly one version module. Callback exceptions
  propagate.

  Options: `:create_schema` (first step only; default
  `prefix != "public"`).

  [DB]
  """
  def run_chain_stepwise(repo, prefix, range, callback, opts \\ [])

  def run_chain_stepwise(repo, prefix, %Range{first: first, last: last, step: 1}, callback, opts)
      when is_function(callback, 1) do
    initial = Postgres.initial_version()

    if first < initial or last > current_version() do
      raise ArgumentError,
            "stepwise range #{first}..#{last} outside the compiled chain " <>
              "#{initial}..#{current_version()}"
    end

    actual = migrated_version(repo, prefix)
    fresh_start? = first == initial and actual == 0

    unless fresh_start? or actual == first - 1 do
      raise "stepwise precondition failed: #{inspect(prefix)} is at version " <>
              "#{actual}; stepping #{first}..#{last} requires #{first - 1} " <>
              "(or a fresh schema when starting at the chain's initial version " <>
              "#{initial}) so each step runs exactly one version"
    end

    create_schema = Keyword.get(opts, :create_schema, prefix != "public")

    Enum.each(first..last, fn version ->
      run_via_wrapper(repo, prefix, :up,
        version: version,
        prefix: prefix,
        create_schema: version == first and create_schema
      )

      callback.(version)
    end)

    :ok
  end

  def run_chain_stepwise(_repo, _prefix, range, callback, _opts) do
    raise ArgumentError,
          "run_chain_stepwise/5 needs an ascending step-1 range and an " <>
            "arity-1 callback, got range #{inspect(range)} and " <>
            "callback #{inspect(callback)}"
  end

  @doc """
  Assert that running the NEW chain against an install at `existing_version`
  (below floor) raises the SPECIFIC below-floor error.

  The June draft accepted ANY raise and downgraded unexpected success to a
  soft `:warn` — both are forbidden: any-raise-passes is exactly how a
  missing guard slips through (an incidental crash deeper in the chain
  reads as a pass), and a missing guard is a hard scenario failure, not a
  warning.

  Matcher resolution:

  * `opts[:matcher]` as a module atom — the raised exception must be a
    struct of that module;
  * `opts[:matcher]` as an arity-1 function — must return truthy for the
    raised exception (use this to additionally pin struct fields/message,
    per S4);
  * no matcher — defaults to `PhoenixKit.Migrations.BelowFloorError` when
    that module exists (P3 onward); until then the caller MUST pass an
    explicit matcher or this function raises `ArgumentError`.

  Precondition (raises otherwise): the target schema actually IS at
  `existing_version` (comment-verified) — a mis-seeded schema would
  misreport the guard, and a FRESH schema would take the D13 clamp path
  and build a full install as a side effect.

  Options: `:matcher` (above), `:entry_point` (`:up` | `:down`, default
  `:up` — D4 requires the guard in both), `:to_version` (default
  `current_version/0` for `:up`, `0` for `:down`).

  Returns `:ok` when the matcher confirms; otherwise
  `{:error, {:unexpected_success, result}}` (guard missing),
  `{:error, {:wrong_error, exception}}`, or
  `{:error, {:non_raise_exit, {kind, value}}}`. The exception raised inside
  the migration surfaces here unwrapped — ecto_sql re-raises the original
  kind/reason in the caller.

  [DB]
  """
  def assert_below_floor_error(repo, prefix, existing_version, opts \\ []) do
    if existing_version >= floor() do
      raise ArgumentError,
            "existing_version #{existing_version} is not below floor #{floor()}"
    end

    matcher = resolve_matcher(Keyword.get(opts, :matcher))
    entry_point = Keyword.get(opts, :entry_point, :up)

    actual = migrated_version(repo, prefix)

    if actual != existing_version do
      raise "scenario precondition failed: #{inspect(prefix)} is at version " <>
              "#{actual}, expected below-floor version #{existing_version}; " <>
              "seed it first (run_old_chain/3 on the bridge checkout) — a " <>
              "mis-seeded schema misreports the guard, and a fresh one would " <>
              "run the full clamp path instead of raising"
    end

    pk_opts =
      case entry_point do
        :up ->
          [
            version: Keyword.get(opts, :to_version, current_version()),
            prefix: prefix,
            create_schema: false
          ]

        :down ->
          [version: Keyword.get(opts, :to_version, 0), prefix: prefix]
      end

    result =
      try do
        {:unexpected_success, run_via_wrapper(repo, prefix, entry_point, pk_opts)}
      rescue
        e -> {:raised, e}
      catch
        kind, value -> {:caught, kind, value}
      end

    case result do
      {:raised, exception} ->
        if matcher.(exception) do
          :ok
        else
          {:error, {:wrong_error, exception}}
        end

      {:caught, kind, value} ->
        {:error, {:non_raise_exit, {kind, value}}}

      {:unexpected_success, value} ->
        {:error, {:unexpected_success, value}}
    end
  end

  @doc """
  Raw migrated-version read for scenario preconditions: comment on
  `{prefix}.phoenix_kit` as integer; table present without comment maps to
  1 (mirroring the entry points' legacy mapping in
  `Postgres.migrated_version/1`); table absent maps to 0.

  [DB]
  """
  def migrated_version(repo, prefix) do
    Helpers.validate_prefix!(prefix)

    %{rows: [[table_exists]]} =
      repo.query!(
        """
        SELECT EXISTS (
          SELECT FROM information_schema.tables
          WHERE table_name = 'phoenix_kit' AND table_schema = $1
        )
        """,
        [prefix],
        log: false
      )

    if table_exists do
      %{rows: [[comment]]} =
        repo.query!(
          """
          SELECT pg_catalog.obj_description(pg_class.oid, 'pg_class')
          FROM pg_class
          JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
          WHERE pg_class.relname = 'phoenix_kit' AND pg_namespace.nspname = $1
          """,
          [prefix],
          log: false
        )

      case comment do
        version when is_binary(version) -> String.to_integer(version)
        _ -> 1
      end
    else
      0
    end
  end

  # ---------------------------------------------------------------------------
  # Offline smoke check (no DB)
  # ---------------------------------------------------------------------------

  @doc """
  DB-free self-check for the `--check` gates of the runnable scripts:
  version constants readable and ordered, floor override parseable and in
  range, stepwise range math sane, and the ephemeral wrapper module
  actually compiles for both directions (the June draft shipped a script
  that failed at load — this catches that class without a database).

  Returns `:ok` or raises with a descriptive message.
  """
  def check do
    initial = Postgres.initial_version()
    current = Postgres.current_version()

    unless is_integer(initial) and is_integer(current) and initial >= 1 and initial <= current do
      raise "version constants unreadable or inverted: initial=#{inspect(initial)} " <>
              "current=#{inspect(current)}"
    end

    f = floor()

    unless f in initial..current do
      raise "floor #{f} (#{@floor_env} override or @initial_version) outside " <>
              "the compiled chain #{initial}..#{current}"
    end

    steps = Enum.count(f..current)

    unless steps == current - f + 1 do
      raise "stepwise range math broken: #{f}..#{current} counted #{steps} steps"
    end

    for direction <- [:up, :down] do
      mod =
        create_wrapper_module!(direction,
          version: current,
          prefix: "public",
          create_schema: false
        )

      purge_wrapper_module(mod)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Runs one PhoenixKit.Migrations.up/down call inside a synthetic
  # Ecto.Migrator migration. Threading :prefix keeps the bookkeeping row in
  # the target schema; a fake-version collision would make Ecto skip the
  # module silently, so :already_up is promoted to a raise.
  defp run_via_wrapper(repo, prefix, direction, pk_opts) do
    Helpers.validate_prefix!(prefix)
    ensure_bookkeeping_schema!(repo, prefix)

    mod = create_wrapper_module!(direction, pk_opts)
    fake_version = :os.system_time(:microsecond)

    try do
      case Ecto.Migrator.up(repo, fake_version, mod, log: false, prefix: prefix) do
        :ok ->
          :ok

        :already_up ->
          raise "synthetic version #{fake_version} collided in " <>
                  "#{prefix}.schema_migrations — the wrapped call did NOT run"
      end
    after
      purge_wrapper_module(mod)
    end
  end

  # The migration body runs in Ecto.Migrator's spawned Task, so the wrapped
  # call is baked in as literals (see moduledoc) — never via process state.
  defp create_wrapper_module!(direction, pk_opts) when direction in [:up, :down] do
    mod =
      Module.concat([
        PhoenixKit.Squash.Runner,
        "T#{:os.system_time(:microsecond)}_#{System.unique_integer([:positive])}"
      ])

    call =
      case direction do
        :up -> quote(do: PhoenixKit.Migrations.up(unquote(pk_opts)))
        :down -> quote(do: PhoenixKit.Migrations.down(unquote(pk_opts)))
      end

    contents =
      quote do
        use Ecto.Migration

        def up, do: unquote(call)
        def down, do: :ok
      end

    {:module, ^mod, _, _} = Module.create(mod, contents, Macro.Env.location(__ENV__))
    mod
  end

  defp purge_wrapper_module(mod) do
    :code.delete(mod)
    :code.purge(mod)
    :ok
  end

  # Ecto's prefixed schema_migrations bookkeeping requires the schema to
  # pre-exist (cf. prefix_migration_test.exs). Check-then-create mirrors
  # V01: CREATE SCHEMA IF NOT EXISTS runs its privilege check before the
  # existence short-circuit and fails for low-privilege roles even when the
  # schema is already there.
  defp ensure_bookkeeping_schema!(_repo, "public"), do: :ok

  defp ensure_bookkeeping_schema!(repo, prefix) do
    %{rows: [[exists]]} =
      repo.query!(
        "SELECT EXISTS (SELECT FROM information_schema.schemata WHERE schema_name = $1)",
        [prefix],
        log: false
      )

    unless exists do
      repo.query!(~s(CREATE SCHEMA "#{prefix}"), [], log: false)
    end

    :ok
  end

  defp assert_squashed_registry! do
    initial = Postgres.initial_version()
    f = floor()

    cond do
      initial <= 1 ->
        raise "new-chain scenarios require the squashed registry " <>
                "(@initial_version == floor); the compiled code has " <>
                "@initial_version #{initial} (pre-squash). Build/check out the " <>
                "squash branch before running fresh/existing new-chain scenarios."

      initial != f ->
        raise "#{@floor_env}=#{f} contradicts the compiled @initial_version " <>
                "#{initial}; unset the override when running against squashed code"

      true ->
        :ok
    end
  end

  defp validate_target_version!(version) do
    unless is_integer(version) and version >= 1 and version <= current_version() do
      raise ArgumentError,
            "target version #{inspect(version)} outside 1..#{current_version()}"
    end
  end

  defp resolve_matcher(nil) do
    mod = PhoenixKit.Migrations.BelowFloorError

    if Code.ensure_loaded?(mod) do
      fn exception -> is_struct(exception, mod) end
    else
      raise ArgumentError,
            "#{inspect(mod)} is not defined (pre-P3 code); pass an explicit " <>
              ":matcher — accepting any raise is forbidden (a missing guard " <>
              "would slip through on an incidental crash)"
    end
  end

  defp resolve_matcher(mod) when is_atom(mod) do
    fn exception -> is_struct(exception, mod) end
  end

  defp resolve_matcher(fun) when is_function(fun, 1), do: fun

  defp parse_version!(raw) do
    case Integer.parse(raw) do
      {version, ""} when version >= 1 ->
        version

      _ ->
        raise ArgumentError,
              "#{@floor_env}=#{inspect(raw)} is not a positive integer version"
    end
  end
end
