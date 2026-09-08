defmodule PhoenixKit.Integrations.ResourceLinks do
  @moduledoc """
  Resolves `"integration"` resources to their edit page for deep-linking.

  An activity logged against an integration (`resource_type: "integration"`,
  `resource_uuid:` the storage row's uuid) resolves to the connection's edit
  page (`/admin/settings/integrations/:uuid`), titled `provider / name`.

  Registered as the `"integration"` handler by `PhoenixKit.ResourceLinks`
  (gated on this module being loaded). Mirrors
  `PhoenixKit.Users.CommentResources` — implements the same
  `resolve_comment_resources/1` contract and returns a **raw** phoenix_kit path
  (`Routes.path/1` is applied once at render).
  """

  alias PhoenixKit.Integrations

  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(resource_uuids) when is_list(resource_uuids) do
    resource_uuids
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn uuid, acc ->
      case info_for(uuid) do
        nil -> acc
        info -> Map.put(acc, uuid, info)
      end
    end)
  rescue
    _ -> %{}
  end

  # Raw path — the caller applies Routes.path/1 (prefix + locale) at render.
  # The title lookup is best-effort: a transient settings error falls back to a
  # generic label rather than dropping the (still-valid) deep-link.
  defp info_for(uuid) when is_binary(uuid) and uuid != "" do
    %{title: title_for(uuid), path: "/admin/settings/integrations/#{uuid}"}
  end

  defp info_for(_), do: nil

  defp title_for(uuid) do
    case Integrations.get_integration_by_uuid(uuid) do
      {:ok, %{provider: provider, name: name}} -> connection_title(provider, name)
      _ -> "Integration"
    end
  rescue
    _ -> "Integration"
  end

  defp connection_title(provider, name) do
    case {to_string(provider), to_string(name)} do
      {"", ""} -> "Integration"
      {p, ""} -> p
      {"", n} -> n
      {p, n} -> "#{p} / #{n}"
    end
  end
end
