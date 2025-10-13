defmodule PhoenixKit.Pages.FileOperations do
  @moduledoc """
  Filesystem operations for Pages module.

  Handles reading, writing, listing files and folders.
  """

  alias PhoenixKit.Pages

  @doc """
  Lists all files and folders in a directory.

  Returns a list of maps with name, type (:file or :folder), and path.

  ## Examples

      iex> FileOperations.list_directory("/")
      {:ok, [
        %{name: "blog", type: :folder, path: "/blog"},
        %{name: "hello.md", type: :file, path: "/hello.md"}
      ]}
  """
  def list_directory(relative_path \\ "/") do
    full_path = build_full_path(relative_path)

    # Debug logging
    require Logger
    Logger.debug("Pages list_directory: full_path=#{inspect(full_path)}")

    case File.ls(full_path) do
      {:ok, entries} ->
        Logger.debug("Pages list_directory: found #{length(entries)} entries: #{inspect(entries)}")

        items =
          entries
          |> Enum.map(fn entry ->
            entry_path = Path.join(full_path, entry)
            relative = Path.join(relative_path, entry)

            type =
              case File.dir?(entry_path) do
                true -> :folder
                false -> :file
              end

            %{
              name: entry,
              type: type,
              path: relative,
              full_path: entry_path
            }
          end)
          |> Enum.sort_by(fn item ->
            # Folders first, then files, alphabetically
            {item.type != :folder, String.downcase(item.name)}
          end)

        {:ok, items}

      {:error, reason} ->
        Logger.debug("Pages list_directory: error #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Reads file content.

  ## Examples

      iex> FileOperations.read_file("/hello.md")
      {:ok, "# Hello World"}
  """
  def read_file(relative_path) do
    full_path = build_full_path(relative_path)
    File.read(full_path)
  end

  @doc """
  Writes content to a file.

  Creates parent directories if they don't exist.

  ## Examples

      iex> FileOperations.write_file("/hello.md", "# Hello World")
      :ok
  """
  def write_file(relative_path, content) do
    full_path = build_full_path(relative_path)

    # Ensure parent directory exists
    full_path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(full_path, content)
  end

  @doc """
  Creates a new directory.

  ## Examples

      iex> FileOperations.create_directory("/blog")
      :ok
  """
  def create_directory(relative_path) do
    full_path = build_full_path(relative_path)
    File.mkdir_p(full_path)
  end

  @doc """
  Checks if a path exists.

  ## Examples

      iex> FileOperations.exists?("/hello.md")
      true
  """
  def exists?(relative_path) do
    full_path = build_full_path(relative_path)
    File.exists?(full_path)
  end

  @doc """
  Gets file info (size, modified time, etc).

  ## Examples

      iex> FileOperations.file_info("/hello.md")
      {:ok, %{size: 1024, mtime: ~U[2025-01-01 00:00:00Z]}}
  """
  def file_info(relative_path) do
    full_path = build_full_path(relative_path)

    case File.stat(full_path) do
      {:ok, stat} ->
        {:ok,
         %{
           size: stat.size,
           mtime: stat.mtime,
           type: stat.type
         }}

      error ->
        error
    end
  end

  # Private helpers

  defp build_full_path(relative_path) do
    # Normalize path (remove leading/trailing slashes)
    normalized =
      relative_path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    # Prevent directory traversal attacks
    if String.contains?(normalized, "..") do
      raise "Invalid path: directory traversal not allowed"
    end

    # Build full path
    root = Pages.root_path()
    full_path = Path.join(root, normalized)

    # Double-check path is within root directory (security check)
    if String.starts_with?(full_path, root) do
      full_path
    else
      raise "Invalid path: attempting to access outside root directory"
    end
  end
end
