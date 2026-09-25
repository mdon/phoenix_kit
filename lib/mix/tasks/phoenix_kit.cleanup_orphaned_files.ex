defmodule Mix.Tasks.PhoenixKit.CleanupOrphanedFiles do
  @moduledoc """
  Finds orphaned media files in PhoenixKit Storage and optionally moves them
  to the trash.

  An orphaned file is one not referenced by any known entity (products, posts,
  categories, users, publishing content, etc.).

  By default this task runs in dry-run mode and only reports what it found.
  Use `--delete` to queue them, via Oban, to be moved to the trash. Nothing
  is deleted outright: a trashed file can be restored until the daily trash
  prune deletes it after `trash_retention_days`.

  ## Usage

      $ mix phoenix_kit.cleanup_orphaned_files
      $ mix phoenix_kit.cleanup_orphaned_files --delete

  ## Options

    * `--delete` - Queue orphaned files to be moved to the trash (default: dry-run)

  ## Examples

      # Dry-run: show orphaned files without touching them
      mix phoenix_kit.cleanup_orphaned_files

      # Move all orphaned files to the trash
      mix phoenix_kit.cleanup_orphaned_files --delete

  """

  use Mix.Task

  alias PhoenixKit.Modules.Storage

  @shortdoc "Find orphaned media files and optionally move them to the trash"

  @switches [delete: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)
    do_delete = opts[:delete] || false

    Mix.shell().info("\nPhoenixKit Storage — Orphaned Files Cleanup")
    Mix.shell().info(String.duplicate("─", 50))

    count = Storage.count_orphaned_files()

    if count == 0 do
      Mix.shell().info("✓ No orphaned files found.")
      :ok
    else
      orphans = Storage.find_orphaned_files()

      if do_delete do
        Mix.shell().info("Found #{count} orphaned file(s). Queuing them for the trash...\n")
      else
        Mix.shell().info(
          "Found #{count} orphaned file(s) (dry-run — use --delete to move them to the trash):\n"
        )
      end

      Enum.each(orphans, fn file ->
        size = format_size(file.size || 0)
        name = file.original_file_name || file.file_name || "unknown"
        Mix.shell().info("  #{file.uuid}  #{name}  (#{size})")
      end)

      if do_delete do
        uuids = Enum.map(orphans, & &1.uuid)
        Storage.queue_file_cleanup(uuids)
        Mix.shell().info("\n✓ #{count} file(s) queued to be moved to the trash (60s delay).")
      else
        Mix.shell().info("\nRun with --delete to move these files to the trash.")
      end

      :ok
    end
  end

  defp format_size(bytes) when bytes >= 1_000_000,
    do: "#{Float.round(bytes / 1_000_000, 2)} MB"

  defp format_size(bytes) when bytes >= 1_000,
    do: "#{Float.round(bytes / 1_000, 2)} KB"

  defp format_size(bytes), do: "#{bytes} B"
end
