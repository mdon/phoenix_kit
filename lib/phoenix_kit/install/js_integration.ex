defmodule PhoenixKit.Install.JsIntegration do
  @moduledoc """
  Handles automatic JavaScript hooks integration for PhoenixKit installation.

  This module:
  - Copies `phoenix_kit.js` to the parent app's `priv/static/assets/vendor/`
  - Adds a `<script>` tag to the root layout so hooks are loaded before LiveSocket

  The JS file defines `window.PhoenixKitHooks` which is spread into LiveSocket's
  hooks object in app.js: `hooks: { ...window.PhoenixKitHooks, ...colocatedHooks }`

  ## External module hooks

  External modules declare prebuilt hook bundles via `js_sources/0`. The
  `:phoenix_kit_js_sources` compiler concatenates those into
  `priv/static/assets/vendor/phoenix_kit_modules.js` on every compile and folds
  their hooks into `window.PhoenixKitHooks`. This module:

  - registers that compiler in the parent app's `mix.exs`,
  - adds a single (stable) `<script>` tag for the aggregate file after
    `phoenix_kit.js` and before `app.js`,
  - seeds an empty aggregate file so the tag doesn't 404 before the first compile.

  The tag never changes as modules come and go — only the file's content does — so
  module JS stays zero-config, exactly like `css_sources/0`.
  """

  require Logger

  @source_filename "phoenix_kit.js"
  @script_marker "<!-- PhoenixKit JS Hooks -->"

  @modules_filename "phoenix_kit_modules.js"
  @modules_script_marker "<!-- PhoenixKit Module Hooks -->"

  @doc """
  Copies phoenix_kit.js to the parent app's static vendor directory and
  adds a script tag to the root layout.

  Safe to run multiple times (idempotent).
  """
  def add_js_integration(igniter) do
    igniter
    |> copy_js_file()
    |> add_script_tag_to_layout()
    |> add_hooks_to_app_js()
    |> ensure_module_js_integration()
  end

  @doc """
  Ensures the external-module JS integration is wired: the
  `:phoenix_kit_js_sources` compiler is in `mix.exs`, an aggregate file is seeded,
  and the root layout has the (stable) module-hooks `<script>` tag.

  Idempotent. Called at install and at `mix phoenix_kit.update`, so hosts that
  installed before this feature pick it up on their next update.
  """
  def ensure_module_js_integration(igniter) do
    igniter
    |> add_js_sources_compiler()
    |> seed_modules_js_file()
    |> add_modules_script_tag_to_layout()
    |> add_viewport_param_to_app_js()
  end

  @doc """
  Updates the JS file in the parent app's static vendor directory.
  Called during `mix phoenix_kit.update` to keep hooks in sync.
  """
  def update_js_file do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p(Path.dirname(dest))

        case File.cp(source, dest) do
          :ok ->
            Logger.info("Updated #{@source_filename} in priv/static/assets/vendor/")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to update #{@source_filename}: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.warning("Could not find #{@source_filename} in PhoenixKit priv/static/assets/")
        {:error, :not_found}
    end
  rescue
    error ->
      Logger.warning("Unexpected error updating #{@source_filename}: #{inspect(error)}")
      {:error, :unexpected}
  end

  # ── Private ──────────────────────────────────────────────────────

  defp copy_js_file(igniter) do
    case resolve_source_path() do
      {:ok, source} ->
        dest = dest_path()
        File.mkdir_p(Path.dirname(dest))

        case File.cp(source, dest) do
          :ok ->
            Igniter.add_notice(
              igniter,
              "✅ Copied #{@source_filename} to priv/static/assets/vendor/"
            )

          {:error, reason} ->
            Igniter.add_warning(
              igniter,
              "⚠️  Failed to copy #{@source_filename}: #{inspect(reason)}. " <>
                "Please copy it manually from deps/phoenix_kit/priv/static/assets/#{@source_filename}"
            )
        end

      {:error, :not_found} ->
        Igniter.add_warning(
          igniter,
          "⚠️  Could not find #{@source_filename}. " <>
            "Please copy it manually from the phoenix_kit package."
        )
    end
  end

  defp add_script_tag_to_layout(igniter) do
    layout_paths = [
      "lib/#{Mix.Phoenix.otp_app()}_web/components/layouts/root.html.heex",
      "lib/#{Mix.Phoenix.otp_app()}_web/templates/layout/root.html.heex"
    ]

    case find_existing_file(layout_paths) do
      {:ok, layout_path} ->
        content = File.read!(layout_path)

        cond do
          String.contains?(content, @script_marker) ->
            # Already integrated
            igniter

          String.contains?(content, "phoenix_kit.js") ->
            # Already has a script tag (manually added)
            igniter

          true ->
            inject_script_tag(igniter, layout_path, content)
        end

      {:error, :not_found} ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not find root layout. Please add this before your app.js script tag:

              #{@script_marker}
              <script src="/assets/vendor/#{@source_filename}"></script>
          """
        )
    end
  end

  defp inject_script_tag(igniter, layout_path, content) do
    script_tag = """
        #{@script_marker}
        <script src={~p"/assets/vendor/#{@source_filename}"}></script>\
    """

    # Insert before the app.js script tag
    updated =
      String.replace(
        content,
        ~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)},
        "\n#{script_tag}\n\\1",
        global: false
      )

    if updated != content do
      File.write!(layout_path, updated)

      Igniter.add_notice(
        igniter,
        "✅ Added PhoenixKit JS hooks script tag to #{layout_path}"
      )
    else
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not automatically add script tag to #{layout_path}.
        Please add this before your app.js script tag:

            #{@script_marker}
            <script src={~p"/assets/vendor/#{@source_filename}"}></script>
        """
      )
    end
  end

  defp add_hooks_to_app_js(igniter) do
    app_js_path = Path.join([File.cwd!(), "assets", "js", "app.js"])

    if File.exists?(app_js_path) do
      content = File.read!(app_js_path)

      cond do
        # Match the actual spread, not any mention — a comment that merely names
        # PhoenixKitHooks must not skip the real injection. \s* handles the
        # multiline `hooks: {\n  ...window.PhoenixKitHooks,` shape.
        Regex.match?(~r/\.\.\.\s*window\.PhoenixKitHooks\b/, content) ->
          # Already has the PhoenixKitHooks spread
          igniter

        Regex.match?(~r/hooks:\s*\{/, content) ->
          # Has a hooks object — inject PhoenixKitHooks spread at the start
          updated =
            Regex.replace(
              ~r/hooks:\s*\{/,
              content,
              "hooks: {...window.PhoenixKitHooks, ",
              global: false
            )

          if updated != content do
            File.write!(app_js_path, updated)

            Igniter.add_notice(
              igniter,
              "✅ Added PhoenixKitHooks spread to LiveSocket hooks in assets/js/app.js"
            )
          else
            add_hooks_manual_notice(igniter)
          end

        Regex.match?(~r/new LiveSocket\(/, content) ->
          # Has LiveSocket but no hooks — add hooks option
          updated =
            Regex.replace(
              ~r/(new LiveSocket\([^,]+,\s*Socket,\s*\{)/,
              content,
              "\\1\n  hooks: {...window.PhoenixKitHooks},",
              global: false
            )

          if updated != content do
            File.write!(app_js_path, updated)

            Igniter.add_notice(
              igniter,
              "✅ Added PhoenixKitHooks to LiveSocket configuration in assets/js/app.js"
            )
          else
            add_hooks_manual_notice(igniter)
          end

        true ->
          add_hooks_manual_notice(igniter)
      end
    else
      add_hooks_manual_notice(igniter)
    end
  end

  # Add `viewport_width` to the LiveSocket connect params (as a closure, so
  # reconnects re-read the width). PhoenixKit LiveViews with responsive layouts
  # (e.g. the dashboards builder) use it to pick the right tier server-side on
  # the FIRST render instead of detecting it with a hook round-trip behind a
  # loading state. They all degrade gracefully without it.
  defp add_viewport_param_to_app_js(igniter) do
    app_js_path = Path.join([File.cwd!(), "assets", "js", "app.js"])

    if File.exists?(app_js_path) do
      content = File.read!(app_js_path)

      case inject_viewport_param(content) do
        :already ->
          igniter

        {:ok, updated} ->
          File.write!(app_js_path, updated)

          Igniter.add_notice(
            igniter,
            "✅ Added viewport_width to the LiveSocket connect params in assets/js/app.js"
          )

        :manual ->
          viewport_manual_notice(igniter)
      end
    else
      viewport_manual_notice(igniter)
    end
  end

  # A params object further than this from `new LiveSocket(` is assumed to
  # belong to something else (another socket, a config literal) — manual notice.
  @viewport_params_window 500

  @doc false
  # Pure transform (public for tests): rewrite the common phx.new shape
  # `params: {_csrf_token: csrfToken}` into a closure carrying viewport_width.
  # Deliberately conservative — regex surgery on arbitrary host code must not
  # corrupt it, so anything fancier gets a manual notice instead:
  #   * only the params object INSIDE the `new LiveSocket(` options is touched
  #     (an earlier `new Socket("/socket", {params: …})` must not be rewritten
  #     while the real LiveSocket params stay bare),
  #   * objects containing comments are refused (appending after a trailing
  #     `// …` would swallow the new code into the comment),
  #   * already a closure / nested braces → no simple-object match → refused.
  def inject_viewport_param(content) do
    # The KEY form specifically — a prose mention in a comment ("add
    # viewport_width someday") must not make the installer skip the patch.
    if Regex.match?(~r/viewport_width\s*:/, content),
      do: :already,
      else: rewrite_livesocket_params(content)
  end

  defp rewrite_livesocket_params(content) do
    with {:ok, anchor_end} <- livesocket_anchor(content),
         rest = binary_part(content, anchor_end, byte_size(content) - anchor_end),
         {:ok, {start, len}, inner} <- top_level_params(rest) do
      trimmed = inner |> String.trim() |> String.trim_trailing(",")
      prefix = if trimmed == "", do: "", else: trimmed <> ", "

      rewritten =
        binary_part(rest, 0, start) <>
          "params: () => ({#{prefix}viewport_width: window.innerWidth})" <>
          binary_part(rest, start + len, byte_size(rest) - start - len)

      {:ok, binary_part(content, 0, anchor_end) <> rewritten}
    else
      _ -> :manual
    end
  end

  # The first `new LiveSocket(` that isn't on a commented line — a documentation
  # example (`// Example: new LiveSocket(...)`) must not anchor the patch away
  # from the real call below it.
  defp livesocket_anchor(content) do
    :binary.matches(content, "new LiveSocket(")
    |> Enum.find_value(:manual, fn {pos, len} ->
      if commented_at?(content, pos), do: nil, else: {:ok, pos + len}
    end)
  end

  defp commented_at?(content, pos) do
    before = binary_part(content, 0, pos)
    line_prefix = before |> String.split("\n") |> List.last()

    String.contains?(line_prefix, "//") or String.contains?(line_prefix, "/*") or
      line_prefix |> String.trim_leading() |> String.starts_with?("*") or
      inside_block_comment?(before)
  end

  # An unclosed /* before the position means we're inside a multi-line block
  # comment (whose lines need no leading *) — e.g. a commented-out example call
  # would otherwise anchor the patch away from the real call below it.
  defp inside_block_comment?(before) do
    length(:binary.matches(before, "/*")) > length(:binary.matches(before, "*/"))
  end

  # The first simple `params: {…}` at the TOP level of the LiveSocket options
  # object (brace depth exactly 1 relative to the call's `(`): a nested
  # `params:` inside a hook body (`this.pushEvent("load", {params: {page: 1}})`)
  # must never be rewritten. Comment-bearing objects are refused (appending
  # after a trailing `// …` would swallow the new code into the comment), as is
  # anything farther than the window (assumed to belong to something else).
  defp top_level_params(rest) do
    ~r/params:\s*\{([^{}]*)\}/
    |> Regex.scan(rest, return: :index)
    |> Enum.find_value(:manual, fn [{start, len}, {inner_start, inner_len}] ->
      inner = binary_part(rest, inner_start, inner_len)

      cond do
        start > @viewport_params_window -> :manual
        brace_depth(binary_part(rest, 0, start)) != 1 -> nil
        String.contains?(inner, "//") or String.contains?(inner, "/*") -> :manual
        true -> {:ok, {start, len}, inner}
      end
    end)
    |> case do
      {:ok, _, _} = ok -> ok
      _ -> :manual
    end
  end

  # Brace depth of the segment with string literals and comments blanked out
  # first — a `"}}}"` inside a hook option must not fake depth 1 at a nested
  # site (that produced a WRONG rewrite in review; imperfect blanking merely
  # skews depth away from 1, which fails closed to :manual).
  defp brace_depth(segment) do
    for <<char <- blank_strings_and_comments(segment)>>, reduce: 0 do
      depth ->
        case char do
          ?{ -> depth + 1
          ?} -> depth - 1
          _ -> depth
        end
    end
  end

  defp blank_strings_and_comments(segment) do
    segment
    |> String.replace(~r/\\./, "")
    |> String.replace(~r/"[^"]*"/, "\"\"")
    |> String.replace(~r/'[^']*'/, "''")
    |> String.replace(~r/`[^`]*`/s, "``")
    |> String.replace(~r{/\*.*?\*/}s, "")
    |> String.replace(~r{//[^\n]*}, "")
  end

  defp viewport_manual_notice(igniter) do
    Igniter.add_notice(
      igniter,
      """
      ℹ️  Optional: pass the viewport in your LiveSocket connect params so
      PhoenixKit's responsive LiveViews (e.g. dashboards) load straight into
      the right layout tier:

          const liveSocket = new LiveSocket("/live", Socket, {
            params: () => ({_csrf_token: csrfToken, viewport_width: window.innerWidth}),
            ...
          })
      """
    )
  end

  defp add_hooks_manual_notice(igniter) do
    Igniter.add_warning(
      igniter,
      """
      ⚠️  Could not automatically add PhoenixKitHooks to app.js.
      Please add ...window.PhoenixKitHooks to your LiveSocket hooks:

          const liveSocket = new LiveSocket("/live", Socket, {
            hooks: {...window.PhoenixKitHooks, ...yourOtherHooks},
          })
      """
    )
  end

  # Register the :phoenix_kit_js_sources compiler in the parent app's mix.exs.
  # It regenerates priv/static/assets/vendor/phoenix_kit_modules.js on each
  # compile from external modules' js_sources/0.
  defp add_js_sources_compiler(igniter) do
    Igniter.Project.MixProject.update(igniter, :project, [:compilers], fn
      nil ->
        # No :compilers key yet — must keep the defaults, so prepend to
        # Mix.compilers() rather than replacing the whole list.
        {:ok, {:code, quote(do: [:phoenix_kit_js_sources] ++ Mix.compilers())}}

      zipper ->
        case Igniter.Code.List.prepend_new_to_list(zipper, :phoenix_kit_js_sources) do
          {:ok, zipper} -> {:ok, zipper}
          :error -> {:warning, "Could not add :phoenix_kit_js_sources to compilers in mix.exs"}
        end
    end)
  rescue
    _ ->
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not add :phoenix_kit_js_sources compiler to mix.exs.
        Please add it manually:

            def project do
              [
                ...,
                compilers: [:phoenix_kit_js_sources] ++ Mix.compilers()
              ]
            end
        """
      )
  end

  # Seed an empty aggregate file so the <script> tag doesn't 404 before the
  # compiler first runs. The compiler overwrites it with real content. A seed
  # failure is surfaced as a warning (not swallowed) — the first `mix compile`
  # recreates the file, so it's recoverable, but the installer should say so.
  defp seed_modules_js_file(igniter) do
    dest = Path.join([File.cwd!(), "priv", "static", "assets", "vendor", @modules_filename])

    if File.exists?(dest) do
      igniter
    else
      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <-
             File.write(
               dest,
               "/* Auto-generated by PhoenixKit — populated on first compile. */\n"
             ) do
        igniter
      else
        {:error, reason} ->
          Igniter.add_warning(
            igniter,
            "⚠️  Could not seed #{@modules_filename} (#{inspect(reason)}). " <>
              "It will be created on the next `mix compile`."
          )
      end
    end
  end

  # Add the (stable) aggregate-module-hooks <script> tag to the root layout,
  # after phoenix_kit.js (so it augments window.PhoenixKitHooks) and before app.js.
  defp add_modules_script_tag_to_layout(igniter) do
    layout_paths = [
      "lib/#{Mix.Phoenix.otp_app()}_web/components/layouts/root.html.heex",
      "lib/#{Mix.Phoenix.otp_app()}_web/templates/layout/root.html.heex"
    ]

    case find_existing_file(layout_paths) do
      {:ok, layout_path} ->
        content = File.read!(layout_path)

        if String.contains?(content, @modules_filename) do
          igniter
        else
          inject_modules_script_tag(igniter, layout_path, content)
        end

      {:error, :not_found} ->
        Igniter.add_notice(
          igniter,
          """
          ⚠️  Could not find root layout. Please add this after the phoenix_kit.js
          script tag and before your app.js script tag:

              #{@modules_script_marker}
              <script src={~p"/assets/vendor/#{@modules_filename}"}></script>
          """
        )
    end
  end

  defp inject_modules_script_tag(igniter, layout_path, content) do
    tag = """
        #{@modules_script_marker}
        <script src={~p"/assets/vendor/#{@modules_filename}"}></script>\
    """

    # Prefer to anchor right after the phoenix_kit.js tag so ordering is explicit.
    # Escape the filename — its "." is a regex metachar, and a future vendor file
    # could otherwise false-match.
    pk = Regex.escape(@source_filename)

    updated =
      cond do
        Regex.match?(~r{<script[^>]*#{pk}[^>]*>\s*</script>}, content) ->
          Regex.replace(
            ~r{(<script[^>]*#{pk}[^>]*>\s*</script>)},
            content,
            "\\1\n#{tag}",
            global: false
          )

        Regex.match?(~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)}, content) ->
          Regex.replace(
            ~r{(\s*<script[^>]*src=[^>]*app\.js[^>]*>)},
            content,
            "\n#{tag}\n\\1",
            global: false
          )

        true ->
          content
      end

    if updated != content do
      File.write!(layout_path, updated)
      Igniter.add_notice(igniter, "✅ Added module-hooks script tag to #{layout_path}")
    else
      Igniter.add_warning(
        igniter,
        """
        ⚠️  Could not automatically add the module-hooks script tag to #{layout_path}.
        Please add this after phoenix_kit.js and before app.js:

            #{@modules_script_marker}
            <script src={~p"/assets/vendor/#{@modules_filename}"}></script>
        """
      )
    end
  end

  defp resolve_source_path do
    # Try multiple possible locations
    candidates = [
      # Path dependency (development)
      Path.join([File.cwd!(), "..", "phoenix_kit", "priv", "static", "assets", @source_filename]),
      # Hex dependency
      Path.join([:code.priv_dir(:phoenix_kit), "static", "assets", @source_filename])
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp dest_path do
    Path.join([File.cwd!(), "priv", "static", "assets", "vendor", @source_filename])
  end

  defp find_existing_file(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end
end
