defmodule Mix.Tasks.Compile.PhoenixKitJsSources do
  @moduledoc """
  Mix compiler that bundles external-module JavaScript hooks for the host app.

  A LiveView JS hook must be present in the host's single `LiveSocket` at
  construction time — a nested LiveView cannot register one at runtime. Modules
  declare their prebuilt hook bundles via `js_sources/0` (see `PhoenixKit.Module`);
  this compiler discovers them and writes one aggregate file the host loads with a
  single `<script>` tag (added once by `mix phoenix_kit.install`).

  ## What it does (every compile)

  1. Discovers external modules via `PhoenixKit.ModuleDiscovery`, collects their
     `js_sources/0` entries.
  2. Resolves each bundle's absolute path via `:code.priv_dir/1` — so it works for
     Hex installs and path deps alike, with no `deps/<app>` path arithmetic.
  3. Concatenates the bundles (each wrapped in an IIFE so their top-level scopes
     can't collide) into `priv/static/assets/vendor/phoenix_kit_modules.js`,
     followed by a merge that folds each bundle's `window.<Global>` into
     `window.PhoenixKitHooks` (which the host already spreads into `LiveSocket`).
  4. Writes only when the content changed (diff-before-write) to avoid live-reload
     thrash.

  The output tag is **stable**: adding or removing a JS-bearing module only changes
  this file's content on the next compile — never the host's layout — so it stays
  zero-config like `css_sources/0`.

  ## Setup (one-time, by `mix phoenix_kit.install`)

      # mix.exs
      compilers: [:phoenix_kit_js_sources, :phoenix_live_view] ++ Mix.compilers()

      # root.html.heex, before app.js
      <script src={~p"/assets/vendor/phoenix_kit_modules.js"}></script>

  Failures are loud: a declared bundle that can't be resolved raises a compile
  error rather than silently shipping a chart with "unknown hook" console errors.
  """

  use Mix.Task.Compiler

  require Logger

  @output "priv/static/assets/vendor/phoenix_kit_modules.js"

  @impl true
  def run(_args) do
    # Ensure all dep applications are loaded so module discovery + priv_dir work.
    for dep <- Mix.Dep.cached() do
      Application.ensure_loaded(dep.app)
    end

    specs = collect_specs()
    content = build_content(specs)

    path = Path.join(File.cwd!(), @output)
    write_if_changed(path, content, length(specs))

    {:ok, []}
  end

  # ── Discovery ────────────────────────────────────────────────────

  # Returns a deterministic list of %{app, file, global, source} maps.
  defp collect_specs do
    PhoenixKit.ModuleDiscovery.discover_external_modules()
    |> Enum.flat_map(fn mod ->
      if Code.ensure_loaded?(mod) and function_exported?(mod, :js_sources, 0) do
        mod.js_sources()
      else
        []
      end
    end)
    |> Enum.map(&normalize_entry/1)
    # Deterministic order; dedupe identical (app, file) declarations.
    |> Enum.uniq_by(fn s -> {s.app, s.file} end)
    |> Enum.sort_by(fn s -> {to_string(s.app), s.file} end)
    |> tap(&check_unique_globals/1)
    |> Enum.map(&resolve_source/1)
  end

  # Two distinct bundles assigning the same window.<Global> would clobber each
  # other (last bundle wins; the merge dedupes the global), silently dropping the
  # earlier module's hooks. Fail loud instead.
  @doc false
  def check_unique_globals(specs) do
    dupes =
      specs
      |> Enum.group_by(& &1.global)
      |> Enum.filter(fn {_global, entries} -> length(entries) > 1 end)

    unless dupes == [] do
      detail =
        Enum.map_join(dupes, "\n", fn {global, entries} ->
          apps = Enum.map_join(entries, ", ", fn e -> "#{e.app}:#{e.file}" end)
          "  window.#{global} <- #{apps}"
        end)

      Mix.raise("""
      Multiple js_sources/0 bundles declare the same window global, so the later
      bundle would clobber the earlier one's hooks:

      #{detail}

      Each module's bundle must assign a unique window.<Global>. Rename one.
      """)
    end

    :ok
  end

  @doc false
  def normalize_entry(%{app: app, file: file, global: global})
      when is_atom(app) and is_binary(file) and is_binary(global) do
    # `global` is emitted as `window.<global>` in the generated JS, so an
    # invalid identifier (e.g. "foo-bar") would produce broken JS — fail loud.
    unless Regex.match?(~r/^[A-Za-z_$][A-Za-z0-9_$]*$/, global) do
      Mix.raise("""
      Invalid js_sources/0 :global #{inspect(global)} — must be a valid JavaScript
      identifier (it is emitted as window.<global> and folded into PhoenixKitHooks).
      """)
    end

    %{app: app, file: file, global: global}
  end

  def normalize_entry(other) do
    Mix.raise("""
    Invalid js_sources/0 entry: #{inspect(other)}

    Each entry must be a map with :app (atom), :file (string, relative to the
    app's priv/), and :global (string, the window.<Name> the bundle assigns).
    """)
  end

  # Resolve the bundle's absolute path via the app's priv dir. Fail loud.
  defp resolve_source(%{app: app, file: file} = spec) do
    priv =
      case :code.priv_dir(app) do
        {:error, :bad_name} ->
          Mix.raise("""
          js_sources/0 references app #{inspect(app)}, but it isn't an available
          application. Add it as a dependency of the module declaring it.
          """)

        dir ->
          to_string(dir)
      end

    source = Path.join(priv, file)

    unless File.exists?(source) do
      Mix.raise("""
      js_sources/0 bundle not found: #{source}

      App #{inspect(app)} declared js_sources file #{inspect(file)} (resolved under
      its priv/), but no such file exists. The bundle must ship in the app's priv/.
      """)
    end

    Map.put(spec, :source, source)
  end

  # ── Content ──────────────────────────────────────────────────────

  @doc false
  def build_content([]) do
    """
    /* Auto-generated by PhoenixKit — do not edit manually.
       No external module declares js_sources/0; this file is intentionally empty. */
    """
  end

  def build_content(specs) do
    bundles =
      Enum.map_join(specs, "\n", fn %{app: app, source: source} ->
        body = File.read!(source)

        # Wrap each prebuilt bundle in an IIFE so its top-level declarations
        # can't collide with another bundle's. Bundles export via window.<Global>,
        # which survives the wrapper. Leading `;` guards against ASI hazards.
        """
        /* #{app} */
        ;(function(){
        #{body}
        })();
        """
      end)

    globals =
      specs
      |> Enum.map(& &1.global)
      |> Enum.uniq()
      |> Enum.map_join(",", fn g -> "window.#{g}||{}" end)

    # NOTE: `check_unique_globals/1` guarantees distinct window.<Global> names,
    # but this Object.assign is still last-write-wins on the HOOK NAMES inside
    # each bundle — and it folds over the core window.PhoenixKitHooks too. Two
    # modules exporting a same-named hook (or one shadowing a core hook) clobber
    # silently; we can't detect that without parsing the bundles. js_sources/0's
    # docs tell modules to namespace their hook names accordingly.
    """
    /* Auto-generated by PhoenixKit — do not edit manually.
       Concatenated module hook bundles (js_sources/0), loaded before app.js. */
    #{bundles}
    /* Fold each module's hooks into window.PhoenixKitHooks (spread into LiveSocket by app.js). */
    window.PhoenixKitHooks=Object.assign(window.PhoenixKitHooks||{},#{globals});
    """
  end

  defp write_if_changed(path, content, spec_count) do
    existing =
      case File.read(path) do
        {:ok, data} -> data
        _ -> nil
      end

    if existing != content do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)

      Mix.shell().info("[PhoenixKit] Updated #{@output} with #{spec_count} module hook bundle(s)")
    end
  end
end
