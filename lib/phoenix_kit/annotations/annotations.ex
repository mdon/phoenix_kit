defmodule PhoenixKit.Annotations do
  # PhoenixKitComments is an optional sibling package. The preview-loader
  # (`list_for_file_with_previews/1`) guards every call with
  # `Code.ensure_loaded?/1` and gracefully degrades when comments aren't
  # installed; silence the undefined warnings the compiler would emit.
  @compile {:no_warn_undefined, [PhoenixKitComments]}

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

  @doc """
  List annotations for a file together with a tooltip-friendly preview of
  their comment thread. Each element is a map:

      %{
        annotation: %Annotation{},
        first_comment: %{content, author, thumbnail_url} | nil,
        comment_count: integer()
      }

  Annotation comments are stored against the file (`resource_type: "file"`,
  `resource_uuid: file_uuid`) with `metadata.annotation_uuid` pointing at
  the annotation, so they show up in the file's main comments thread
  alongside non-annotated discussion. This loader pulls every file
  comment in one query and groups by that metadata key.

  If the comments package isn't installed, returns the same shape with
  `first_comment: nil` and `comment_count: 0` so callers always handle
  one schema.
  """
  @spec list_for_file_with_previews(uuid()) :: [map()]
  def list_for_file_with_previews(file_uuid) do
    annotations = list_for_file(file_uuid)

    by_annotation =
      if Code.ensure_loaded?(PhoenixKitComments) do
        group_file_comments_by_annotation(file_uuid)
      else
        %{}
      end

    Enum.map(annotations, fn ann ->
      comments = Map.get(by_annotation, ann.uuid, [])
      Map.merge(%{annotation: ann}, build_preview(comments))
    end)
  end

  defp group_file_comments_by_annotation(file_uuid) do
    all = PhoenixKitComments.list_comments("file", file_uuid, preload: [:user, media: :file])

    # Build a parent_uuid → [children] map so we can walk the tree from
    # each annotation-rooted comment and pick up every reply. The
    # tooltip's count should reflect total activity on the annotation,
    # not just the root post.
    children_by_parent = Enum.group_by(all, & &1.parent_uuid)

    all
    |> Enum.filter(fn c -> is_binary(get_in(c.metadata || %{}, ["annotation_uuid"])) end)
    |> Enum.reduce(%{}, fn root, acc ->
      annotation_uuid = get_in(root.metadata, ["annotation_uuid"])
      cluster = collect_subtree(root, children_by_parent)
      Map.update(acc, annotation_uuid, cluster, &(&1 ++ cluster))
    end)
  end

  defp collect_subtree(root, children_by_parent) do
    children = Map.get(children_by_parent, root.uuid, [])
    [root | Enum.flat_map(children, &collect_subtree(&1, children_by_parent))]
  end

  # Comments arrive ordered by inserted_at asc from list_comments/3, so
  # the first top-level entry is the earliest reply. If everything is a
  # reply (rare — usually there's a root), fall back to the first.
  defp build_preview([]), do: %{first_comment: nil, comment_count: 0}

  defp build_preview(comments) do
    first =
      case Enum.find(comments, fn c -> c.parent_uuid == nil end) do
        nil -> hd(comments)
        c -> c
      end

    %{first_comment: build_first_comment(first), comment_count: length(comments)}
  end

  defp build_first_comment(nil), do: nil

  defp build_first_comment(comment) do
    %{
      content: comment.content,
      author: author_display(comment.user),
      thumbnail_url: first_attachment_thumbnail(comment) || giphy_preview(comment),
      # `has_attachment` lets the tooltip render a paperclip fallback
      # icon when the comment has media but no usable thumbnail URL
      # (e.g. variant generation hasn't completed yet, or the file
      # isn't an image so there's no preview to render).
      has_attachment: has_any_media?(comment)
    }
  end

  defp has_any_media?(%{media: media}) when is_list(media) and media != [], do: true
  defp has_any_media?(_), do: false

  defp author_display(nil), do: nil

  defp author_display(user) do
    case {user.first_name, user.last_name, user.email} do
      {fn_, ln, _} when is_binary(fn_) and is_binary(ln) and fn_ != "" and ln != "" ->
        "#{fn_} #{ln}"

      {fn_, _, _} when is_binary(fn_) and fn_ != "" ->
        fn_

      {_, _, email} when is_binary(email) ->
        email |> String.split("@", parts: 2) |> hd()

      _ ->
        nil
    end
  end

  defp first_attachment_thumbnail(comment) do
    # `comment.media` is `%Ecto.Association.NotLoaded{}` when the
    # preload didn't fire, an empty list for a no-attachment comment,
    # or a list of `CommentMedia` rows (the smallest position first per
    # the schema's `preload_order`).
    with [%{file: file} | _] when is_struct(file, PhoenixKit.Modules.Storage.File) <-
           comment.media do
      # Walk the available variants smallest-first. `get_public_url_by_variant`
      # already falls back to the original when the requested variant
      # doesn't exist, but we still want to land on "thumbnail" when it's
      # there. Non-image files (PDF, zip, audio) have no thumbnail; for
      # those the JS picks up `has_attachment` and renders a paperclip
      # icon instead.
      if image?(file) do
        PhoenixKit.Modules.Storage.get_public_url_by_variant(file, "thumbnail")
      else
        nil
      end
    else
      _ -> nil
    end
  end

  defp image?(%PhoenixKit.Modules.Storage.File{mime_type: "image/" <> _}), do: true
  defp image?(_), do: false

  defp giphy_preview(%{metadata: %{"giphy" => %{"preview_url" => url}}}) when is_binary(url),
    do: url

  defp giphy_preview(_), do: nil

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

  @doc """
  Delete an annotation by UUID.

  Cascades to any linked comments — i.e. comments on the annotation's
  file that carry `metadata.annotation_uuid` pointing at this row. The
  cascade is a soft delete (status: "deleted") so reply chains stay
  attached as `[removed]` placeholders rather than disappearing
  silently. No-ops cleanly when PhoenixKitComments isn't installed.
  """
  @spec delete(uuid()) :: :ok | {:error, :not_found | Ecto.Changeset.t()}
  def delete(uuid) do
    case RepoHelper.get(Annotation, uuid) do
      nil ->
        {:error, :not_found}

      annotation ->
        delete_linked_comments(annotation)

        case RepoHelper.delete(annotation) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end
    end
  end

  defp delete_linked_comments(annotation) do
    if Code.ensure_loaded?(PhoenixKitComments) do
      "file"
      |> PhoenixKitComments.list_comments(annotation.file_uuid)
      |> Enum.filter(fn c ->
        get_in(c.metadata || %{}, ["annotation_uuid"]) == annotation.uuid
      end)
      |> Enum.each(&PhoenixKitComments.delete_comment/1)
    end
  rescue
    # Swallow comment-side errors so an annotation can still be deleted
    # even if the comments package has issues. Orphan comments are
    # benign (they just show in the file thread without their pin).
    _ -> :ok
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
