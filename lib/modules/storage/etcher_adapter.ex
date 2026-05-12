defmodule PhoenixKit.Modules.Storage.EtcherAdapter do
  @moduledoc """
  `Etcher.Storage` adapter that writes annotation events from the
  MediaBrowser's Fresco viewer into `phoenix_kit_annotations`.

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

  @behaviour Etcher.Storage

  alias PhoenixKit.Annotations

  # Whitelist of annotation schema fields the adapter accepts from event
  # payloads. Anything else (Etcher routing keys, JS-side anchor coords,
  # client-side metadata) is silently dropped — `String.to_existing_atom`
  # on unknown payload keys used to crash the LV when Etcher's payload
  # shape grew new client-side keys like `anchor_x` / `anchor_y`.
  @schema_keys ~w(kind geometry style metadata position creator_uuid)

  @impl Etcher.Storage
  def create(attrs) do
    with {:ok, file_uuid} <- target_uuid(attrs) do
      attrs
      |> filter_to_schema()
      |> Map.put(:file_uuid, file_uuid)
      |> Annotations.create()
    end
  end

  @impl Etcher.Storage
  def list_for(target_type, target_uuid)

  def list_for("file", file_uuid) when is_binary(file_uuid) do
    Annotations.list_for_file(file_uuid)
  end

  def list_for(_other, _uuid), do: []

  @impl Etcher.Storage
  def update(uuid, attrs) do
    attrs
    |> filter_to_schema()
    |> then(&Annotations.update(uuid, &1))
  end

  @impl Etcher.Storage
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
