defmodule PhoenixKitWeb.Components.Core.CrawlerMetas do
  @moduledoc """
  Head metas owned by the Crawlers module: the global `noindex, nofollow`
  directive and search-engine verification tags.

  Self-contained on purpose — it reads the settings itself (ETS-cached), so it
  works in ANY root layout with zero assigns, exactly like
  `phoenix_kit_favicon`. That matters because most installs render the head in
  the HOST app's root layout, where core's assigns don't reach: an assign-based
  meta in core's own layout files renders only on installs using core's shells.
  Embed in a host root layout's `<head>`:

      <PhoenixKitWeb.Components.Core.CrawlerMetas.crawler_metas />

  Renders nothing while the Crawlers module is disabled, and never raises —
  with no database (installer context) it degrades to empty.
  """

  use Phoenix.Component

  alias PhoenixKit.Modules.Crawlers

  @doc """
  Robots directive and verification meta tags, from current Crawlers settings.
  """
  def crawler_metas(assigns) do
    {no_index, verifications} = read_state()

    assigns =
      assigns
      |> assign(:no_index, no_index)
      |> assign(:verifications, verifications)

    ~H"""
    <%= if @no_index do %>
      <meta name="robots" content="noindex,nofollow" />
      <meta name="googlebot" content="noindex,nofollow" />
    <% end %>
    <meta :for={{name, content} <- @verifications} name={name} content={content} />
    """
  end

  defp read_state do
    if Crawlers.module_enabled?() do
      {Crawlers.no_index_enabled?(), Crawlers.verification_metas()}
    else
      {false, []}
    end
  rescue
    _ -> {false, []}
  catch
    :exit, _ -> {false, []}
  end
end
