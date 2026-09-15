defmodule PhoenixKit.UploadsParentFolder do
  @moduledoc """
  Host hook for core's own uploads (user avatars, branding logos, media
  selector uploads with a scope):

      config :phoenix_kit, :uploads_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(kind, actor_uuid, subject)` (or `parent_for(kind, actor_uuid)`),
  `kind` ∈ `:avatar | :branding`, returning `{:ok, folder_uuid}` or `nil` (root, default).
  """
  alias PhoenixKit.Modules.Storage

  require Logger

  @spec resolve(atom(), String.t() | nil, term()) :: String.t() | nil
  def resolve(kind, actor_uuid, subject \\ nil) do
    case Application.get_env(:phoenix_kit, :uploads_parent_folder) do
      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        result =
          cond do
            Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
              apply(mod, fun, [kind, actor_uuid, subject])

            Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
              apply(mod, fun, [kind, actor_uuid])

            true ->
              nil
          end

        case result do
          {:ok, uuid} when is_binary(uuid) -> uuid
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    error ->
      Logger.warning("[UploadsParentFolder] hook failed for #{inspect(kind)}: #{inspect(error)}")
      nil
  end

  @doc "Attach `file` to the host folder for `kind`; no-op when the host answers nil."
  @spec place(PhoenixKit.Modules.Storage.File.t(), atom(), String.t() | nil, term()) :: :ok
  def place(file, kind, actor_uuid, subject \\ nil) do
    case resolve(kind, actor_uuid, subject) do
      nil ->
        :ok

      folder_uuid ->
        case Storage.attach_file_to_folder(file, folder_uuid) do
          {:ok, _} ->
            :ok

          :ok ->
            :ok

          other ->
            Logger.warning(
              "[UploadsParentFolder] could not place #{file.uuid}: #{inspect(other)}"
            )

            :ok
        end
    end
  end
end
