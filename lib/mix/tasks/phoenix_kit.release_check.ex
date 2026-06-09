defmodule Mix.Tasks.PhoenixKit.ReleaseCheck do
  @moduledoc """
  Asserts release-metadata consistency before publishing to Hex.

  Catches the class of mistakes that `precommit`/`quality.ci` cannot see —
  version/CHANGELOG/migration drift and unsafe git state — and exits non-zero
  on any failure so it can gate `mix hex.publish`. It is the semantic core of
  the `mix prerelease` alias and runs without a database.

  ## Usage

      $ mix phoenix_kit.release_check
      $ mix phoenix_kit.release_check --allow-dirty --allow-branch

  ## Options

    * `--allow-dirty`  — downgrade the "working tree clean" check to a warning
    * `--allow-branch` — downgrade the "on main branch" check to a warning

  ## Checks Performed

    1. **CHANGELOG Heading** — top `## X.Y.Z` entry matches `mix.exs` `@version`
       (and is a real version, not "Unreleased").
    2. **CHANGELOG Body** — that entry has at least one content line.
    3. **Migration Version Sync** — `Migrations.Postgres.current_version/0`
       equals the highest `vNNN.ex` migration file on disk.
    4. **Git Tree Clean** — no uncommitted changes (`--allow-dirty` to warn).
    5. **Git Branch** — on `main` (`--allow-branch` to warn).
    6. **Tag Collision** — tag `v<version>` does not already exist (publish-
       before-tag means a pre-existing tag signals a double release).
  """

  use Mix.Task

  @shortdoc "Asserts version/CHANGELOG/migration/git consistency before a Hex release"

  @switches [allow_dirty: :boolean, allow_branch: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _argv, _errors} = OptionParser.parse(argv, switches: @switches)

    version = Mix.Project.config()[:version]

    header("PhoenixKit Release Check (v#{version})")

    results = [
      run_check("CHANGELOG Heading", fn -> check_changelog_heading(version) end),
      run_check("CHANGELOG Body", fn -> check_changelog_body(version) end),
      run_check("Migration Version Sync", fn -> check_migration_sync() end),
      run_check("Git Tree Clean", fn -> check_git_clean(opts) end),
      run_check("Git Branch", fn -> check_git_branch(opts) end),
      run_check("Tag Collision", fn -> check_tag_collision(version) end)
    ]

    IO.puts("")
    summary(results)
  end

  # ── Check implementations (return {:pass | :warn | :fail, detail}) ──

  defp check_changelog_heading(version) do
    case top_changelog_version() do
      {:ok, ^version} ->
        {:pass, "Top CHANGELOG entry is #{version}"}

      {:ok, other} ->
        {:fail,
         "mix.exs is #{version} but top CHANGELOG entry is #{other}. " <>
           "Add a `## #{version} - <date>` section before publishing."}

      :unreleased ->
        {:fail, "Top CHANGELOG entry is still \"Unreleased\" — stamp it with #{version}."}

      :error ->
        {:fail, "Could not find a `## X.Y.Z` heading in CHANGELOG.md"}
    end
  end

  defp check_changelog_body(version) do
    case changelog_body(version) do
      {:ok, body} ->
        if String.trim(body) == "" do
          {:fail, "The #{version} CHANGELOG section has no content."}
        else
          lines = body |> String.split("\n") |> Enum.count(&(String.trim(&1) != ""))
          {:pass, "#{lines} non-blank line(s)"}
        end

      :error ->
        {:fail, "No CHANGELOG section found for #{version}."}
    end
  end

  defp check_migration_sync do
    module = PhoenixKit.Migrations.Postgres

    if Code.ensure_loaded?(module) and function_exported?(module, :current_version, 0) do
      code_version = module.current_version()

      case highest_migration_file() do
        {:ok, file_version} when file_version == code_version ->
          {:pass, "current_version/0 == v#{file_version}.ex"}

        {:ok, file_version} ->
          {:fail,
           "Migrations.Postgres.current_version/0 is #{code_version} but the highest " <>
             "migration file is v#{file_version}.ex — register the new version (or " <>
             "remove the stray file)."}

        :error ->
          {:fail, "No vNNN.ex migration files found."}
      end
    else
      {:warn, "PhoenixKit.Migrations.Postgres.current_version/0 not available — skipped."}
    end
  end

  defp check_git_clean(opts) do
    case git(["status", "--porcelain"]) do
      {:ok, ""} ->
        {:pass, "No uncommitted changes"}

      {:ok, out} ->
        count = out |> String.split("\n", trim: true) |> length()
        detail = "#{count} uncommitted change(s). Commit or stash before publishing."
        if opts[:allow_dirty], do: {:warn, detail}, else: {:fail, detail}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  defp check_git_branch(opts) do
    case git(["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, "main"} ->
        {:pass, "On main"}

      {:ok, branch} ->
        detail = "On #{branch}, not main. Releases are cut from main."
        if opts[:allow_branch], do: {:warn, detail}, else: {:fail, detail}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  defp check_tag_collision(version) do
    tag = "v#{version}"

    case git(["tag", "-l", tag]) do
      {:ok, ""} ->
        {:pass, "#{tag} does not exist yet"}

      {:ok, _} ->
        {:fail, "Tag #{tag} already exists — this version looks already released."}

      :error ->
        {:warn, "git unavailable — skipped."}
    end
  end

  # ── CHANGELOG parsing ──────────────────────────────────────────────

  # Matches "## 1.7.138 - 2026-06-09", "## [1.7.138]", "## v1.7.138", etc.
  @heading_re ~r/^##\s+\[?v?(?<ver>\d+\.\d+\.\d+)/

  defp top_changelog_version do
    case File.read(changelog_path()) do
      {:ok, contents} ->
        heading = first_heading(contents) || ""

        cond do
          Regex.match?(~r/^##\s+\[?unreleased/im, heading) ->
            :unreleased

          match = Regex.named_captures(@heading_re, heading) ->
            {:ok, match["ver"]}

          true ->
            :error
        end

      _ ->
        :error
    end
  end

  # The first line starting with "## " — the latest entry.
  defp first_heading(contents) do
    contents
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "## "))
  end

  defp changelog_body(version) do
    case File.read(changelog_path()) do
      {:ok, contents} ->
        lines = String.split(contents, "\n")
        target = ~r/^##\s+\[?v?#{Regex.escape(version)}\b/

        case Enum.find_index(lines, &Regex.match?(target, &1)) do
          nil ->
            :error

          idx ->
            body =
              lines
              |> Enum.drop(idx + 1)
              |> Enum.take_while(&(not String.starts_with?(&1, "## ")))
              |> Enum.join("\n")

            {:ok, body}
        end

      _ ->
        :error
    end
  end

  defp changelog_path, do: Path.join(File.cwd!(), "CHANGELOG.md")

  # ── Migration file discovery ───────────────────────────────────────

  defp highest_migration_file do
    "lib/phoenix_kit/migrations/postgres/v*.ex"
    |> Path.wildcard()
    |> Enum.map(&extract_migration_number/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> :error
      nums -> {:ok, Enum.max(nums)}
    end
  end

  defp extract_migration_number(path) do
    case Regex.run(~r/v(\d+)\.ex$/, Path.basename(path)) do
      [_, num] -> String.to_integer(num)
      _ -> nil
    end
  end

  # ── Git ────────────────────────────────────────────────────────────

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # ── Output (mirrors mix phoenix_kit.doctor) ────────────────────────

  defp header(title) do
    IO.puts("\n#{IO.ANSI.bright()}#{IO.ANSI.cyan()}#{title}#{IO.ANSI.reset()}")
    IO.puts(String.duplicate("─", 60))
  end

  defp run_check(name, fun) do
    result =
      try do
        fun.()
      rescue
        e -> {:fail, "Exception: #{Exception.message(e)}"}
      end

    display_check(name, result)
    {name, result}
  end

  defp display_check(name, {:pass, detail}) do
    IO.puts("  #{IO.ANSI.green()}PASS#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.faint()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:warn, detail}) do
    IO.puts("  #{IO.ANSI.yellow()}WARN#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.yellow()}#{detail}#{IO.ANSI.reset()}")
  end

  defp display_check(name, {:fail, detail}) do
    IO.puts("  #{IO.ANSI.red()}FAIL#{IO.ANSI.reset()} #{name}")
    if detail, do: IO.puts("       #{IO.ANSI.red()}#{detail}#{IO.ANSI.reset()}")
  end

  defp summary(results) do
    pass = Enum.count(results, fn {_, {status, _}} -> status == :pass end)
    warn = Enum.count(results, fn {_, {status, _}} -> status == :warn end)
    fail = Enum.count(results, fn {_, {status, _}} -> status == :fail end)
    total = length(results)

    IO.puts(
      "#{IO.ANSI.bright()}Summary#{IO.ANSI.reset()}: #{pass}/#{total} passed, #{warn} warnings, #{fail} failures"
    )

    if fail > 0 do
      IO.puts(
        "#{IO.ANSI.red()}Release blocked — fix the FAIL items above before publishing.#{IO.ANSI.reset()}"
      )

      exit({:shutdown, 1})
    end
  end
end
