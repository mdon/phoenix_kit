defmodule PhoenixKit.Modules.Storage.Manager do
  @moduledoc """
  Storage manager for handling file operations with redundancy and failover.

  This module coordinates file storage across multiple buckets with automatic
  redundancy, failover, and variant generation.

  ## Where an object is read from (V204)

  Reads, existence checks, public URLs and serving go to the buckets the
  object's location rows name first (`PhoenixKit.Modules.Storage.Locations`),
  in the usual order: local buckets, then by priority. Only when none of
  them has it are the other enabled buckets tried, and a bucket found to
  hold it that way is recorded as a location. Deletes still remove an
  unreferenced key from every enabled bucket.

  ## Where an object is written (V205)

  By the storage profile of the file's library (`store_file/2`): its
  buckets, their roles and write priorities, and its copy counts.
  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Locations
  alias PhoenixKit.Modules.Storage.ProfileBucket
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Modules.Storage.ProviderRegistry
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Cache TTL for bucket list (5 minutes)
  @buckets_cache_ttl 300_000

  @doc """
  Stores a file across buckets.

  ## Where it goes (V205)

  By a storage profile: `:profile` (a `StorageProfile` with its buckets
  preloaded, `Storage.Profiles.for_library/1`), or the Default profile
  when none is given. `:kind` says what the object is: `:original` (an
  original upload, the default) or `:derived` (a size, a tile, a render),
  which picks the profile's copy count and the buckets whose `stores`
  allows it. Buckets that are enabled, `active` in the profile and not over
  their `max_size_mb` are written, primaries before replicas before
  backups, each group by fixed write priority and then in random order,
  up to the copy count.

  An original fails unless at least the profile's `min_copies_on_write`
  copies were written (what was written is removed again). The result
  says whether every copy the profile wants was made (`complete?`); the
  rest are made by the reconciler.

  ## Options

  - `:path_prefix` - the object key
  - `:profile` / `:kind` - see above
  - `:force_bucket_ids` - exactly these buckets (every one that is enabled,
    in the order given), whatever any profile says
  - `:redundancy_copies` / `:priority_buckets` - the pre-profile selection
    (the enabled buckets by priority, up to the count), kept for callers
    that ask for it

  ## Returns

  - `{:ok, file_result}` - `destination_path`, `bucket_ids` (the buckets
    written), `stored_in`, `successful_storages`, `complete?`
  - `{:error, reason}` - Failed to store file
  """
  def store_file(source_path, opts \\ []) do
    force_bucket_ids = Keyword.get(opts, :force_bucket_ids, [])

    # `force_bucket_ids` are exactly the buckets to write to (an edit's
    # output goes where the key it replaces is): every one that is enabled,
    # in the order given.
    {buckets, min_copies, target} =
      cond do
        force_bucket_ids != [] ->
          forced = forced_buckets(force_bucket_ids)
          {forced, 1, length(forced)}

        legacy_selection?(opts) ->
          redundancy = Keyword.get(opts, :redundancy_copies, 1)

          selected =
            select_buckets_for_storage(redundancy, Keyword.get(opts, :priority_buckets, []))

          {selected, 1, length(selected)}

        profile = Keyword.get(opts, :profile) || Profiles.default_profile() ->
          profile_placement(profile, Keyword.get(opts, :kind, :original))

        # No profiles on this database yet: the pre-V205 pool.
        true ->
          selected = select_buckets_for_storage(1, [])
          {selected, 1, length(selected)}
      end

    if Enum.empty?(buckets) do
      {:error, "No available storage buckets"}
    else
      with {:ok, info} <- store_across_buckets(source_path, buckets, opts) do
        require_copies(info, min_copies, target)
      end
    end
  rescue
    error -> {:error, "Error storing file: #{inspect(error)}"}
  end

  defp legacy_selection?(opts),
    do:
      Keyword.has_key?(opts, :redundancy_copies) or Keyword.get(opts, :priority_buckets, []) != []

  # The buckets `profile` writes an object of `kind` to, how many copies
  # must succeed, and how many it wants (capped at the buckets it can use).
  defp profile_placement(profile, kind) do
    eligible = placement_candidates(profile, kind)
    copies = Profiles.copies(profile, kind)
    min_copies = if kind == :original, do: profile.min_copies_on_write, else: 1

    {Enum.take(eligible, copies), min_copies, min(copies, length(eligible))}
  end

  @doc false
  # The buckets `profile` may write an object of `kind` to, in write order:
  # enabled, active in the profile, storing that kind, not over capacity;
  # by role, then fixed write priority, then the shuffled pool.
  def placement_candidates(profile, kind) do
    stores = if kind == :original, do: "originals", else: "derived"

    profile.buckets
    |> Enum.filter(fn row ->
      row.status == "active" and row.stores in ["all", stores] and
        match?(%{enabled: true}, row.bucket) and not bucket_full?(row.bucket)
    end)
    |> Enum.group_by(& &1.role)
    |> then(fn by_role ->
      Enum.flat_map(ProfileBucket.roles(), fn role ->
        {fixed, pool} = by_role |> Map.get(role, []) |> Enum.split_with(& &1.write_priority)
        Enum.sort_by(fixed, & &1.write_priority) ++ Enum.shuffle(pool)
      end)
    end)
    |> Enum.map(& &1.bucket)
  end

  # Fewer copies than an original needs undo the write; fewer than wanted
  # are reported, for the reconciler.
  defp require_copies(info, min_copies, target) do
    written = info.successful_storages

    if written < min_copies do
      Enum.each(info.bucket_ids, fn bucket_uuid ->
        with %{} = bucket <- Storage.get_bucket(bucket_uuid) do
          safe_delete(bucket, info.destination_path)
        end
      end)

      {:error, "Stored #{written} of the #{min_copies} copies required"}
    else
      {:ok, Map.put(info, :complete?, written >= target)}
    end
  end

  defp safe_delete(bucket, key) do
    get_provider_for_bucket(bucket).delete_file(bucket, key)
  rescue
    _ -> :error
  end

  # Capacity (G9): a bucket with a `max_size_mb` is full when what its
  # active locations hold reaches it. The sum is cached for a minute per
  # bucket; a bucket with no cap is never full.
  @usage_ttl 60_000

  defp bucket_full?(%{max_size_mb: max} = bucket) when is_integer(max) and max > 0 do
    key = {:phoenix_kit_bucket_usage, to_string(bucket.uuid)}
    now = System.monotonic_time(:millisecond)

    used =
      case :persistent_term.get(key, nil) do
        {at, used} when now - at < @usage_ttl ->
          used

        _ ->
          used = Storage.calculate_bucket_usage(bucket.uuid)
          :persistent_term.put(key, {now, used})
          used
      end

    used >= max
  rescue
    _ -> false
  end

  defp bucket_full?(_bucket), do: false

  @doc """
  Retrieves a file from storage with failover.

  Tries each bucket in priority order until the file is found.
  """
  def retrieve_file(file_path, opts \\ []) do
    {located, fallback} =
      read_order(file_path, Keyword.get(opts, :priority_buckets, []), :read)

    case retrieve_with_failover(file_path, located, opts) do
      {:ok, path, _bucket} ->
        {:ok, path}

      {:error, _} ->
        case retrieve_with_failover(file_path, fallback, opts) do
          {:ok, path, bucket} ->
            Locations.record(file_path, bucket.uuid)
            {:ok, path}

          error ->
            error
        end
    end
  end

  @doc """
  Deletes a file from all storage buckets.
  """
  def delete_file(file_path, opts \\ []) do
    priority_buckets = Keyword.get(opts, :priority_buckets, [])
    buckets = select_buckets_for_retrieval(priority_buckets)

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        provider.delete_file(bucket, file_path)
      end)

    # Return success if at least one deletion succeeded
    if Enum.any?(results, &(&1 == :ok)) do
      :ok
    else
      {:error, "Failed to delete file from all buckets"}
    end
  end

  @doc """
  Checks if a file exists in any storage bucket.
  """
  def file_exists?(file_path, opts \\ []) do
    {located, fallback} =
      read_order(file_path, Keyword.get(opts, :priority_buckets, []), :read)

    holds? = fn bucket -> bucket_holds?(bucket, file_path) end

    Enum.any?(located, holds?) or
      case Enum.find(fallback, holds?) do
        nil ->
          false

        bucket ->
          Locations.record(file_path, bucket.uuid)
          true
      end
  end

  @doc """
  Gets a public URL for a file from the highest priority bucket that has it.
  """
  def public_url(file_path, opts \\ []) do
    {located, fallback} =
      read_order(file_path, Keyword.get(opts, :priority_buckets, []), :serve)

    url_from = fn bucket, record? ->
      # Only a public bucket hands out a plain object URL: a private or
      # signed one answers it with a denial, so it is not a URL to give out.
      if public_bucket?(bucket) and bucket_holds?(bucket, file_path) do
        if record?, do: Locations.record(file_path, bucket.uuid)
        get_provider_for_bucket(bucket).public_url(bucket, file_path)
      end
    end

    Enum.find_value(located, &url_from.(&1, false)) ||
      Enum.find_value(fallback, &url_from.(&1, true))
  end

  @doc """
  Replicates a file to specific target buckets.

  Retrieves the file from any available bucket, then stores it to
  each target bucket. Returns the list of bucket UUIDs that succeeded.
  """
  def replicate_to_buckets(file_path, target_buckets, opts \\ []) do
    # First retrieve the file to a temp location
    temp_path = generate_temp_path() <> Path.extname(file_path)

    case retrieve_file(file_path, destination_path: temp_path) do
      {:ok, local_path} ->
        try do
          store_across_buckets(local_path, target_buckets, [{:path_prefix, file_path} | opts])
        after
          File.rm(local_path)
        end

      {:error, reason} ->
        {:error, "Cannot retrieve source file for replication: #{inspect(reason)}"}
    end
  rescue
    error -> {:error, "Replication failed: #{inspect(error)}"}
  end

  # Private functions

  defp select_buckets_for_storage(redundancy_copies, priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Get fresh bucket list from database (don't use cache for selection)
      # This ensures we get the current state and can shuffle properly
      all_buckets = Storage.list_enabled_buckets()

      # Separate buckets by priority
      {auto_priority_buckets, fixed_priority_buckets} =
        Enum.split_with(all_buckets, &(&1.priority == 0))

      # Shuffle auto-priority buckets (priority = 0) for random distribution
      # Fixed priority buckets are deterministic
      shuffled_auto = Enum.shuffle(auto_priority_buckets)

      # Combine: fixed priority buckets first (sorted), then shuffled auto-priority
      (Enum.sort_by(fixed_priority_buckets, & &1.priority) ++ shuffled_auto)
      |> Enum.take(redundancy_copies)
    else
      # Use specified buckets
      Storage.list_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
      |> Enum.take(redundancy_copies)
    end
  end

  # Whether `bucket` has the object. A bucket that raises (credentials, a
  # timeout) does not have it, for this request: the next bucket is tried
  # instead of the whole read failing. The recorded buckets are tried first
  # now, so a sick one must not take a file down that another copy serves.
  defp bucket_holds?(bucket, file_path) do
    get_provider_for_bucket(bucket).file_exists?(bucket, file_path)
  rescue
    error ->
      Logger.warning(
        "Storage: could not check #{file_path} on bucket #{bucket.name}: #{Exception.message(error)}"
      )

      false
  end

  defp forced_buckets(bucket_uuids) do
    enabled = Map.new(Storage.list_enabled_buckets(), &{to_string(&1.uuid), &1})

    bucket_uuids
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(Map.get(enabled, &1)))
  end

  defp select_buckets_for_retrieval(priority_buckets) do
    if Enum.empty?(priority_buckets) do
      # Use all enabled buckets ordered by priority (simple sort, no usage calculation needed for retrieval)
      get_enabled_buckets()
      |> Enum.sort_by(& &1.priority)
    else
      # Use specified buckets
      get_enabled_buckets()
      |> Enum.filter(&(&1.uuid in priority_buckets))
    end
  end

  # The buckets to read `file_path` from: `{located, fallback}`. With no
  # buckets named, the enabled ones its location rows name come first, in
  # the order its file's storage profile serves from (V205,
  # `Locations.ranked/1`), and every other enabled bucket is the fallback,
  # by priority. `purpose` is `:serve` (to a client: a backup copy is never
  # served, and not probed either) or `:read` (bytes to process, or whether
  # the object exists: a backup may be used, last). Named buckets are used
  # as they are, with no fallback.
  defp read_order(file_path, [], purpose) do
    case Locations.ranked(file_path) do
      # Checked and found in no bucket: not asked about again on every
      # request (the backfill remembered the miss).
      [] ->
        if Locations.known_missing?(file_path),
          do: {[], []},
          else: {[], select_buckets_for_retrieval([])}

      ranked ->
        enabled = select_buckets_for_retrieval([])
        by_uuid = Map.new(enabled, &{to_string(&1.uuid), &1})
        named = MapSet.new(ranked, & &1.bucket_uuid)

        located =
          ranked
          |> Enum.reject(&(purpose == :serve and &1.role == "backup"))
          |> Enum.flat_map(&List.wrap(Map.get(by_uuid, &1.bucket_uuid)))

        {located, Enum.reject(enabled, &MapSet.member?(named, to_string(&1.uuid)))}
    end
  end

  defp read_order(_file_path, priority_buckets, _purpose),
    do: {select_buckets_for_retrieval(priority_buckets), []}

  defp store_across_buckets(source_path, buckets, opts) do
    # Use path_prefix if provided, otherwise generate a path
    destination_path =
      case Keyword.get(opts, :path_prefix) do
        nil -> generate_destination_path(source_path, opts)
        path_prefix -> path_prefix
      end

    results =
      buckets
      |> Enum.map(fn bucket ->
        provider = get_provider_for_bucket(bucket)
        result = provider.store_file(bucket, source_path, destination_path, opts)
        {bucket, result}
      end)

    # Only include buckets where the upload actually succeeded
    successful_buckets =
      Enum.filter(results, fn {_bucket, result} ->
        result == :ok or match?({:ok, _}, result)
      end)

    if successful_buckets != [] do
      file_info = %{
        destination_path: destination_path,
        stored_in: length(buckets),
        successful_storages: length(successful_buckets),
        bucket_ids: Enum.map(successful_buckets, fn {bucket, _} -> bucket.uuid end)
      }

      {:ok, file_info}
    else
      {:error, "Failed to store file in any bucket"}
    end
  end

  defp retrieve_with_failover(_file_path, [], _opts), do: {:error, "File not found in any bucket"}

  defp retrieve_with_failover(file_path, [bucket | remaining_buckets], opts) do
    provider = get_provider_for_bucket(bucket)

    destination_path =
      Keyword.get(opts, :destination_path, generate_temp_path() <> temp_extension(file_path))

    case safe_retrieve(provider, bucket, file_path, destination_path) do
      :ok ->
        {:ok, destination_path, bucket}

      {:error, reason} ->
        Logger.debug(
          "Storage: #{file_path} not read from bucket #{bucket.name}: #{inspect(reason)}"
        )

        retrieve_with_failover(file_path, remaining_buckets, opts)
    end
  end

  # A bucket that raises while reading fails over like one that errors.
  defp safe_retrieve(provider, bucket, file_path, destination_path) do
    provider.retrieve_file(bucket, file_path, destination_path)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp get_provider_for_bucket(bucket) do
    {:ok, provider_module} = ProviderRegistry.get_provider(bucket.provider)
    provider_module
  end

  defp generate_destination_path(source_path, opts) do
    original_name = Path.basename(source_path)
    extension = Path.extname(original_name)
    base_name = Path.rootname(original_name)

    timestamp = UtilsDate.utc_now() |> DateTime.to_iso8601()
    random_suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    prefix = Keyword.get(opts, :path_prefix, "")
    subdir = Keyword.get(opts, :subdir, timestamp)

    Path.join([prefix, subdir, "#{base_name}_#{random_suffix}#{extension}"])
  end

  defp generate_temp_path do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_#{random_name}")
  end

  @doc false
  # The extension a processing temp copy of `file_path` should carry.
  #
  # ImageMagick identifies some formats (ICO among them) by extension alone,
  # so an extensionless copy fails with "no decode delegate". But the stored
  # extension is the uploader's filename, and an extension also *selects*
  # the coders that have no magic bytes to sniff — MVG, MSL, TXT — which an
  # extensionless copy never reaches. So it is kept only when it names a
  # media type (image, video, audio, PDF); `.mvg` uploaded as `image/png`
  # gets no extension and ImageMagick still reads it by content alone.
  @spec temp_extension(String.t()) :: String.t()
  def temp_extension(file_path) do
    case MIME.from_path(file_path) do
      "image/" <> _ -> Path.extname(file_path)
      "video/" <> _ -> Path.extname(file_path)
      "audio/" <> _ -> Path.extname(file_path)
      "application/pdf" -> Path.extname(file_path)
      _ -> ""
    end
  end

  @doc """
  Drops the cached list of enabled buckets, so the next read sees the
  database. Called whenever a bucket is created, updated or deleted. The
  cache only spares a query per file request; it expires on its own after
  five minutes, which is how long a bucket edit used to take to apply.
  """
  def invalidate_bucket_cache do
    :persistent_term.erase(:phoenix_kit_buckets_cache)
    :ok
  end

  defp get_enabled_buckets do
    # Cache bucket list to avoid querying on every file request
    cache_key = :phoenix_kit_buckets_cache
    current_time = System.monotonic_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {timestamp, buckets} when current_time - timestamp < @buckets_cache_ttl ->
        # Cache hit - return cached buckets
        buckets

      _ ->
        # Cache miss or expired - fetch fresh buckets
        buckets = Storage.list_enabled_buckets()
        :persistent_term.put(cache_key, {current_time, buckets})
        buckets
    end
  end

  @doc """
  Returns the local filesystem path for a file if stored locally.

  This function checks enabled buckets with "local" provider and returns the
  direct path to the file if it exists. This allows serving files directly
  without copying to a temp file first.

  ## Returns

  - `{:ok, path}` - File exists at the local path
  - `{:error, :not_local}` - No local bucket contains the file
  """
  def get_local_file_path(file_path),
    do: local_path(file_path, read_order(file_path, [], :serve))

  defp local_path(file_path, {located, fallback}) do
    Enum.find_value(located, &local_hit(&1, file_path, false)) ||
      Enum.find_value(fallback, {:error, :not_local}, &local_hit(&1, file_path, true))
  end

  # `{:ok, path}` when `bucket` is local and holds `file_path`; a hit found
  # by probing (`record?`) is recorded as a location.
  defp local_hit(%{provider: "local"} = bucket, file_path, record?) do
    full_path = Path.join(Local.root(bucket), file_path)

    if File.exists?(full_path) do
      if record?, do: Locations.record(file_path, bucket.uuid)
      {:ok, full_path}
    end
  end

  defp local_hit(_bucket, _file_path, _record?), do: nil

  @doc """
  Returns file access info based on bucket access_type.

  Determines how a file should be served based on its storage location:
  - Local files are always served directly
  - Remote files depend on bucket's access_type setting

  ## Returns

  - `{:local, path}` - File is local, serve directly from filesystem
  - `{:redirect, url}` - Redirect to public URL (for public buckets)
  - `{:signed_redirect, url}` - Redirect to a short-lived signed URL (a
    public bucket, with `:download` given)
  - `{:proxy, file_name}` - Download and proxy through server (for private buckets)
  - `{:error, :not_found}` - File not found in any bucket

  ## Options

  - `:download` - response headers (`:disposition`, `:content_type`) for a
    file that must download rather than render. A public bucket's plain
    object URL answers with the object's stored headers, so for such a file
    a public bucket hands out a signed URL that overrides them
    (`c:PhoenixKit.Modules.Storage.Provider.signed_download_url/3`), or is
    proxied when its provider cannot sign one.
  """
  def get_file_access(file_name, opts \\ []) do
    download = Keyword.get(opts, :download)
    {located, fallback} = read_order(file_name, [], :serve)

    # The recorded copies in the profile's serve order (G3: a remote copy
    # may come before a local one); then, for a key with no rows yet,
    # today's rule: a local copy first.
    Enum.find_value(located, &serve_from(&1, file_name, download, false)) ||
      fallback_access(file_name, fallback, download)
  end

  defp fallback_access(file_name, fallback, download) do
    {local, remote} = Enum.split_with(fallback, &(&1.provider == "local"))

    Enum.find_value(local, &serve_from(&1, file_name, download, true)) ||
      Enum.find_value(remote, {:error, :not_found}, &serve_from(&1, file_name, download, true))
  end

  defp serve_from(%{provider: "local"} = bucket, file_name, _download, record?) do
    with {:ok, path} <- local_hit(bucket, file_name, record?), do: {:local, path}
  end

  defp serve_from(bucket, file_name, download, record?),
    do: check_bucket_for_file(bucket, file_name, download, record?)

  defp check_bucket_for_file(bucket, file_name, download, record?) do
    provider = get_provider_for_bucket(bucket)

    if bucket_holds?(bucket, file_name) do
      if record?, do: Locations.record(file_name, bucket.uuid)
      bucket_access(bucket, file_name, provider, download)
    end
  end

  defp public_bucket?(%{access_type: type}) when type in ["private", "signed"], do: false
  defp public_bucket?(_bucket), do: true

  # How long a `"signed"` bucket's URL for one request lives.
  @signed_url_seconds 300

  @doc false
  # How a remote bucket that holds `file_name` serves it. Public and
  # `@doc false` only so the decision is testable without a live bucket.
  def bucket_access(%{access_type: "private"}, file_name, _provider, _download) do
    {:proxy, file_name}
  end

  # A `"signed"` bucket is served by a short-lived presigned URL made for
  # this request, never by its plain object URL; proxied when the provider
  # cannot sign.
  def bucket_access(%{access_type: "signed"} = bucket, file_name, provider, download) do
    opts = Keyword.put(download || [], :expires_in, @signed_url_seconds)

    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, opts) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  # "public" or nil (default), for a file that must download.
  def bucket_access(bucket, file_name, provider, download) when is_list(download) do
    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :signed_download_url, 3),
         {:ok, url} <- provider.signed_download_url(bucket, file_name, download) do
      {:signed_redirect, url}
    else
      _ -> {:proxy, file_name}
    end
  end

  # A public bucket whose provider has no public URL for the object (an R2
  # bucket with no public domain) is proxied: the object is there, it just
  # cannot be linked to.
  def bucket_access(bucket, file_name, provider, nil) do
    case provider.public_url(bucket, file_name) do
      nil -> {:proxy, file_name}
      url -> {:redirect, url}
    end
  end
end
