defmodule PhoenixKit.Modules.Storage.TesseraAdapter do
  @moduledoc """
  `Tessera.Storage` adapter that routes tile writes through
  `PhoenixKit.Modules.Storage.Manager`.

  When `Tessera.generate_tile/4` or `Tessera.generate_manifest/3` is called
  with `storage: PhoenixKit.Modules.Storage.TesseraAdapter`, the generated
  file gets persisted to every bucket the operator has configured (S3,
  Backblaze, local — whichever providers are active), under the
  `_tiles/<key>` prefix so it can't collide with the variant tree.

  Reads, existence checks, and deletes happen from the consumer side via
  `Manager.file_exists?/1`, `Manager.retrieve_file/1`, and friends — Tessera
  itself never reads back what it wrote.
  """

  @behaviour Tessera.Storage

  alias PhoenixKit.Modules.Storage.Manager

  @prefix "_tiles/"

  @doc """
  Persist `content_path` to every configured bucket at the destination
  `_tiles/<key>`.

  Returns `:ok` on success (at least one bucket succeeded) or
  `{:error, reason}` otherwise.
  """
  @impl Tessera.Storage
  def put(content_path, key, _opts) do
    destination = @prefix <> key

    case Manager.store_file(content_path, path_prefix: destination) do
      {:ok, _info} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the storage-side destination path for a tile/manifest key.

  Use this when reading tiles back via `Manager.file_exists?/1` or
  `Manager.retrieve_file/1`, so the same prefix this adapter uses for
  writes is applied for reads.
  """
  def destination_for(key), do: @prefix <> key
end
