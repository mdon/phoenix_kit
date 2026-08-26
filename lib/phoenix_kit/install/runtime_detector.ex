defmodule PhoenixKit.Install.RuntimeDetector do
  @moduledoc """
  Detects Phoenix runtime configuration patterns and determines appropriate config strategy.

  This module analyzes Phoenix project configuration files to determine:
  - Whether the project uses runtime.exs patterns
  - The appropriate configuration file to modify
  - The correct insertion location for PhoenixKit configuration

  A stock Phoenix 1.7+ app has **both** a simple `config/dev.exs` and a
  `config/runtime.exs` that calls `System.get_env`. The Local mailer adapter
  belongs in `dev.exs` on that layout. Preferring `runtime.exs` just because
  it exists is how 2.13.6 wrote `config :phoenix_kit, PhoenixKit.Mailer`
  above `import Config` and crashed the next boot with
  `undefined function config/3`.
  """

  alias PhoenixKit.Install.ConfigVerify

  @doc """
  Detects if the project uses runtime configuration patterns.

  Prefers a simple `config/dev.exs` even when `config/runtime.exs` exists
  (every `mix phx.new` tree). `runtime.exs` is only chosen when there is
  no simple `dev.exs` to write to.

  ## Returns

  - `:dev_exs` - Simple `config/dev.exs` (stock Phoenix)
  - `:runtime` - Uses runtime.exs with no simple `dev.exs` (e.g. Dotenvy)
  - `:config_exs` - Fall back to `config/config.exs`

  ## Examples

      iex> RuntimeDetector.detect_config_pattern()
      :dev_exs
  """
  def detect_config_pattern do
    detect_config_pattern(
      optional_file("config/runtime.exs"),
      optional_file("config/dev.exs")
    )
  end

  @doc """
  Same as `detect_config_pattern/0` but takes file contents so it can be
  tested without the process cwd. Pass `nil` for a missing file.
  """
  @spec detect_config_pattern(String.t() | nil, String.t() | nil) ::
          :runtime | :dev_exs | :config_exs
  def detect_config_pattern(runtime_content, dev_content) do
    cond do
      is_binary(dev_content) and simple_dev_content?(dev_content) ->
        :dev_exs

      is_binary(runtime_content) and runtime_patterns?(runtime_content) ->
        :runtime

      true ->
        :config_exs
    end
  end

  @doc """
  Checks if runtime.exs file exists in the project.

  ## Returns

  `true` if runtime.exs exists, `false` otherwise.
  """
  def runtime_exists? do
    File.exists?("config/runtime.exs")
  end

  @doc """
  Checks if runtime.exs contains runtime configuration patterns.

  ## Returns

  `true` if runtime patterns are detected, `false` otherwise.
  """
  def has_runtime_patterns? do
    case File.read("config/runtime.exs") do
      {:ok, content} ->
        runtime_patterns?(content)

      {:error, _} ->
        false
    end
  end

  @doc """
  Checks if dev.exs file exists and is simple enough to modify.

  ## Returns

  `true` if simple dev.exs exists, `false` otherwise.
  """
  def simple_dev_config? do
    case File.read("config/dev.exs") do
      {:ok, content} ->
        simple_dev_content?(content)

      {:error, _} ->
        false
    end
  end

  @doc """
  Checks if dev.exs file exists.

  ## Returns

  `true` if dev.exs exists, `false` otherwise.
  """
  def dev_exs_exists? do
    File.exists?("config/dev.exs")
  end

  @doc """
  Finds the appropriate insertion point for PhoenixKit configuration.

  ## Returns

  - `{:runtime, line_number}` - Insert at specific line in runtime.exs
  - `{:dev_exs, line_number}` - Insert at end of dev.exs
  - `{:config_exs, line_number}` - Insert in config.exs with env check

  ## Examples

      iex> RuntimeDetector.find_insertion_point()
      {:dev_exs, 40}
  """
  def find_insertion_point do
    case detect_config_pattern() do
      :runtime ->
        line_num = find_runtime_insertion_point()
        {:runtime, line_num}

      :dev_exs ->
        {:dev_exs, find_end_of_file("config/dev.exs")}

      :config_exs ->
        {:config_exs, find_end_of_file("config/config.exs")}
    end
  end

  @doc """
  Finds the appropriate location within runtime.exs for development configuration.

  ## Returns

  `line_number` (1-based) where PhoenixKit config should be inserted —
  always strictly after `import Config` when that line is present.
  """
  def find_runtime_insertion_point do
    case File.read("config/runtime.exs") do
      {:ok, content} ->
        find_runtime_insertion_point_in(content)

      {:error, _} ->
        1
    end
  end

  @doc """
  Same as `find_runtime_insertion_point/0` for a content string.

  The returned 1-based line number is the line to insert AT (existing
  content at that line is pushed down). `import Config` on line 1
  therefore returns `2`, not `1` — inserting at line 1 is the 2.13.6
  CompileError (`undefined function config/3`).
  """
  @spec find_runtime_insertion_point_in(String.t()) :: pos_integer()
  def find_runtime_insertion_point_in(content) when is_binary(content) do
    lines = String.split(content, "\n")

    case find_dev_block_end(lines) do
      {:ok, line_num} ->
        max(line_num, find_insertion_after_imports(lines))

      {:error, :no_dev_block} ->
        find_insertion_after_imports(lines)
    end
  end

  @doc """
  Inserts `snippet` into a config file immediately after `import Config`.

  If `import Config` is missing, it is added at the top. Never places a
  `config/3` call above `import Config` — that is a CompileError.

  `snippet` is trimmed; a blank line is kept on either side.
  """
  @spec insert_after_import_config(String.t(), String.t()) :: String.t()
  def insert_after_import_config(content, snippet)
      when is_binary(content) and is_binary(snippet) do
    snippet_lines = snippet |> String.trim() |> String.split("\n")
    lines = String.split(content, "\n")

    case import_config_index(lines) do
      nil ->
        Enum.join(
          ["import Config", ""] ++ snippet_lines ++ [""] ++ drop_leading_blanks(lines),
          "\n"
        )

      index ->
        {before, after_lines} = Enum.split(lines, index + 1)

        Enum.join(
          before ++ [""] ++ snippet_lines ++ [""] ++ drop_leading_blanks(after_lines),
          "\n"
        )
    end
  end

  @doc """
  Moves any `config` calls that appear before `import Config` to just
  after it.

  A stock Phoenix `runtime.exs` starts with `import Config`; writing
  above that line is a CompileError (`undefined function config/3`).
  Comments and blank lines above the import are left alone. If
  `import Config` is missing and the file already has `config` calls,
  the import is prepended.

  Idempotent.
  """
  @spec ensure_import_config_first(String.t()) :: String.t()
  def ensure_import_config_first(content) when is_binary(content) do
    lines = String.split(content, "\n")

    case import_config_index(lines) do
      nil ->
        if has_config_call?(lines) do
          Enum.join(["import Config", ""] ++ lines, "\n")
        else
          content
        end

      index ->
        {before, rest} = Enum.split(lines, index)

        if has_config_call?(before) do
          [import_line | after_import] = rest
          Enum.join([import_line, ""] ++ before ++ after_import, "\n")
        else
          content
        end
    end
  end

  @wrapped_dev_mailer """
  # PhoenixKit mailer configuration
  if config_env() == :dev do
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
  end
  """

  # 2.13.6 wrote this unguarded (and indented) at the top of runtime.exs.
  # Left unwrapped after the import-order repair, it would override a
  # production mailer configured in prod.exs — runtime.exs runs last.
  @unguarded_216_mailer ~r/^[ \t]*# PhoenixKit mailer configuration\n[ \t]*config :phoenix_kit, PhoenixKit\.Mailer,\n[ \t]*adapter: Swoosh\.Adapters\.Local/m

  @doc """
  Wraps the unguarded 2.13.6 Local-adapter snippet in
  `if config_env() == :dev`. No-op when already wrapped or absent.

  Idempotent.
  """
  @spec wrap_unguarded_local_mailer(String.t()) :: String.t()
  def wrap_unguarded_local_mailer(content) when is_binary(content) do
    already_wrapped? =
      Regex.match?(
        ~r/if config_env\(\) == :dev do\s+config :phoenix_kit, PhoenixKit\.Mailer/s,
        content
      )

    if already_wrapped? do
      content
    else
      candidate = Regex.replace(@unguarded_216_mailer, content, String.trim(@wrapped_dev_mailer))

      # I103: this function is a pure String -> String transform with no
      # Igniter/Mix.shell context to print a notice through, so a rollback
      # here is silent by necessity — same "no-op" contract this function
      # already documents for the already-wrapped/absent cases, just
      # extended to a would-be-corrupting match too. `@unguarded_216_mailer`
      # anchors on an exact, specific multi-line snippet rather than a
      # variable-length block, so this is lower risk than the Oban splices;
      # verified anyway, for the same reason as every other site in I103 —
      # a regex match on raw text is still blind to what it lands inside.
      case ConfigVerify.verify_or_rollback(content, candidate, &mailer_wrapped_in_dev_guard?/1) do
        {:ok, result} -> result
        {:rolled_back, original, _reason} -> original
      end
    end
  end

  # Private functions

  # True if `ast` has `if config_env() == :dev do ... end` wrapping a real
  # `config :phoenix_kit, PhoenixKit.Mailer, ...` call — confirms the wrap
  # landed on the actual mailer config, not on a comment or string that
  # happened to match the same anchored text.
  defp mailer_wrapped_in_dev_guard?(ast) do
    ConfigVerify.ast_contains?(ast, fn
      {:if, _, [{:==, _, [{:config_env, _, []}, :dev]}, [do: body]]} ->
        mailer_config_call?(body)

      _ ->
        false
    end)
  end

  defp mailer_config_call?(
         {:config, _, [:phoenix_kit, {:__aliases__, _, [:PhoenixKit, :Mailer]}, _opts]}
       ),
       do: true

  defp mailer_config_call?(_), do: false

  defp optional_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp simple_dev_content?(content) do
    not (runtime_patterns?(content) or has_complex_conditionals?(content))
  end

  defp runtime_patterns?(content) do
    patterns = [
      ~r/config_env\(\)/,
      ~r/System\.get_env/,
      ~r/Dotenvy\.env!/,
      ~r/\.env\.\s*Atom\.to_string/,
      ~r/if.*config_env.*==/
    ]

    Enum.any?(patterns, &Regex.match?(&1, content))
  end

  defp has_complex_conditionals?(content) do
    patterns = [
      # Multi-line if blocks
      ~r/if.*do.*end/s,
      # Case statements
      ~r/case.*do.*end/s,
      # Cond statements
      ~r/cond.*do/s
    ]

    Enum.any?(patterns, &Regex.match?(&1, content))
  end

  defp find_dev_block_end(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _index} ->
      String.contains?(line, "config :swoosh, :api_client, false") &&
        String.contains?(line, "end")
    end)
    |> case do
      {_line, index} ->
        # Find the actual "end" of the dev block
        remaining_lines = Enum.drop(lines, index + 1)

        case find_next_config_block(remaining_lines) do
          {:ok, next_line_num} ->
            {:ok, index + 1 + next_line_num - 1}

          :not_found ->
            {:ok, index + 1}
        end

      nil ->
        {:error, :no_dev_block}
    end
  end

  defp find_next_config_block(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find(fn {line, _index} ->
      String.starts_with?(String.trim(line), "config ") ||
        String.starts_with?(String.trim(line), "if config_env")
    end)
    |> case do
      {_, index} -> {:ok, index}
      nil -> :not_found
    end
  end

  # 1-based line AFTER `import Config` so `Enum.split(lines, n - 1)` keeps
  # the import in `before`. `import Config` on line 1 → `2`, never `1`.
  defp find_insertion_after_imports(lines) do
    case import_config_index(lines) do
      nil -> 1
      index -> index + 2
    end
  end

  defp import_config_index(lines) do
    Enum.find_index(lines, fn line ->
      String.starts_with?(String.trim(line), "import Config")
    end)
  end

  defp drop_leading_blanks(lines) do
    Enum.drop_while(lines, &(String.trim(&1) == ""))
  end

  defp has_config_call?(lines) do
    Enum.any?(lines, fn line ->
      String.starts_with?(String.trim(line), "config ")
    end)
  end

  defp find_end_of_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        String.split(content, "\n") |> length()

      {:error, _} ->
        1
    end
  end
end
