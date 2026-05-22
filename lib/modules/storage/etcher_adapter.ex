defmodule PhoenixKit.Modules.Storage.EtcherAdapter do
  @moduledoc """
  Persistence helper for the MediaBrowser's annotation flow.

  Etcher 0.3 dropped the `Etcher.Storage` behaviour entirely — annotations
  now live inside the host `<Fresco.canvas>`'s `extensions.etcher` blob
  and the library doesn't reach into the consumer's DB anymore. PhoenixKit
  still needs to persist its annotations (they're per-file, not per-canvas-
  file-on-disk), so this module survives as a thin helper module called
  from the MediaBrowser LV's `etcher:annotations-changed` event handler —
  not as a behaviour implementation.

  The four public functions (`create/1`, `list_for/2`, `update/2`,
  `delete/1`) keep their pre-0.3 signatures so the diff in MediaBrowser
  stays small. None of them are `@impl` annotations anymore; they're
  just plain helpers wrapping the `PhoenixKit.Annotations` context.

  Etcher's generic API is keyed by `target_type` + `target_uuid` so the
  library can annotate any kind of resource. In PhoenixKit the only
  target is a media File, so this adapter requires `target_type ==
  "file"` and maps `target_uuid` to `file_uuid`.

  ## Comment threads

  An annotation's discussion thread is **not** created at draw time —
  it's instantiated lazily when the user posts the first comment on the
  annotation. The comments are anchored to the **file**
  (`resource_type = "file"`, `resource_uuid = file_uuid`) with
  `metadata.annotation_uuid` carrying the back-reference, so they
  appear in the file's main thread alongside non-annotated discussion.
  No `comment_uuid` column on annotations is needed.
  """

  alias PhoenixKit.Annotations
  alias PhoenixKit.Annotations.Annotation

  # Whitelist of annotation schema fields the helper accepts from event
  # payloads, sourced from `Annotation.adapter_writable_fields/0` so the
  # set stays in sync with the schema's `@cast_fields`. Anything else
  # (Etcher routing keys, JS-side anchor coords, comment-derived metadata
  # we hydrate server-side) is silently dropped — `String.to_existing_atom`
  # on unknown payload keys used to crash the LV when Etcher's payload
  # shape grew new client-side keys. Stored as strings here since the
  # filter compares against `to_string(payload_key)`.
  @schema_keys Enum.map(Annotation.adapter_writable_fields(), &Atom.to_string/1)

  def create(attrs) do
    with {:ok, file_uuid} <- target_uuid(attrs) do
      attrs
      |> filter_to_schema()
      |> Map.put(:file_uuid, file_uuid)
      |> Annotations.create()
    end
  end

  def list_for(target_type, target_uuid)

  def list_for("file", file_uuid) when is_binary(file_uuid) do
    Annotations.list_for_file(file_uuid)
  end

  def list_for(_other, _uuid), do: []

  def update(uuid, attrs) do
    attrs
    |> filter_to_schema()
    |> then(&Annotations.update(uuid, &1))
  end

  def delete(uuid), do: Annotations.delete(uuid)

  # ---------------------------------------------------------------------------

  defp target_uuid(%{"target_type" => "file", "target_uuid" => uuid}) when is_binary(uuid),
    do: {:ok, uuid}

  defp target_uuid(%{target_type: "file", target_uuid: uuid}) when is_binary(uuid),
    do: {:ok, uuid}

  defp target_uuid(_attrs), do: {:error, :unsupported_target}

  defp filter_to_schema(attrs) do
    Enum.reduce(attrs, %{}, fn {k, v}, acc ->
      key = to_string(k)
      if key in @schema_keys, do: Map.put(acc, String.to_existing_atom(key), v), else: acc
    end)
  end
end
