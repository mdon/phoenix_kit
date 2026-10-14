defmodule PhoenixKit.API.Registry do
  @moduledoc """
  The tools the API can serve right now.

  A tool is callable when its module is enabled, it is not hidden by the
  `api_disabled_tools` setting, and it passed `PhoenixKit.API.Tool.validate/1`. The list is
  the enabled modules' `c:PhoenixKit.Module.api_tools/0` (through
  `PhoenixKit.ModuleRegistry.all_api_tools/0`) plus core's own
  `PhoenixKit.API.CoreTools.tools/0`.

  Nothing here is cached: modules can be enabled and disabled at runtime, and a settings
  change must take effect on the next request. A caller that serves a request should ask
  once and keep the answer.

  ## Cost

  A call asks every enabled module for its tools (`api_tools/0`) and validates each of them
  again. Measured with 60 tools in one module: about 1.1 ms for `all_tools/0` or a `find/2`
  hit, about 2 ms for a `find/2` miss, which also asks the switched-off modules. A caller
  that an anonymous client can reach (the public endpoint) must count the request against a
  rate bucket **before** it looks a tool up, so repeated unknown names are not free CPU.
  """

  alias PhoenixKit.API.Config
  alias PhoenixKit.API.Tool
  alias PhoenixKit.ModuleRegistry

  @doc """
  Every callable tool: the enabled modules' tools (tagged with `:module`) followed by
  core's, minus the names in `api_disabled_tools` (newline separated). A module cannot
  declare a `system.*` tool (`PhoenixKit.ModuleRegistry.all_api_tools/0` drops it), so it
  cannot shadow one of core's. When the list cannot be read at all, nothing is callable.
  """
  @spec all_tools() :: [Tool.t()]
  def all_tools do
    case Config.fetch_disabled_tools() do
      :unreadable -> []
      {:ok, names} -> callable_tools(MapSet.new(names))
    end
  end

  @doc """
  Finds the callable tool `name` of `audience`.

  Answers `{:error, :module_disabled}` when a registered module that is switched off
  declares a tool of that name, and `{:error, :not_found}` for every other miss: an unknown
  name, a tool of the other audience, a tool hidden by `api_disabled_tools` (even when its
  module is also off), and every name when the hidden list cannot be read.
  """
  @spec find(String.t(), Tool.audience()) ::
          {:ok, Tool.t()} | {:error, :not_found | :module_disabled}
  def find(name, audience) when is_binary(name) do
    case Config.fetch_disabled_tools() do
      :unreadable -> {:error, :not_found}
      {:ok, names} -> find_callable(name, audience, MapSet.new(names))
    end
  end

  def find(_name, _audience), do: {:error, :not_found}

  @doc """
  The tools of `audience` a caller may see.

    * `:all` - every callable tool of the audience (public listings, the admin UI).
    * `:none` - nothing. So is anything that is not a list of scopes (an anonymous actor
      has no scopes).
    * a list of scopes - the tools whose `:scope` is in the list, plus the tools that have
      no scope (core's `system.*` tools and public tools), which every caller may use.
  """
  @spec visible_tools(Tool.audience(), [String.t()] | :all | :none) :: [Tool.t()]
  def visible_tools(audience, scopes) do
    tools = Enum.filter(all_tools(), &(&1.audience == audience))

    case scopes do
      :all -> tools
      :none -> []
      scopes when is_list(scopes) -> Enum.filter(tools, &(is_nil(&1.scope) or &1.scope in scopes))
      _other -> []
    end
  end

  defp callable_tools(hidden) do
    ModuleRegistry.all_api_tools()
    |> Enum.reject(&MapSet.member?(hidden, &1.name))
  end

  defp find_callable(name, audience, hidden) do
    case Enum.find(callable_tools(hidden), &(&1.name == name and &1.audience == audience)) do
      %Tool{} = tool -> {:ok, tool}
      nil -> {:error, miss_reason(name, audience, hidden)}
    end
  end

  defp miss_reason(name, audience, hidden) do
    cond do
      MapSet.member?(hidden, name) -> :not_found
      ModuleRegistry.disabled_api_tool?(name, audience) -> :module_disabled
      true -> :not_found
    end
  end
end
