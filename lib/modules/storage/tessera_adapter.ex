defmodule PhoenixKit.Modules.Storage.TesseraAdapter do
  @moduledoc """
  `Tessera.Storage` adapter that lands tile / manifest writes inside
  PhoenixKit's storage pipeline:

    * writes the binary into every configured bucket via
      `PhoenixKit.Modules.Storage.Manager.store_file/2` under the
      `_tiles/` prefix (multi-bucket redundancy applies)
    * creates a system-managed `File` row + one `"original"`
      `FileInstance` row for the chunk via `Storage.store_system_file/3`,
      so the chunk is tracked in the DB and cascades away when the
      source File is deleted

  ## Required `storage_opts`

  Callers must pass the source image's UUID so the chunk knows its
  parent:

      Tessera.generate_tile(
        original_path, {level, col, row}, "<uuid>/<uuid>",
        image_width: w,
        image_height: h,
        storage: PhoenixKit.Modules.Storage.TesseraAdapter,
        storage_opts: [
          parent_file_uuid: source_file_uuid,
          mime_type: "image/jpeg"
        ]
      )

  Reads, existence checks, and deletes happen from the consumer side
  (see `PhoenixKitWeb.FileController.serve_tile/2` and the cascade FK
  on `parent_file_uuid` in V112).
  """

  @behaviour Tessera.Storage

  alias PhoenixKit.Modules.Storage

  @prefix "_tiles/"

  @doc """
  Persist `content_path` under `_tiles/<key>` in every configured bucket
  *and* create a system-managed File + FileInstance pair in the DB.

  Returns `:ok` or `{:error, reason}`. If the bucket write succeeded
  but DB row creation failed, the bucket data is left in place
  (orphaned) — the controller will treat the next request as a cache
  miss and try again.
  """
  @impl Tessera.Storage
  def put(content_path, key, opts) do
    parent_file_uuid = Keyword.fetch!(opts, :parent_file_uuid)
    mime_type = Keyword.fetch!(opts, :mime_type)

    destination = destination_for(key)

    case Storage.store_system_file(content_path, destination,
           parent_file_uuid: parent_file_uuid,
           mime_type: mime_type,
           file_type: "tile",
           metadata: Keyword.get(opts, :metadata)
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns the storage-side destination path for a tile/manifest key
  (prepends the `_tiles/` prefix this adapter uses for writes).
  """
  def destination_for(key), do: @prefix <> key
end
