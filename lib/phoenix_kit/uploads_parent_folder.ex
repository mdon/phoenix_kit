defmodule PhoenixKit.UploadsParentFolder do
  @moduledoc """
  Host hook for core's own uploads (user avatars, branding logos, media
  selector uploads with a scope):

      config :phoenix_kit, :uploads_parent_folder, {MyApp.Media, :parent_for}

  called as `parent_for(kind, actor_uuid, subject)` (or `parent_for(kind, actor_uuid)`),
  `kind` ∈ `:avatar | :branding`, returning `{:ok, folder_uuid}` or `nil` (root, default).

  - `actor_uuid` is whoever is uploading. On the admin user form that is the
    admin and `subject` is the user being edited; `Auth.update_user_avatar/4`
    passes the avatar's owner as both.
  - The avatar and branding pickers pass the answer to `MediaSelectorModal`
    as `scope_folder_id`, which **also scopes browsing** to that folder's
    subtree — files outside it are not offered in those pickers.
  - The pickers consult the hook when they open, not on page mount, so a
    hook that lazily creates its folder does so only when someone uploads.
  - An answer that is not a UUID, names no folder, or names a trashed folder
    is treated as `nil`, as is a hook that raises or exits.
  """
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder

  require Logger

  @type hook :: {module(), atom()} | nil

  @spec resolve(atom(), String.t() | nil, term()) :: String.t() | nil
  def resolve(kind, actor_uuid, subject \\ nil) do
    resolve_with(
      Application.get_env(:phoenix_kit, :uploads_parent_folder),
      kind,
      actor_uuid,
      subject
    )
  end

  @doc false
  # Shared with modules that follow the same hook convention under their own
  # config key (see the Storage moduledoc's "Folder conventions for modules").
  @spec resolve_with(hook() | term(), atom(), String.t() | nil, term()) :: String.t() | nil
  def resolve_with({mod, fun}, kind, actor_uuid, subject) when is_atom(mod) and is_atom(fun) do
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
      {:ok, uuid} when is_binary(uuid) -> live_folder_uuid(uuid, kind)
      _ -> nil
    end
  rescue
    error ->
      Logger.warning("[UploadsParentFolder] hook failed for #{inspect(kind)}: #{inspect(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("[UploadsParentFolder] hook exited for #{inspect(kind)}: #{inspect(reason)}")
      nil
  end

  def resolve_with(_hook, _kind, _actor_uuid, _subject), do: nil

  @doc "Attach `file` to the host folder for `kind`; no-op when the host answers nil."
  @spec place(Storage.File.t(), atom(), String.t() | nil, term()) :: :ok
  def place(file, kind, actor_uuid, subject \\ nil) do
    place_with(
      Application.get_env(:phoenix_kit, :uploads_parent_folder),
      file,
      kind,
      actor_uuid,
      subject
    )
  end

  @doc false
  @spec place_with(hook() | term(), Storage.File.t(), atom(), String.t() | nil, term()) :: :ok
  def place_with(hook, file, kind, actor_uuid, subject) do
    case resolve_with(hook, kind, actor_uuid, subject) do
      nil -> :ok
      folder_uuid -> attach(file, folder_uuid)
    end
  end

  # Placement never fails the upload it follows: the file is already stored
  # and the caller still has to record it.
  defp attach(file, folder_uuid) do
    case Storage.attach_file_to_folder(file, folder_uuid) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("[UploadsParentFolder] could not place #{file.uuid}: #{inspect(other)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[UploadsParentFolder] could not place #{file.uuid}: #{inspect(error)}")
      :ok
  end

  # `attach_file_to_folder/2` writes a root file's `folder_uuid` through a bare
  # `change/2`, so a uuid naming no folder raises a foreign-key error rather
  # than returning one; a trashed folder would silently receive new uploads.
  defp live_folder_uuid(uuid, kind) do
    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %Folder{trashed_at: nil} <- Storage.get_folder(uuid) do
      uuid
    else
      _ ->
        Logger.warning(
          "[UploadsParentFolder] hook for #{inspect(kind)} answered #{inspect(uuid)}, " <>
            "which is not a live folder; using the root"
        )

        nil
    end
  end
end
