defmodule PhoenixKit.ResourceLinks do
  @moduledoc """
  Resolves `(resource_type, resource_uuid)` pairs into navigable deep-links to
  the underlying resource — the record an action happened on or a comment is
  attached to.

  Two-tier resolution, tried in order per `resource_type`:

  1. **Handler modules** — a module registered for the type that exports
     `resolve_comment_resources/1`, returning `%{uuid => %{title, path, thumb_url?}}`
     with a **raw** phoenix_kit path (`Routes.path/1` is applied once at render
     time — pre-applying it would double-prefix under a non-root `url_prefix`).
     Auto-registered when the module is loaded: `"post" => PhoenixKitPosts`,
     `"file" => PhoenixKit.Annotations`, `"user" => PhoenixKit.Users.CommentResources`.
     Hosts add more via `config :phoenix_kit, :comment_resource_handlers`.

  2. **String path templates** — the `comment_resource_paths` setting, a no-code
     JSON map (`%{"shoes" => "/order/shoes/:uuid"}`) with `:uuid` / `:prefix` /
     `:metadata.<key>` placeholders.

  Shared by the Comments moderation admin (`PhoenixKitComments` delegates here)
  and the Activity feed. The handler contract and setting name keep the
  historical `comment_*` naming, but the mechanism is resource-generic — a
  resource that deep-links in comments deep-links in Activity with no extra
  config.

  ## Items

  `resolve/1` accepts any list of maps/structs exposing `:resource_type`,
  `:resource_uuid`, and (optionally) `:metadata` — both `PhoenixKit.Activity.Entry`
  and comment structs qualify. Items missing a type or uuid are skipped.

  Returns a map keyed by `{resource_type, resource_uuid}`, each value a map:

      %{title: String.t(), full_title: String.t(), path: String.t(),
        prefixed: boolean(), thumb_url: String.t() (optional)}

  `prefixed: true` means `path` is a raw phoenix_kit route — pass it through
  `url/1` (→ `Routes.path/1`) and SPA-navigate. `prefixed: false` comes from a
  host template and should render as a plain `href`.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @metadata_max_display_length 15

  @doc """
  Resolves resource context (title + path) for a list of items.

  See the module doc for the item and return shapes.
  """
  def resolve(items) do
    items
    |> Enum.filter(&(present?(field(&1, :resource_type)) and present?(field(&1, :resource_uuid))))
    |> Enum.group_by(&field(&1, :resource_type))
    |> Enum.reduce(%{}, fn {resource_type, type_items}, acc ->
      resolved = resolve_for_type(resource_type, type_items)

      Enum.reduce(resolved, acc, fn {id, info}, inner ->
        Map.put(inner, {resource_type, id}, info)
      end)
    end)
  end

  @doc """
  Looks up a resolved info map for a single `(resource_type, resource_uuid)` pair.

  Returns `nil` when the pair was not resolvable.
  """
  def info_for(context, resource_type, resource_uuid) when is_map(context) do
    Map.get(context, {resource_type, resource_uuid})
  end

  @doc """
  Final navigable path for a resolved info map.

  Applies `Routes.path/1` (URL prefix + locale) to raw phoenix_kit paths
  (`prefixed: true`); returns host-template paths (`prefixed: false`) verbatim.
  """
  def url(%{path: path} = info) do
    if info[:prefixed], do: Routes.path(path), else: path
  end

  @doc """
  Gets configured resource path templates (path + optional display title).

  Returns a map of `resource_type => config`, where config is either a plain
  string (legacy path-only format) or a map with `"path"` and optional `"title"`
  keys.

      %{"shoes" => "/order/shoes/:uuid"}
      %{"shoes" => %{"path" => "/order/shoes/:uuid", "title" => ":metadata.name"}}
  """
  def get_resource_path_templates do
    Settings.get_json_setting("comment_resource_paths", %{})
  rescue
    e ->
      Logger.warning("Failed to load resource path templates: #{inspect(e)}")
      %{}
  end

  @doc """
  Updates resource path templates for resource types.

  Accepts both legacy string values and new map values with `"path"` and
  `"title"` keys.
  """
  def update_resource_path_templates(templates) when is_map(templates) do
    Settings.update_json_setting("comment_resource_paths", templates)
  end

  @doc """
  The registered `resource_type => handler_module` map.

  Merges, in increasing precedence: the auto-registered core defaults (loaded
  post/file/user/integration modules), the module-declared handlers (the
  `resource_links/0` `PhoenixKit.Module` callback entries whose value is a
  resolver module), and the host's `config :phoenix_kit, :comment_resource_handlers`
  overrides. Exposed so other consumers (e.g. the comments notification-callback
  dispatch) resolve a resource type against the same registry the deep-links use.
  """
  def handlers do
    configured = Application.get_env(:phoenix_kit, :comment_resource_handlers, %{})

    module_handlers =
      module_resolvers()
      |> Enum.filter(fn {_type, resolver} -> is_atom(resolver) end)
      |> Map.new()

    default_resource_handlers()
    |> Map.merge(module_handlers)
    |> Map.merge(configured)
  end

  # ── Resolution ──────────────────────────────────────────────────────

  defp default_resource_handlers do
    handlers = %{}

    handlers =
      if Code.ensure_loaded?(PhoenixKitPosts),
        do: Map.put(handlers, "post", PhoenixKitPosts),
        else: handlers

    # File resources (incl. Etcher annotation discussions) resolve to the file's
    # media page via phoenix_kit core's Annotations context.
    handlers =
      if Code.ensure_loaded?(PhoenixKit.Annotations),
        do: Map.put(handlers, "file", PhoenixKit.Annotations),
        else: handlers

    # Integration resources resolve to the integration's edit page in Settings.
    handlers =
      if Code.ensure_loaded?(PhoenixKit.Integrations.ResourceLinks),
        do: Map.put(handlers, "integration", PhoenixKit.Integrations.ResourceLinks),
        else: handlers

    # User resources resolve to the user's admin detail page (with avatar) via
    # phoenix_kit core's Users context.
    if Code.ensure_loaded?(PhoenixKit.Users.CommentResources),
      do: Map.put(handlers, "user", PhoenixKit.Users.CommentResources),
      else: handlers
  end

  # Resolver entries declared by discovered modules via the `resource_links/0`
  # `PhoenixKit.Module` callback: `%{resource_type => module | template_string
  # | %{"path" => ..., "title" => ...}}`. Module values become handlers; string/
  # map values become internal path templates (see `module_templates/0`).
  defp module_resolvers do
    if Code.ensure_loaded?(PhoenixKit.ModuleRegistry) do
      PhoenixKit.ModuleRegistry.all_modules()
      |> Enum.reduce(%{}, fn mod, acc ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :resource_links, 0) do
          Map.merge(acc, safe_module_resource_links(mod))
        else
          acc
        end
      end)
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp safe_module_resource_links(mod) do
    case mod.resource_links() do
      map when is_map(map) -> map
      _ -> %{}
    end
  rescue
    e ->
      Logger.warning("[ResourceLinks] #{inspect(mod)}.resource_links/0 failed: #{inspect(e)}")
      %{}
  end

  # The non-module (string / map) entries from `resource_links/0` — no-code
  # internal path templates, resolved as SPA-navigated phoenix_kit routes.
  defp module_templates do
    module_resolvers()
    |> Enum.reject(fn {_type, resolver} -> is_atom(resolver) end)
    |> Map.new()
  end

  # Precedence per resource_type: a resolver module (rich, prefixed navigate) →
  # a module-declared internal template (prefixed navigate) → a host
  # `comment_resource_paths` setting template (external href).
  defp resolve_for_type(resource_type, items) do
    resource_uuids = items |> Enum.map(&field(&1, :resource_uuid)) |> Enum.uniq()
    handler = resolve_via_handler(resource_type, resource_uuids)

    cond do
      map_size(handler) > 0 ->
        Map.new(handler, fn {id, info} -> {id, Map.put(info, :prefixed, true)} end)

      map_size(mod_tpl = resolve_via_module_template(resource_type, items)) > 0 ->
        mod_tpl

      true ->
        resolve_via_setting_template(resource_type, items)
    end
  rescue
    e ->
      Logger.warning("Resource link resolver error: #{inspect(e)}")
      %{}
  end

  defp resolve_via_handler(resource_type, resource_uuids) do
    case Map.get(handlers(), resource_type) do
      nil ->
        %{}

      mod ->
        if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve_comment_resources, 1) do
          mod.resolve_comment_resources(resource_uuids)
        else
          %{}
        end
    end
  end

  # Module-declared templates are internal phoenix_kit routes → prefixed
  # (Routes.path applied at render, SPA-navigated).
  defp resolve_via_module_template(resource_type, items) do
    case Map.get(module_templates(), resource_type) do
      nil -> %{}
      config -> resolve_via_template(resource_type, items, config, true)
    end
  end

  # Host `comment_resource_paths` templates are for controller/external pages →
  # not prefixed (rendered as a plain href, `:prefix` substituted into the path).
  defp resolve_via_setting_template(resource_type, items) do
    case Map.get(get_resource_path_templates(), resource_type) do
      nil -> %{}
      config -> resolve_via_template(resource_type, items, config, false)
    end
  end

  defp resolve_via_template(resource_type, items, config, prefixed) do
    path_template = path_from_config(config)
    title_template = title_from_config(config)

    Map.new(items, fn item ->
      metadata = field(item, :metadata) || %{}
      uuid = field(item, :resource_uuid)
      path = apply_path_template(path_template, uuid, metadata, prefixed)
      title = resolve_title(title_template, resource_type, uuid, metadata)
      full_title = resolve_full_title(title_template, resource_type, uuid, metadata)

      {uuid, %{title: title, full_title: full_title, path: path, prefixed: prefixed}}
    end)
  end

  defp resolve_title(nil, resource_type, uuid, _metadata) do
    short_id = uuid |> to_string() |> String.slice(0..7)
    "#{resource_type} #{short_id}..."
  end

  defp resolve_title(title_template, _resource_type, uuid, metadata) do
    apply_title_template(title_template, uuid, metadata)
  end

  defp resolve_full_title(nil, resource_type, uuid, _metadata) do
    "#{resource_type} #{uuid}"
  end

  defp resolve_full_title(title_template, _resource_type, uuid, metadata) do
    title_template
    |> replace_metadata_placeholders(metadata)
    |> String.replace(":uuid", to_string(uuid))
  end

  defp path_from_config(config) when is_binary(config), do: config
  defp path_from_config(%{"path" => path}), do: path
  defp path_from_config(_), do: ""

  defp title_from_config(config) when is_binary(config), do: nil
  defp title_from_config(%{"title" => ""}), do: nil
  defp title_from_config(%{"title" => title}), do: title
  defp title_from_config(_), do: nil

  # `prefixed?` = true for internal phoenix_kit routes: leave `:prefix` alone
  # (Routes.path/1 prepends the url_prefix at render). false for external/host
  # templates: substitute `:prefix` with the configured prefix here.
  defp apply_path_template(template, resource_uuid, metadata, prefixed?) do
    template
    |> replace_metadata_url_placeholders(metadata)
    |> then(fn t -> if prefixed?, do: t, else: String.replace(t, ":prefix", prefix_value()) end)
    |> String.replace(":uuid", url_encode(to_string(resource_uuid)))
  end

  defp apply_title_template(template, resource_uuid, metadata) do
    template
    |> replace_metadata_truncated(metadata)
    |> String.replace(":uuid", truncate_value(to_string(resource_uuid)))
  end

  defp prefix_value do
    prefix = Routes.url_prefix()
    if prefix == "/", do: "", else: prefix
  end

  defp replace_metadata_placeholders(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string()
    end)
  end

  defp replace_metadata_url_placeholders(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string() |> url_encode()
    end)
  end

  defp replace_metadata_truncated(template, metadata) do
    Regex.replace(~r/:metadata\.(\w+)/, template, fn _match, key ->
      metadata |> Map.get(key, "") |> to_string() |> truncate_value()
    end)
  end

  defp url_encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp truncate_value(value) do
    if String.length(value) <= @metadata_max_display_length do
      value
    else
      String.slice(value, 0, @metadata_max_display_length) <> "..."
    end
  end

  # Struct/map field access that tolerates either atom-keyed structs (Activity
  # entries, comments) without assuming a specific type.
  defp field(item, key), do: Map.get(item, key)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
