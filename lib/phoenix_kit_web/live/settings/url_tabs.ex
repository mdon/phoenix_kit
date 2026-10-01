defmodule PhoenixKitWeb.Live.Settings.UrlTabs do
  @moduledoc """
  Keeps the active tab of a settings page in the URL (`?tab=sessions`).

  A tab held only in the socket is lost on refresh, can't be linked to and isn't
  restored by the browser's Back button. The settings pages render every pane in
  one LiveView (and often one form) and hide the inactive ones, so the tabs
  *patch*: the LiveView stays mounted, nothing is reloaded, unsaved edits in a
  hidden pane survive, and only the URL changes.

  A page keeps one list of tab maps (`%{id:, label:, icon:}`, the shape
  `PhoenixKitWeb.Components.Core.NavTabs` takes) and uses it twice:

      def handle_params(params, _url, socket) do
        {:noreply, assign(socket, :active_tab, UrlTabs.active(params, tabs()))}
      end

      # template
      <.nav_tabs
        active_tab={@active_tab}
        tabs={UrlTabs.patch_links(tabs(), "/admin/settings/users")}
        variant={:border}
      />

  The first tab is the default and its URL carries no query. An unknown `?tab=`
  opens the default rather than rendering nothing.
  """

  alias PhoenixKit.Utils.Routes

  @doc "The id of the tab `params[\"tab\"]` names, or the first tab's."
  @spec active(map(), [map()]) :: String.t()
  def active(%{"tab" => tab}, tabs) when is_binary(tab) do
    if Enum.any?(tabs, &(&1.id == tab)), do: tab, else: default(tabs)
  end

  def active(_params, tabs), do: default(tabs)

  @doc """
  `tabs` with a `:patch` link added to each, under `base_path` (the canonical
  `/admin/...` path — `Routes.path/1` prefixes and localizes it).
  """
  @spec patch_links([map()], String.t()) :: [map()]
  def patch_links(tabs, base_path) do
    default = default(tabs)
    Enum.map(tabs, fn %{id: id} = tab -> Map.put(tab, :patch, path(base_path, id, default)) end)
  end

  defp path(base_path, id, default) when id == default, do: Routes.path(base_path)

  defp path(base_path, id, _default),
    do: Routes.path(base_path <> "?tab=" <> URI.encode_www_form(id))

  defp default([%{id: id} | _]), do: id
end
