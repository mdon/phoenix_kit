defmodule PhoenixKit.Modules.Storage.Libraries do
  @moduledoc """
  Storage libraries: partitions of the file store (V202).

  Every stored file, media folder and folder link belongs to exactly one
  library (`library_uuid`). V202 put everything that existed into one system
  library, **Media**, under a fixed uuid (`media_uuid/0`), and made Media the
  column default — so a writer that names no library, in core or in any
  module, keeps landing there, and an install with a single library behaves
  exactly as it did before libraries existed.

  More system libraries can be created by an admin (`create_system_library/1`).
  Each keeps its own folders (folder names are unique per library and
  parent) and gives the files stored in it an object-key prefix of its own
  (`key_prefix`). User libraries, members and per-library storage are later
  phases of `dev_docs/plans/2026-09-22-storage-libraries.md`.

  ## What a library does NOT change yet

  Dedup is still per uploader across the whole install: uploading, into one
  library, bytes the same person already stored in another returns the file
  that exists — in the library it is in. `Storage.store_file_in_buckets/5`
  reports that as `{:ok, file, :duplicate}` like any other duplicate; callers
  that care (`MediaBrowser`) compare the libraries.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.{Folder, Library}
  alias PhoenixKit.Users.Auth.Scope

  @media_uuid "00000000-0000-7000-8000-000000000001"

  @doc """
  The uuid of Media, the default system library every existing file, folder
  and link was put into by V202, and the column default for new ones. Fixed
  on every install.
  """
  @spec media_uuid() :: String.t()
  def media_uuid, do: @media_uuid

  @doc "Whether `uuid` is Media's."
  @spec media?(term()) :: boolean()
  def media?(uuid), do: to_string(uuid) == @media_uuid

  @doc "A library by uuid, or nil (also for anything that is not a uuid)."
  @spec get_library(term()) :: Library.t() | nil
  def get_library(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} -> repo().get(Library, uuid)
      :error -> nil
    end
  end

  @doc """
  The live system libraries, the default (Media) first, then by name.
  """
  @spec list_system_libraries() :: [Library.t()]
  def list_system_libraries do
    from(l in Library,
      where: l.kind == "system" and is_nil(l.trashed_at),
      order_by: [desc: l.is_default, asc: fragment("lower(?)", l.name)]
    )
    |> repo().all()
  end

  @doc """
  The live system library with this uuid, or nil — what a URL-supplied
  library id is checked against before anything is listed or stored in it.
  """
  @spec get_system_library(term()) :: Library.t() | nil
  def get_system_library(uuid) do
    case get_library(uuid) do
      %Library{kind: "system", trashed_at: nil} = library -> library
      _ -> nil
    end
  end

  @doc """
  The live system library whose URL slug is `slug`, or nil. The default
  library has no slug (it is the bare `/admin/media`).
  """
  @spec get_system_library_by_slug(term()) :: Library.t() | nil
  def get_system_library_by_slug(slug) when is_binary(slug) do
    repo().one(
      from(l in Library,
        where: l.kind == "system" and is_nil(l.trashed_at) and l.slug == ^slug
      )
    )
  end

  def get_system_library_by_slug(_slug), do: nil

  @doc """
  Creates a system library. `attrs` takes a `"name"` (or `:name`). The URL
  slug comes from the name (`"Brand Assets"` → `"brand-assets"`, then
  `"brand-assets-2"` … while one is taken) and the object-key prefix is
  generated, unless either is given.
  """
  @spec create_system_library(map()) :: {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def create_system_library(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    attrs = Map.put_new_lazy(attrs, "key_prefix", &generate_key_prefix/0)

    case attrs do
      %{"slug" => _} -> insert_system_library(attrs)
      _ -> insert_with_free_slug(attrs, Library.slugify(to_string(attrs["name"])), 1)
    end
  end

  # Tries `base`, `base-2`, `base-3` … until the slug is free. Any other
  # error (a taken name, a blank one) is returned as it is.
  defp insert_with_free_slug(attrs, base, n) do
    slug = if n == 1, do: base, else: "#{base}-#{n}"

    case insert_system_library(Map.put(attrs, "slug", slug)) do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :slug) and not name_error?(changeset) and n < 100,
          do: insert_with_free_slug(attrs, base, n + 1),
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp name_error?(%Ecto.Changeset{errors: errors}), do: Keyword.has_key?(errors, :name)

  defp insert_system_library(attrs) do
    %Library{}
    |> Library.create_system_changeset(attrs)
    |> repo().insert()
  end

  @doc "Renames a library."
  @spec rename_library(Library.t(), String.t()) ::
          {:ok, Library.t()} | {:error, Ecto.Changeset.t()}
  def rename_library(%Library{} = library, name) do
    library
    |> Library.rename_changeset(%{name: name})
    |> repo().update()
  end

  @doc """
  Deletes a library that holds nothing. The default library is never
  deleted, and a library that still has a file or a folder — trashed ones
  included — is refused (`:not_empty`); the database refuses it too.
  """
  @spec delete_library(Library.t()) :: {:ok, Library.t()} | {:error, :default | :not_empty}
  def delete_library(%Library{is_default: true}), do: {:error, :default}

  def delete_library(%Library{uuid: uuid} = library) do
    holds? =
      repo().exists?(from(f in StorageFile, where: f.library_uuid == ^uuid)) or
        repo().exists?(from(f in Folder, where: f.library_uuid == ^uuid))

    if holds? do
      {:error, :not_empty}
    else
      case repo().delete(library) do
        {:ok, deleted} -> {:ok, deleted}
        {:error, _changeset} -> {:error, :not_empty}
      end
    end
  rescue
    Ecto.ConstraintError -> {:error, :not_empty}
  end

  @doc """
  Whether a library is a system library. Media always is; anything else is
  read. A missing library is not.
  """
  @spec system_library?(term()) :: boolean()
  def system_library?(uuid) do
    media?(uuid) or match?(%Library{kind: "system"}, get_library(uuid))
  end

  @doc """
  Whether `scope` may do `action` to `file`. One predicate for every
  per-file check, so they stop drifting apart:

    * `:read` — the file's info and signed URLs: its uploader, or an
      Owner/Admin (`Scope.system_role?/1`). Deliberately NOT the `"media"`
      permission: a single permission must not open every other user's
      file metadata (issue #687).
    * `:edit` — change the picture (image editing, annotation burn-in, the
      unedited original): the uploader, an Owner/Admin, or a holder of the
      `"media"` permission when the file is in a system library.

  Anything else, and a scope without a user, is refused.
  """
  @spec can?(Scope.t() | nil, map(), :read | :edit) :: boolean()
  def can?(%Scope{} = scope, %{} = file, action) when action in [:read, :edit] do
    uploader?(scope, file) or Scope.system_role?(scope) or
      (action == :edit and Scope.has_module_access?(scope, "media") and
         system_library?(Map.get(file, :library_uuid) || @media_uuid))
  end

  def can?(_scope, _file, _action), do: false

  defp uploader?(scope, file) do
    uuid = Scope.user_uuid(scope)
    is_binary(uuid) and to_string(Map.get(file, :user_uuid)) == uuid
  end

  defp generate_key_prefix do
    "lib-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
