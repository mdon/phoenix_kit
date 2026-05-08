defmodule PhoenixKit.KnownPackages do
  @moduledoc """
  Live catalog of known external PhoenixKit packages fetched from Hex.pm.

  Results are cached in-process for 10 minutes via `:persistent_term`.
  On Hex fetch failure, returns stale cached data when available, otherwise
  returns `extra_known_packages` config entries only.
  """

  require Logger

  @cache_key {__MODULE__, :cache}
  @hex_search_url "https://hex.pm/api/packages"
  @icon_marker_re ~r/\bhex_docs_icon_name:\s*([a-z0-9-]+)/
  @default_icon "hero-puzzle-piece"
  @skip_packages ["phoenix_kit"]
  @ttl_ms :timer.minutes(10)

  @doc """
  Returns the list of known external PhoenixKit packages.

  Fetches from Hex.pm on cache miss (up to every 10 minutes).
  Always merges `config :phoenix_kit, extra_known_packages: [...]` on top.

  Each entry is a map with keys: `key`, `package`, `name`, `description`,
  `icon`, `hex_url`, `source`.
  """
  @spec list() :: [map()]
  def list do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {expires_at, cached} when expires_at > now ->
        cached

      _ ->
        fetch_and_cache()
    end
  end

  @doc "Clears the in-process cache. Intended for tests."
  @spec clear_cache() :: :ok
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_and_cache do
    case fetch_from_hex() do
      {:ok, hex_list} ->
        merged = merge_extras(hex_list)
        expires_at = System.monotonic_time(:millisecond) + @ttl_ms
        :persistent_term.put(@cache_key, {expires_at, merged})
        merged

      {:error, reason} ->
        Logger.warning(
          "PhoenixKit.KnownPackages: Hex fetch failed (#{inspect(reason)}) — " <>
            "returning config extras only"
        )

        case :persistent_term.get(@cache_key, nil) do
          {_expired_at, stale} -> stale
          nil -> merge_extras([])
        end
    end
  end

  defp fetch_from_hex do
    url = @hex_search_url <> "?search=phoenix_kit_&sort=name"
    fetch_hex_page(url, [])
  end

  defp fetch_hex_page(nil, acc), do: {:ok, acc}

  defp fetch_hex_page(url, acc) do
    opts = Application.get_env(:phoenix_kit, :_known_packages_req_opts, receive_timeout: 3000)

    case Req.get(url, opts) do
      {:ok, %{status: 200, body: packages, headers: headers}} when is_list(packages) ->
        valid = packages |> Enum.reject(&skip_package?/1) |> Enum.map(&shape_entry/1)
        next_url = parse_next_link(headers)
        fetch_hex_page(next_url, acc ++ valid)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp skip_package?(%{"name" => name}), do: name in @skip_packages
  defp skip_package?(_), do: false

  defp shape_entry(pkg) do
    package = pkg["name"]
    key = String.replace_prefix(package, "phoenix_kit_", "")
    raw_description = get_in(pkg, ["meta", "description"]) || ""
    {stripped_description, icon} = parse_marker(raw_description)

    %{
      key: key,
      package: package,
      name: humanize_key(key),
      description: stripped_description,
      icon: icon,
      hex_url: "https://hex.pm/packages/#{package}",
      source: "hex"
    }
  end

  defp humanize_key(key) do
    key |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp parse_marker(description) do
    case Regex.run(@icon_marker_re, description) do
      [full_match, icon_name] ->
        stripped = description |> String.replace(full_match, "") |> String.trim()
        {stripped, icon_name}

      nil ->
        {String.trim(description), @default_icon}
    end
  end

  defp parse_next_link(headers) when is_map(headers) do
    link = headers |> Map.get("link", []) |> List.first()

    with binary when is_binary(binary) <- link,
         [_, url] <- Regex.run(~r/<([^>]+)>;\s*rel="next"/, binary) do
      url
    else
      _ -> nil
    end
  end

  defp merge_extras(hex_list) do
    extras =
      Application.get_env(:phoenix_kit, :extra_known_packages, [])
      |> Enum.map(&Map.put(&1, :source, "config"))

    # Config wins: concat config first, then hex; uniq_by keeps first (config)
    (extras ++ hex_list)
    |> Enum.uniq_by(& &1.package)
  end
end
