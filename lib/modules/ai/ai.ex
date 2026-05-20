defmodule PhoenixKit.Modules.AI do
  @moduledoc """
  Core-side conveniences for talking to the optional `PhoenixKitAI`
  plugin. The plugin is shipped as a separate Hex package and may or
  may not be installed in a given host application; everything in this
  namespace is safe to call regardless.

  Each function here uses `Code.ensure_loaded?/1` to detect the
  plugin at runtime and returns `{:error, :ai_not_installed}` (or
  a documented fallback) when the plugin is absent. That lets feature
  modules in core (and sibling plugins) reference AI workflows
  unconditionally without depending on `:phoenix_kit_ai` at compile
  time.

  See `PhoenixKit.Modules.AI.Translation` for the higher-level
  translation orchestration (prompt rendering, structured-response
  parsing, error normalization).
  """

  @doc """
  Returns true when the `PhoenixKitAI` plugin is loaded and exports the
  `ask_with_prompt/4` entry point this namespace relies on.

  **Note on the semantics:** this is a *module-loadability* check —
  it does NOT verify that the host has a configured endpoint, a valid
  prompt template, or working credentials. Use it to decide whether to
  surface AI-driven UI at all; the actual request is the only place
  that can confirm runtime readiness.

      <.language_switcher_dropdown
        ai_translate={
          if PhoenixKit.Modules.AI.available?(),
            do: %{enabled: true, event: "translate_lang", ...},
            else: nil
        }
        ...
      />

  Hosts that need a stricter "endpoint configured and reachable" check
  should call into `PhoenixKitAI` directly (e.g. validating that
  `PhoenixKitAI.list_endpoints/0` returns at least one connected row)
  before showing the affordance.

  Cheap — a single atom lookup against the code server. No DB hit.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitAI) and function_exported?(PhoenixKitAI, :ask_with_prompt, 4)
  end
end
