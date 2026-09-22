defmodule PhoenixKit.Modules.Storage.Reorganizer.Source do
  @moduledoc """
  Behaviour a module implements to contribute a media-reorganization plan to
  `PhoenixKit.Modules.Storage.Reorganizer`.

  A module registers its `Source` via the optional `PhoenixKit.Module`
  callback `media_reorganizer/0`, collected from **enabled** modules by
  `PhoenixKit.ModuleRegistry.all_media_reorganizers/0`.

      @impl PhoenixKit.Module
      def media_reorganizer, do: MyModule.MediaReorganizer

      defmodule MyModule.MediaReorganizer do
        @behaviour PhoenixKit.Modules.Storage.Reorganizer.Source

        @impl true
        def plan(actor_uuid, opts) do
          [
            %{
              source: "my_module",
              kind: :item,
              label: "My item",
              op: :move,
              folder: current_folder,
              parent_uuid: desired_parent_uuid,
              name: desired_name,
              counts: {files, links},
              on_conflict: :suffix
            }
          ]
        end
      end

  A module that keeps one media folder per record through
  `PhoenixKit.Modules.Storage.ResourceFolders` declares its records to
  `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource` instead of
  implementing this list itself — it applies every rule below.

  `plan/2` returns a list of **plain maps** (`PhoenixKit.Modules.Storage.Reorganizer.Action`
  validates and normalizes them) — a `Source` implementation never needs to
  depend on this module at compile time, only declare the shape. Rules for a
  well-behaved `Source` (the contract worked out with the module owner across
  several rounds of review; amend this list on conflict rather than a single
  module's comments):

  - **No hook configured on the host → `:report` actions only.** When the
    module's own parent-folder hook isn't wired up, the `Source` emits
    orphan/pending/duplicate/relocated `:report`s and nothing else — never
    `op: :move`, never `op: :trash`, no pointer back-fill. A host with no
    hooks wired is untouched. A pointer-less module illustrates this with
    `on_conflict: :report` (see below) rather than the `:suffix` example at
    the top of this moduledoc.
  - **Desired parent/name come from the module's own hooks** — the same
    functions the module uses when it creates a folder on first upload — so
    a plan always matches what a fresh upload would do.
  - **Lookup order is parent-first, in the module's own order**: under the
    resolved parent before root. A host-named folder under the resolved
    parent (the root, when the answer is root — the name a fresh upload
    would use) is itself a lookup step,
    batched — not folded into the legacy-name lookup: if an unclaimed one
    exists there, it IS the current folder (a noop move + pointer
    back-fill); one another record's pointer claims is skipped and the
    legacy name is wanted instead. A live host-named folder AND a live
    legacy-named folder both present is one `:report, kind: :duplicate`
    naming every copy in the places looked, no move. A live folder found in more than one place the module would look
    (e.g. root AND the resolved parent) is the same: one `:duplicate`
    report naming every uuid found, nothing moves.
  - **The record's pointer wins over any name lookup** when it resolves to
    a live folder. A folder found only through a legacy/host name (no live
    pointer) means the record's pointer needs back-filling.
  - **A pointer-found folder keeps its current name** (`name: nil`) —
    modules never rename a folder the owner may have renamed — UNLESS
    `folder.name` still equals the module's legacy name exactly, or still
    carries its pending-upload prefix (the owner never touched it), in which
    case the desired host name is proposed like any other rename. A name hook is never called for a pointer-found
    folder whose name is kept — that decision is made from the folder's own
    name, not from calling the hook.
  - **Converging targets**: two records whose desired `{parent, name}` are
    the same collapse into one `:report, kind: :duplicate` for the group —
    never two `:move` actions racing for one target. This only applies when
    the host has a hook configured, and only among actions that would
    otherwise be a real `:move` (a record already sitting at its target is
    not part of the group).
  - **Claims are computed from every record's valid pointer**, regardless of
    whether the host has a hook configured — a pending folder any live
    record points at is never planned as an orphan or a stale-pending
    `:trash`, hook or no hook. Orphan candidates always exclude every
    claimed folder (pointer-resolved or name-resolved).
  - **No hook call without a candidate** (a record with a resolvable current
    folder) — orphan/pending scanning under a parent that no candidate's
    hook call resolved is scoped to root only, never guessed from where a
    folder happens to sit. The orphan scope is every parent returned by a
    SUCCESSFUL hook call for any candidate, regardless of that candidate's
    own outcome (`:move`, `:relocated`, `:duplicate`, `:hook_nil` all
    count) — never a parent inferred from a folder's current position.
  - **A hook answer is `{:ok, uuid}`, `{:ok, nil}`, or bare `nil`** — the
    last two both mean root. Every other shape — a raise, throw, exit,
    `{:error, _}`, `{:ok, <non-UUID>}` (including `{:ok, ""}`), or a
    configured `{module, function}` that isn't callable
    (`Code.ensure_loaded?/1` / `function_exported?/3` fails) — is the hook
    FAILING, never "root". A failing hook skips the affected record with one
    `op: :report, kind: :hook_error` per source (naming how many records it
    affected and, for an uncallable hook, that it "is not callable") — it
    must never be read as `{:ok, nil}` and planned as a move to root. Every
    hook answer is normalized through `Ecto.UUID.cast/1` and downcased
    before use — a non-UUID string must become `:hook_error`, never an
    uncaught `Ecto.Query.CastError` from feeding it straight into a query.
    This applies to the orphan/pending scan too, not only to candidate
    records: a hook call failing while resolving a scope parent is still one
    `:hook_error`, and the failure is logged (`Logger.warning`) with the
    hook's `{module, function}` and the record's kind, not only counted —
    by its shape (the exception's name, an exit's reason, the answer's
    type), never the exception's message or the hook's answer, which can
    carry the hook's arguments.
  - **An explicit `nil`/`{:ok, nil}` never moves a folder that isn't already
    at root.** For a candidate whose current folder has a parent, a `nil`
    answer from the parent hook yields only the pointer back-fill (if any)
    and one `:report, kind: :hook_nil` ("hook answered root for a folder
    living under X") — never an actual `:move` to root. Only a folder that
    is already at root may stay there via a `nil` answer. With no copy at
    the root, a single copy elsewhere is adopted in place that way; several
    are one `:duplicate` naming them all.
  - **A name hook that fails is a hook error** (`:hook_error`, record
    skipped) — never a silent fallback to the deterministic/legacy name. A
    name hook that itself returns `nil` is fine (it means "use the
    deterministic name").
  - **No folder found means no action** — nothing exists to move yet; the
    module creates one on first upload.
  - **Pointer-less modules** (no field to back-fill) only ever consider a
    legacy-named folder at root or under the resolved parent; one found
    anywhere else is left alone and reported `kind: :relocated` — never
    moved, since nothing would keep pointing at it afterwards. This applies
    to EVERY extra live copy found (not only the first one), and a copy
    already checked off as a claim is never also reported `:relocated`.
    When the hook itself depends on the acting user (not just database
    state), the `:relocated` reason says so. Every `:relocated` reason names
    WHERE the copy actually is — at the media root, under `<parent name>`,
    or as a `"(N)"` twin already sitting under the target parent — never a
    bare "found elsewhere".
  - **Records whose parent record is trashed** (e.g. a CRM interaction of a
    trashed contact) are skipped by the `Source`; their folders, if any, are
    reported as orphans, not moved. Archived/inactive-but-not-deleted
    records are still live for the reorganizer — only a deleted/trashed
    record makes its folder an orphan.
  - **Pointer back-fill** happens via `:after_move` when the record has no
    live pointer to its current folder. `:after_move` writes only the
    owned pointer field directly with a repo update (no context `update_*`,
    no Activity log, no PubSub, no full changeset validation) and must be a
    0-arity function returning `:ok`, `{:ok, _}`, or `{:error, _}` (anything
    else is a bad-return failure, same as an `{:error, _}`).
  - **Stale pending folders** (a module's own `<prefix>-pending-*` naming):
    empty and older than `pending_days` (an opt threaded through `plan/2`)
    become `op: :trash`; non-empty ones become `op: :report` naming the
    files still inside, collected in one batched files+links query (the
    reason is never an empty list — say "N trashed file(s)" when only
    trashed files remain) — but only among folders no live record claims
    (see claims above), and only for a host that has a hook configured. A
    folder any live record points at is never trashed, and two records
    pointing at the same folder is one `:report, kind: :duplicate`, not a
    move — one folder never produces more than one action.
  - A `Source` **must never create folders**. A parent that a module's own
    hook lazily creates (e.g. an "Uncategorized" bucket) is the hook's
    business, not the `Source`'s.
  - **Query cost**: load only the light columns a plan needs for CANDIDATE
    DETECTION (uuid, name/number, status, pointer, parent id) — never whole
    records with large/jsonb payloads — in one batched query per kind. When
    the pointer field lives inside a `data` jsonb column, the light select
    pulls it with `fragment("?->>'field_name'", data)` — never `select:
    data` or `select: m` just to reach one key, which drags the whole
    payload along for every row. Also keep the query count independent of
    record count (grouped/batched
    lookups, not one query per record). Every by-name lookup filters
    `trashed_at is nil` (the unique index is partial; a trashed twin must
    never hide a live folder). A pointer that fails `Ecto.UUID.cast/1`, or
    doesn't resolve to a live folder, is treated as absent, never raises;
    pointers are compared case-insensitively (cast + downcased) so casing
    differences never make a pointer look "absent". Once a record is an
    actual CANDIDATE (it has a resolvable current folder), reload it as the
    FULL row in one batched `where uuid in ^candidates` query before calling
    any hook on it — hooks are opaque and may read fields well beyond the
    light select (a light `Category` select missing `parent_uuid` planned
    28 wrong moves to the catalogue root on 2026-09-15). Never call a hook
    for a record that isn't a candidate — there's nothing to move.
  - **Deterministic order**: parents before children when the module has
    that hierarchy (e.g. category before item), then by `inserted_at`/uuid,
    so re-running `plan/2` against unchanged data always proposes the same
    order. This holds for orphan/pending candidates too (explicit
    `order_by`), not only for move actions.
  - **`counts` contract**: measured at plan time as `{files, links}` where
    `files` is EVERY row of `phoenix_kit_files` with `folder_uuid ==
    folder.uuid` (any status, including trashed) and `links` is every row of
    `phoenix_kit_media_folder_links` with that `folder_uuid` — the engine
    re-counts the same way before and after applying, so a Source must not
    filter either count by status.
  """

  @doc """
  Returns the actions this source plans for the current database state.

  `actor_uuid` is passed straight through to the module's own hooks (the
  same actor a fresh upload would use). `opts` carries engine options such
  as `pending_days` (default `7`).
  """
  @callback plan(actor_uuid :: String.t() | nil, opts :: keyword()) :: [map()]
end
