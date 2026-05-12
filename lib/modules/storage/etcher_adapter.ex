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
  annotation. The linkage is one-directional from the comments table
  via the existing `resource_type` / `resource_uuid` convention
  (`resource_type = "annotation"`, `resource_uuid = annotation.uuid`).
  No `comment_uuid` column on annotations is needed.
  """

  @behaviour Etcher.Storage

  alias PhoenixKit.Annotations

  @impl Etcher.Storage
  def create(attrs) do
    with {:ok, file_uuid} <- target_uuid(attrs) do
      attrs
      |> Map.new(fn {k, v} -> {to_atom(k), v} end)
      |> Map.put(:file_uuid, file_uuid)
      |> Map.drop([:target_type, :target_uuid, :tmp_id])
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
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_atom(k), v} end)
      |> Map.drop([:target_type, :target_uuid, :tmp_id])

    Annotations.update(uuid, attrs)
  end

  @impl Etcher.Storage
  def delete(uuid), do: Annotations.delete(uuid)

  # ---------------------------------------------------------------------------

  defp target_uuid(%{"target_type" => "file", "target_uuid" => uuid}) when is_binary(uuid),
    do: {:ok, uuid}

  defp target_uuid(%{target_type: "file", target_uuid: uuid}) when is_binary(uuid),
    do: {:ok, uuid}

  defp target_uuid(_attrs), do: {:error, :unsupported_target}

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_existing_atom(k)
end
