defmodule PhoenixKitWeb.Attachments do
  @moduledoc """
  The pieces every module's file form shares, so each upload behaves the
  same wherever it happens: the upload config, storing a finished upload
  into a record's folder, the messages people see, and the files grid's
  featured-image and order rules.

      socket = Attachments.allow(socket, :attachment_files, &handle_progress/3)

      def handle_progress(:attachment_files, %{done?: true} = entry, socket) do
        stored =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            {:ok, Attachments.store(path, entry, Actor.uuid(socket), folder_uuid)}
          end)

        case stored do
          {:ok, _file} -> …
          {:already_attached, existing} -> put_flash(socket, :info, Attachments.duplicate_notice(entry.client_name, existing))
          {:error, reason} -> put_flash(socket, :error, Attachments.failed_message(entry.client_name, reason))
        end
      end

  What each form keeps — which folder, when its pointers are written, who
  hears about a change — is its own; the folder rules underneath are
  `PhoenixKit.Modules.Storage.ResourceFolders`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Users.Auth

  @defaults [
    accept: :any,
    max_entries: 20,
    max_file_size: 100_000_000,
    auto_upload: true
  ]

  @doc """
  Registers upload `name` with the attachment defaults — any file type,
  20 files, 100 MB each, uploaded as soon as they are chosen — and
  `progress` as its progress callback. `opts` override the defaults.
  """
  @spec allow(Phoenix.LiveView.Socket.t(), atom(), function(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def allow(socket, name, progress, opts \\ []) when is_atom(name) and is_function(progress, 3) do
    Phoenix.LiveView.allow_upload(
      socket,
      name,
      @defaults |> Keyword.merge(opts) |> Keyword.put(:progress, progress)
    )
  end

  @doc """
  Stores a finished upload (the temp `path` of `entry`) for `user_uuid`
  and files it into `folder_uuid` by core's rules
  (`ResourceFolders.place_stored/2`): a content duplicate already in the
  folder is `{:already_attached, file}`, a trashed one is restored. The
  browser's file name is reduced to its base name before it reaches
  storage, and the type comes from `Storage.determine_file_type/2`.
  `nil` for the folder stores the file without placing it (a form that
  files it on save); a trashed duplicate is restored then too, so the
  file returned is always live. Never raises — call it outside a
  transaction, which a database error would abort.
  """
  @spec store(String.t(), map(), String.t() | nil, String.t() | nil) ::
          {:ok, Storage.File.t()} | {:already_attached, Storage.File.t()} | {:error, term()}
  def store(_path, _entry, nil, _folder_uuid), do: {:error, :no_user}

  def store(path, entry, user_uuid, folder_uuid) do
    name = client_name(entry)
    mime = client_type(entry)
    ext = name |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    hash = Auth.calculate_file_hash(path)

    path
    |> Storage.store_file_in_buckets(
      Storage.determine_file_type(mime, name),
      user_uuid,
      hash,
      ext,
      name,
      mime_type: mime
    )
    |> place(folder_uuid)
  rescue
    error ->
      Logger.warning("Storing an upload failed: #{ResourceFolders.describe_failure(error)}")
      {:error, error}
  catch
    :exit, reason ->
      Logger.warning(
        "Storing an upload failed: #{ResourceFolders.describe_failure({:exit, reason})}"
      )

      {:error, {:exit, reason}}
  end

  defp place({:ok, file}, nil), do: {:ok, file}

  # Re-uploading a file that was trashed means it is wanted again — as
  # `place_stored/2` does when there is a folder. A form that files on save
  # would otherwise stage the trashed row and then fail to attach it.
  # Into no folder: it is staged, and the folder it was removed from must not
  # show it again.
  defp place({:ok, %{status: "trashed"} = file, :duplicate}, nil),
    do: Storage.restore_file_into(file, nil)

  defp place({:ok, file, :duplicate}, nil), do: {:ok, file}

  defp place(stored, folder_uuid) when is_binary(folder_uuid),
    do: ResourceFolders.place_stored(stored, folder_uuid)

  defp place({:error, reason}, _folder_uuid), do: {:error, reason}

  # `client_name` is the browser's and only checked against `:accept`: a path
  # (either separator), control characters (a NUL fails the insert) and a
  # bare "." or ".." never reach storage as a file name, and the name fits
  # the 255-character column with its extension kept.
  @max_name 255

  defp client_name(entry) do
    name =
      entry
      |> Map.get(:client_name)
      |> to_string()
      |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
      |> String.split(["/", "\\"])
      |> List.last()

    if name in ["", ".", ".."], do: "upload", else: bounded(name)
  end

  # Also the browser's: kept only when it reads as a mime type (parameters
  # dropped), so a long or garbage one cannot fail the insert — storage then
  # guesses from the name instead.
  @mime ~r/\A[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\z/i

  defp client_type(entry) do
    type =
      entry
      |> Map.get(:client_type)
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()

    if Regex.match?(@mime, type), do: type
  end

  # The column counts code points, not graphemes (an emoji can be several).
  defp bounded(name) do
    points = String.codepoints(name)

    if length(points) <= @max_name do
      name
    else
      ext = name |> Path.extname() |> String.codepoints() |> Enum.take(16)
      Enum.join(Enum.take(points, @max_name - length(ext)) ++ ext)
    end
  end

  @doc "What to tell a person about an upload error (LiveView's or `store/4`'s)."
  @spec error_message(term()) :: String.t()
  def error_message(:too_large), do: gettext("File is too large.")
  def error_message(:not_accepted), do: gettext("File type not accepted.")
  def error_message(:too_many_files), do: gettext("Too many files.")
  def error_message(:no_user), do: gettext("Sign in to upload files.")

  def error_message(other),
    do: gettext("Upload error: %{reason}", reason: ResourceFolders.describe_failure(other))

  @doc "What to tell a person when their upload `client_name` could not be stored."
  @spec failed_message(String.t(), term()) :: String.t()
  def failed_message(_client_name, :no_user), do: error_message(:no_user)

  def failed_message(client_name, _reason),
    do: gettext("Upload failed for %{name}.", name: Path.basename(to_string(client_name)))

  @doc """
  What to tell a person whose upload is byte-identical to a file already
  in the folder: storage de-duplicates by content, so nothing new appears
  and the file keeps the earlier upload's name — without this it reads as
  a lost file.
  """
  @spec duplicate_notice(String.t(), map()) :: String.t()
  def duplicate_notice(client_name, existing) do
    name = Path.basename(to_string(client_name))

    gettext("%{name} is identical to %{existing}, which is already attached — nothing was added.",
      name: name,
      existing: Map.get(existing, :original_file_name) || name
    )
  end

  @doc "What to tell a person when a record's files folder cannot be prepared."
  @spec folder_error_message() :: String.t()
  def folder_error_message, do: gettext("Could not prepare the files folder.")

  @doc """
  A folder's files with the record's featured image first when it lives
  elsewhere — a featured image moved out of the folder is still what the
  record shows, so the grid shows it too.
  """
  @spec with_featured([map()], map() | nil) :: [map()]
  def with_featured(files, nil), do: files

  def with_featured(files, %{uuid: uuid} = featured) do
    if Enum.any?(files, &(&1.uuid == uuid)), do: files, else: [featured | files]
  end

  @doc """
  Files sorted by a saved order of uuids: files the order doesn't know
  keep their relative place after the ordered ones (new uploads land
  last), and an empty order changes nothing.
  """
  @spec apply_order([map()], [String.t()] | nil) :: [map()]
  def apply_order(files, order) when is_list(order) and order != [] do
    index = order |> Enum.with_index() |> Map.new()
    tail = length(order)

    files
    |> Enum.with_index()
    |> Enum.sort_by(fn {file, position} ->
      {Map.get(index, to_string(file.uuid), tail), position}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def apply_order(files, _order), do: files
end
