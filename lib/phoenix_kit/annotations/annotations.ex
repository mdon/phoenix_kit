defmodule PhoenixKit.Annotations do
  @moduledoc """
  Context for `phoenix_kit_annotations` — drawn-on-image shapes created
  via the Etcher overlay layer in the MediaBrowser modal.

  Most callers won't use this directly — they go through
  `PhoenixKit.Modules.Storage.EtcherAdapter` which implements the
  `Etcher.Storage` behaviour and dispatches to this context. The module
  is exposed so admin tooling, audits, or background workers can do
  CRUD without reaching for the adapter.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Annotations.Annotation
  alias PhoenixKit.RepoHelper

  @type attrs :: map()
  @type uuid :: String.t()

  @doc """
  Create an annotation for a file.

  `attrs` accepts both atom- and string-keyed maps (the latter is what
  flows in from LiveView events). Keys: `:file_uuid`, `:kind`,
  `:geometry`, optional `:creator_uuid`, `:style`, `:metadata`,
  `:position`.
  """
  @spec create(attrs()) :: {:ok, Annotation.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Annotation{}
    |> Annotation.changeset(normalize(attrs))
    |> RepoHelper.insert()
  end

  @doc "List annotations for a file, ordered by `position` then insertion time."
  @spec list_for_file(uuid()) :: [Annotation.t()]
  def list_for_file(file_uuid) do
    RepoHelper.all(
      from a in Annotation,
        where: a.file_uuid == ^file_uuid,
        order_by: [asc: a.position, asc: a.inserted_at]
    )
  end

  @doc "Fetch a single annotation by UUID, or nil."
  @spec get(uuid()) :: Annotation.t() | nil
  def get(uuid), do: RepoHelper.get(Annotation, uuid)

  @doc "Update an annotation's geometry / style / metadata / position."
  @spec update(uuid(), attrs()) ::
          {:ok, Annotation.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update(uuid, attrs) do
    case RepoHelper.get(Annotation, uuid) do
      nil ->
        {:error, :not_found}

      annotation ->
        annotation
        |> Annotation.changeset(normalize(attrs))
        |> RepoHelper.update()
    end
  end

  @doc "Delete an annotation by UUID."
  @spec delete(uuid()) :: :ok | {:error, :not_found | Ecto.Changeset.t()}
  def delete(uuid) do
    case RepoHelper.get(Annotation, uuid) do
      nil ->
        {:error, :not_found}

      annotation ->
        case RepoHelper.delete(annotation) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  # Accept both string- and atom-keyed maps. Falls back to passing the
  # map through untouched if any key can't be converted (the changeset
  # will then reject the unknown fields).
  defp normalize(attrs) when is_map(attrs) do
    Enum.into(attrs, %{}, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
