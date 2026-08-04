defmodule PhoenixKit.Migrations.Repair.Scope do
  @moduledoc """
  Spec §6.1's scope rule as pure functions: which manifest objects/invariants
  a given comment version puts "in scope", and at which revision. Everything
  here is DB-free.

  ## The scope rule, restated

  > repair applies manifest objects with `since <= comment` only, each at the
  > newest **revision** with `as_of_version <= comment` (never a future
  > shape); objects with `since > comment` are pending — reported, never
  > pre-applied.

  `resolve/2` gets the second half right for every class by always selecting
  through `PhoenixKit.Migrations.ExpectedSchema.Object.shape_at(object,
  bound)` — **never** `object.check`/`object.create`, which are precomputed
  against the newest revision (see `Object`'s moduledoc for why that
  distinction matters: a healthy DB whose comment sits between two revisions
  must verify clean against the *comment-era* shape, and any create for a
  missing object must be built from that same shape). Turning a resolved
  `%{object:, shape:}` pair into actual SQL is
  `PhoenixKit.Migrations.Repair.Executor.create_action/2`'s job, not this
  module's — `shape_at/2`'s result is already everything a per-class SQL
  builder needs (see that module's moduledoc for why every class *except*
  `:column`/`:index`/`:constraint` ends up using the object's own
  newest-shape `create` regardless of which revision `shape` selected).
  """

  alias PhoenixKit.Migrations.ExpectedSchema.Object

  @typedoc "One in-scope object, resolved to the shape `bound` selects."
  @type resolved :: %{object: Object.t(), shape: Object.shape()}

  @doc """
  Partitions `objects` by `object.since <= bound` — the scope rule's first
  half. Order within each list is preserved from the input.
  """
  @spec partition(list(Object.t()), bound :: pos_integer()) ::
          {in_scope :: list(Object.t()), pending :: list(Object.t())}
  def partition(objects, bound) do
    Enum.split_with(objects, &(&1.since <= bound))
  end

  @doc """
  Resolves one in-scope object to the shape `bound` selects (the scope
  rule's second half — see moduledoc). `nil` for an object whose
  `since > bound` — callers are expected to have already filtered via
  `partition/2`; this guard exists so a misuse fails as "nothing to
  resolve" rather than resolving against a shape that does not exist yet.
  """
  @spec resolve(Object.t(), bound :: pos_integer()) :: resolved() | nil
  def resolve(object, bound) do
    case Object.shape_at(object, bound) do
      nil -> nil
      shape -> %{object: object, shape: shape}
    end
  end

  @doc """
  Selects the data invariants in scope for `bound` (`invariant.since <= bound`
  — the same half of the scope rule as `partition/2`, for
  `PhoenixKit.Migrations.ExpectedSchema.DataInvariant.t()` instead of
  `Object.t()`).
  """
  @spec in_scope_invariants(list(map()), bound :: pos_integer()) :: list(map())
  def in_scope_invariants(invariants, bound) do
    Enum.filter(invariants, &(&1.since <= bound))
  end

  @class_order %{
    extension: 0,
    function: 1,
    sequence: 2,
    table: 3,
    column: 4,
    index: 5,
    constraint: 6,
    seed: 7
  }

  @doc "The additive-safety class order (spec §6.1/§6.2): extensions < functions < sequences < tables < columns < indexes < constraints < seeds."
  @spec class_rank(Object.class()) :: non_neg_integer()
  def class_rank(class), do: Map.fetch!(@class_order, class)

  @doc """
  Sorts resolved objects for execution: class order first (see
  `class_rank/1`), then `since`, then `object.id` — a stable, deterministic
  order independent of the manifest's own emission order (which sorts
  `{since, class, id}` for diff-friendliness; this sorts for *execution
  safety* — class always dominates, since a column must never be attempted
  before its table regardless of which version introduced each).
  """
  @spec execution_order(list(resolved())) :: list(resolved())
  def execution_order(resolved_objects) do
    Enum.sort_by(resolved_objects, fn %{object: object} ->
      {class_rank(object.class), object.since, object.id}
    end)
  end
end
