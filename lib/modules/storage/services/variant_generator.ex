defmodule PhoenixKit.Modules.Storage.VariantGenerator do
  @moduledoc """
  Variant generation system for images and videos.

  This module handles the creation of different variants (thumbnails, resizes,
  quality adjustments) for uploaded files based on dimension configurations.

  ## Supported Operations

  ### Images
  - Resize to specific dimensions
  - Generate thumbnails (square crops)
  - Quality adjustments
  - Format conversion (JPEG, PNG, WebP)

  ### Videos
  - Quality variants (360p, 720p, 1080p)
  - Thumbnail extraction
  - Format conversion (MP4)

  ## Dependencies

  Requires external tools to be installed:
  - Images: ImageMagick (`convert` and `identify` commands)
  - Videos: FFmpeg

  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ImageProcessor
  alias PhoenixKit.Modules.Storage.Manager
  alias PhoenixKit.Modules.Storage.PdfProcessor
  alias PhoenixKit.Modules.Storage.VariantSets

  require Logger

  @doc """
  Generates variants for a file based on enabled dimensions.

  ## Parameters

  - `file` - The file struct to generate variants for
  - `opts` - Options for variant generation

  ## Options

  - `:dimensions` - List of specific dimensions to generate (default: all enabled)

  Variant generation is always synchronous from the caller's perspective.
  Internally `process_variants/2` parallelizes the per-dimension work via
  `Task.await_many/2` with a 10-minute cap. Callers that need fire-and-forget
  semantics should enqueue the work via Oban (see `process_file_job.ex`).

  ## Returns

  - `{:ok, variants}` - List of generated file instances
  - `{:error, reason}` - Error if generation fails
  """
  def generate_variants(file, opts \\ []) do
    specific_dimensions = Keyword.get(opts, :dimensions, [])
    # The set as it is now: the run is stamped with this revision, so a size
    # changed while it runs leaves the file stale, not falsely up to date.
    set = VariantSets.for_file(file)

    cond do
      not variant_source?(file) ->
        {:ok, []}

      # The file's library's variant set makes no sizes automatically:
      # nothing is missing, so its variants are as the set wants them.
      not VariantSets.variants_for?(file) ->
        if specific_dimensions == [], do: VariantSets.record_variants(file, true, set)
        {:ok, []}

      true ->
        dimensions = get_dimensions_for_generation(file, specific_dimensions)

        {result, complete?} =
          case dimensions do
            [] -> {{:ok, []}, true}
            _ -> process_variants(file, dimensions)
          end

        # A full run records whether every size of the set was made; one
        # that failed leaves the file stale for the reconciler.
        if specific_dimensions == [], do: VariantSets.record_variants(file, complete?, set)
        result
    end
  end

  @doc """
  Generates a specific variant for a file.

  ## Parameters

  - `file` - The file struct
  - `dimension` - The dimension configuration

  ## Returns

  - `{:ok, file_instance}` - Generated variant
  - `{:error, reason}` - Error if generation fails
  """
  def generate_variant(file, dimension) do
    # Guard: file_path must exist to generate variants
    if is_nil(file.file_path) do
      Logger.warning("Cannot generate variant for file #{file.uuid}: file_path is nil")
      {:error, :file_path_missing}
    else
      do_generate_variant(file, dimension, dimension.name, dimension.format)
    end
  end

  @doc """
  Generates `variant_name` of `file` from `dimension` in `format`: the
  size's own format, or one of its alternative formats (`"medium_webp"`
  from `medium` in `"webp"`). What the reconciler uses to make one missing
  or stale variant (`expected_variants/1` lists them).
  """
  # `fresh_key: true` stores it under a key of its own (the spec hash in the
  # name) instead of the size's usual key: for a key another file still
  # serves under its old spec.
  def generate_variant(file, dimension, variant_name, format, opts \\ []) do
    if is_nil(file.file_path) do
      Logger.warning("Cannot generate variant for file #{file.uuid}: file_path is nil")
      {:error, :file_path_missing}
    else
      suffix =
        if Keyword.get(opts, :fresh_key),
          do: "_" <> String.slice(VariantSets.spec_hash(dimension, format), 0, 8),
          else: ""

      do_generate_variant(file, dimension, variant_name, format, suffix)
    end
  end

  @doc """
  The variants `file` should have by its library's variant set (V205), as
  `{dimension, variant_name, format}`: every enabled size for its type and
  each of its alternative formats. `[]` for a file no sizes are made of
  (system-managed, not an image, video or PDF) or whose set makes none.
  """
  def expected_variants(file) do
    if variant_source?(file) and VariantSets.variants_for?(file),
      do: file |> get_dimensions_for_generation([]) |> expand_dimensions_with_alternatives(),
      else: []
  end

  @doc """
  Whether sizes are made of `file` at all (by its type, not its set).
  System-managed media (Tessera DZI tiles + manifests) never get quality
  variants — a tile is already 256×256, generating a smaller tile-of-a-tile
  would waste CPU and disk for no user-facing value.
  """
  def variant_source?(file) do
    not file.system_managed and
      (file.file_type in ["image", "video"] or
         (file.file_type == "document" and file.mime_type == "application/pdf"))
  end

  defp do_generate_variant(file, dimension, variant_name, format_override, key_suffix \\ "") do
    Logger.info("Generating variant: #{variant_name} for file: #{file.uuid}")

    # Generate variant filename using file checksum + variant name for uniqueness
    variant_ext = determine_variant_extension(file.ext, format_override)
    # Use file_checksum or file_name basename for naming (works with any path structure)
    base_name = file.file_checksum || Path.basename(file.file_name, Path.extname(file.file_name))
    variant_filename = "#{base_name}_#{variant_name}#{key_suffix}.#{variant_ext}"
    variant_mime_type = determine_variant_mime_type(file.mime_type, format_override)

    # Build the variant storage path using file_path as base directory
    # file_path can be any directory structure (timestamp-based or hierarchical)
    variant_storage_path = "#{file.file_path}/#{variant_filename}"

    # Generate temp path for processing
    variant_path = generate_temp_path(variant_ext)

    # Override dimension format for alternative format variants
    effective_dimension = %{dimension | format: format_override}

    # Download original file to temp location
    result =
      with {:ok, original_path, source_key} <- retrieve_original_file(file) do
        # Both temp files go whatever the outcome: a format ImageMagick cannot
        # decode fails on every attempt, and each request for the missing
        # variant re-queues the job — a copy left behind per failure fills
        # the temp dir.
        try do
          with {:ok, variant_path} <-
                 process_variant(original_path, variant_path, file.mime_type, effective_dimension),
               {:ok, file_stats} <- get_variant_file_stats(variant_path),
               {:ok, storage_info} <-
                 store_variant_file(variant_path, variant_name, variant_storage_path, file) do
            publish_variant(
              file,
              variant_attrs(
                variant_name,
                variant_storage_path,
                variant_mime_type,
                variant_ext,
                file_stats,
                VariantSets.spec_hash(dimension, format_override)
              ),
              storage_info.bucket_ids,
              source_key
            )
          end
        after
          cleanup_temp_files([original_path, variant_path])
        end
      end

    case result do
      {:ok, instance} ->
        Logger.info("Variant #{variant_name} created successfully in database with locations")
        {:ok, instance}

      {:error, :file_locations_failed} = error ->
        Logger.error("Variant #{variant_name} failed: file locations could not be created")
        error

      {:error, reason} = error ->
        Logger.error("Variant #{variant_name} failed: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stores an already-rendered variant file as `variant_name` on `file`.

  Use this when the variant bytes are produced outside the normal resize
  pipeline (e.g. the baked annotated thumbnail). Handles stats, bucket storage,
  the `FileInstance` row, and file-location records — then removes `prepared_path`.

  Pass `source_key:` — the `file_name` of the original instance the bytes
  were made from (`Storage.retrieve_original/1`) — and the variant is only
  recorded while that is still the file's original.

  Returns `{:ok, instance}` or `{:error, reason}`.
  """
  def store_prepared_variant(
        file,
        variant_name,
        prepared_path,
        variant_ext,
        variant_mime_type,
        opts \\ []
      ) do
    base_name = file.file_checksum || Path.basename(file.file_name, Path.extname(file.file_name))
    variant_filename = "#{base_name}_#{variant_name}.#{variant_ext}"
    variant_storage_path = "#{file.file_path}/#{variant_filename}"

    try do
      with {:ok, file_stats} <- get_variant_file_stats(prepared_path),
           {:ok, storage_info} <-
             store_variant_file(prepared_path, variant_name, variant_storage_path, file) do
        publish_variant(
          file,
          variant_attrs(
            variant_name,
            variant_storage_path,
            variant_mime_type,
            variant_ext,
            file_stats,
            nil
          ),
          storage_info.bucket_ids,
          Keyword.get(opts, :source_key)
        )
      end
    after
      cleanup_temp_files([prepared_path])
    end
  end

  # Private functions

  defp get_variant_file_stats(variant_path) do
    with {:ok, stat} <- File.stat(variant_path) do
      checksum = calculate_file_checksum(variant_path)
      width = get_width_from_file(variant_path)
      height = get_height_from_file(variant_path)
      {:ok, %{size: stat.size, checksum: checksum, width: width, height: height}}
    end
  end

  # A variant is a derived object: it goes where the file's library's
  # storage profile puts derived files (V205), which need not be the
  # original's buckets. Fewer copies than the profile wants leave the file
  # stale for the reconciler.
  defp store_variant_file(variant_path, variant_name, storage_path, file) do
    Logger.info("Storing variant #{variant_name} to storage buckets at path: #{storage_path}")

    case Storage.store_by_profile(variant_path, file.library_uuid, :derived,
           generate_variants: false,
           path_prefix: storage_path
         ) do
      {:ok, storage_info} = success ->
        Logger.info("Variant #{variant_name} stored successfully in buckets")
        unless storage_info.complete?, do: Storage.mark_placement_stale(file.uuid)
        success

      error ->
        error
    end
  end

  # Records a stored variant on `file`, all or nothing.
  #
  # The file row is read FOR SHARE and checked against what this variant was
  # made from — the checksum its key is named after, and the original
  # instance it was rendered from (`source_key`): an image edit swaps the
  # original (and the checksum) under FOR UPDATE, and a generator that
  # started before the swap, or read the file and the original on either
  # side of it, must not attach a variant of other bytes to the file. Such a
  # result is dropped (its object deleted unless the backup still uses it).
  #
  # An existing row is refreshed rather than kept as it was: regeneration
  # writes new bytes, and a stale checksum or size on the row misleads every
  # consumer. Locations are only re-created when the key changed — the old
  # code added a duplicate set on every regeneration.
  #
  # `variant` is the instance's attributes (`variant_attrs/6`).
  defp publish_variant(file, variant, bucket_uuids, source_key) do
    repo = PhoenixKit.Config.get_repo()
    %{variant_name: variant_name, file_name: storage_path} = variant
    attrs = Map.merge(variant, %{processing_status: "completed", file_uuid: file.uuid})

    repo.transaction(fn ->
      current =
        from(f in Storage.File,
          where: f.uuid == ^file.uuid,
          lock: "FOR SHARE",
          select: f.file_checksum
        )
        |> repo.one()

      if current != file.file_checksum or
           (source_key && not Storage.original_key?(file.uuid, source_key)),
         do: repo.rollback(:stale_source)

      # A deletion of this (content-addressed) key may have run since it was
      # stored; under the directory lock the object is either still there or
      # its deletion is over.
      Storage.lock_storage_paths([Path.dirname(storage_path)])
      unless Manager.file_exists?(storage_path), do: repo.rollback(:object_missing)

      case Storage.get_file_instance_by_name(file.uuid, variant_name) do
        nil ->
          insert_variant!(repo, attrs, bucket_uuids)

        %Storage.FileInstance{file_name: ^storage_path} = existing ->
          {:ok, instance} = Storage.update_file_instance(existing, attrs)
          {instance, []}

        %Storage.FileInstance{file_name: old_key} = existing ->
          {:ok, _} = repo.delete(existing)
          {instance, []} = insert_variant!(repo, attrs, bucket_uuids)
          {instance, Storage.unreferenced_keys([old_key])}
      end
    end)
    |> case do
      {:ok, {instance, stale_keys}} ->
        _ = Storage.delete_stored_objects(stale_keys)
        {:ok, instance}

      {:error, :stale_source} ->
        Logger.info("Variant #{variant_name} of #{file.uuid} dropped: the original changed")

        _ = Storage.delete_stored_objects([storage_path])

        {:error, :stale_source}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A variant instance's attributes. `spec_hash` is the spec of the size it
  # was made from (V205), nil for a variant not made from a size (an
  # annotated thumbnail).
  defp variant_attrs(name, key, mime_type, ext, stats, spec_hash) do
    %{
      variant_name: name,
      file_name: key,
      mime_type: mime_type,
      ext: ext,
      checksum: stats.checksum,
      size: stats.size,
      width: stats.width,
      height: stats.height,
      spec_hash: spec_hash
    }
  end

  defp insert_variant!(repo, attrs, bucket_uuids) do
    with {:ok, instance} <- Storage.create_file_instance(attrs),
         {:ok, _locations} <-
           Storage.create_file_locations_for_instance(
             instance.uuid,
             bucket_uuids,
             attrs.file_name
           ) do
      {instance, []}
    else
      {:error, :file_locations_failed, errors} ->
        Logger.error("Failed to create file locations for #{attrs.file_name}: #{inspect(errors)}")
        repo.rollback(:file_locations_failed)

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp cleanup_temp_files(paths) do
    Enum.each(paths, &File.rm/1)
  end

  # The sizes of the file's library's variant set (V205) for its type.
  defp get_dimensions_for_generation(file, specific_dimensions) do
    # PDFs generate image thumbnails, so use image dimensions
    query_type = if file.file_type == "document", do: "image", else: file.file_type

    base_query =
      Storage.list_dimensions_for_type(query_type, VariantSets.set_uuid_for(file.library_uuid))

    dimensions =
      if Enum.empty?(specific_dimensions) do
        base_query
      else
        Enum.filter(base_query, &(&1.name in specific_dimensions))
      end

    # Filter out the "original" dimension as that's handled separately
    Enum.filter(dimensions, &(&1.name != "original"))
  end

  # Expands each dimension into {dimension, variant_name, format_override} tuples,
  # including one tuple per alternative format configured on the dimension.
  defp expand_dimensions_with_alternatives(dimensions) do
    Enum.flat_map(dimensions, fn dim ->
      primary = {dim, dim.name, dim.format}
      alt_formats = Map.get(dim, :alternative_formats, []) || []

      alternatives =
        Enum.map(alt_formats, fn fmt ->
          {dim, "#{dim.name}_#{fmt}", fmt}
        end)

      [primary | alternatives]
    end)
  end

  defp process_variants(file, dimensions) do
    expanded = expand_dimensions_with_alternatives(dimensions)

    results =
      expanded
      |> Enum.map(fn {dim, vname, fmt} ->
        Task.async(fn -> do_generate_variant(file, dim, vname, fmt) end)
      end)
      # Video transcoding can take several minutes for large files
      |> Task.await_many(:timer.minutes(10))

    # Separate successful and failed results
    {successful, failed} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    result =
      if Enum.empty?(successful) and not Enum.empty?(failed) do
        {:error, "All variant generations failed"}
      else
        {:ok, Enum.map(successful, fn {:ok, variant} -> variant end)}
      end

    {result, failed == []}
  end

  defp determine_variant_mime_type(original_mime, format_override) do
    if format_override do
      case format_override do
        "jpg" -> "image/jpeg"
        "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        "mp4" -> "video/mp4"
        _ -> original_mime
      end
    else
      # PDF variants are rendered as JPEG images
      if original_mime == "application/pdf", do: "image/jpeg", else: original_mime
    end
  end

  defp determine_variant_extension(original_ext, format_override) do
    if format_override do
      # Return extension WITHOUT leading dot - generate_temp_path will add it
      if String.starts_with?(format_override, ".") do
        String.trim_leading(format_override, ".")
      else
        format_override
      end
    else
      ext = String.trim_leading(original_ext, ".")
      # PDF variants are rendered as JPEG images
      if ext == "pdf", do: "jpg", else: ext
    end
  end

  defp retrieve_original_file(file) do
    case Storage.retrieve_original(file.uuid) do
      {:ok, path, _file, instance} -> {:ok, path, instance.file_name}
      error -> error
    end
  end

  defp process_variant(original_path, variant_path, mime_type, dimension) do
    cond do
      String.starts_with?(mime_type, "image/") ->
        process_image_variant(original_path, variant_path, mime_type, dimension)

      String.starts_with?(mime_type, "video/") ->
        process_video_variant(original_path, variant_path, mime_type, dimension)

      mime_type == "application/pdf" ->
        process_pdf_variant(original_path, variant_path, dimension)

      true ->
        {:error, "Unsupported file type for variant generation"}
    end
  end

  defp process_image_variant(input_path, output_path, _mime_type, dimension) do
    Logger.info(
      "process_image_variant: input=#{input_path} output=#{output_path} width=#{dimension.width} height=#{dimension.height} maintain_aspect=#{dimension.maintain_aspect_ratio}"
    )

    quality = dimension.quality || 85
    format = dimension.format

    # Decision based on maintain_aspect_ratio setting
    case dimension.maintain_aspect_ratio do
      true ->
        # Maintain aspect ratio - use only width
        Logger.info("Using responsive resize for #{dimension.name} (width: #{dimension.width}px)")

        ImageProcessor.resize(input_path, output_path, dimension.width, nil,
          quality: quality,
          format: format
        )

      false ->
        # Fixed dimensions - use center-crop with gravity
        Logger.info(
          "Using center-crop for #{dimension.name} (#{dimension.width}x#{dimension.height})"
        )

        ImageProcessor.resize_and_crop_center(
          input_path,
          output_path,
          dimension.width,
          dimension.height,
          quality: quality,
          format: format,
          background: "white"
        )
    end
  end

  defp process_video_variant(input_path, output_path, _mime_type, dimension) do
    # Build FFmpeg command
    args = build_ffmpeg_args(input_path, output_path, dimension)

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} ->
        # FFmpeg succeeded - dimensions are enforced by the scale filter
        {:ok, output_path}

      {output, exit_code} ->
        {:error, "FFmpeg failed with exit code #{exit_code}: #{output}"}
    end
  end

  defp build_ffmpeg_args(input_path, output_path, dimension) do
    # -y to overwrite output file
    args = ["-i", input_path, "-y"]

    # Handle video quality variants
    args =
      case dimension.name do
        "360p" ->
          args ++ ["-vf", "scale=640:360", "-crf", "28"]

        "720p" ->
          args ++ ["-vf", "scale=1280:720", "-crf", "25"]

        "1080p" ->
          args ++ ["-vf", "scale=1920:1080", "-crf", "23"]

        "video_thumbnail" ->
          args ++ ["-ss", "00:00:01.000", "-vframes", "1", "-vf", "scale=640:360"]

        _ ->
          if dimension.width and dimension.height do
            args ++ ["-vf", "scale=#{dimension.width}:#{dimension.height}"]
          else
            args
          end
      end

    # Handle quality (override for specific variants)
    args =
      if dimension.quality && dimension.name not in ["360p", "720p", "1080p"] do
        quality = convert_video_quality(dimension.quality)
        args ++ ["-crf", quality]
      else
        args
      end

    args ++ [output_path]
  end

  defp convert_video_quality(quality) when is_integer(quality) do
    # FFmpeg CRF uses 0-51 (lower = higher quality)
    # Map image quality (1-100) to CRF (51-0)
    crf = 51 - trunc(quality / 100 * 51)
    Integer.to_string(crf)
  end

  defp calculate_file_checksum(file_path) do
    file_path
    |> File.read!()
    |> then(fn data -> :crypto.hash(:sha256, data) end)
    |> Base.encode16(case: :lower)
  end

  defp get_width_from_file(file_path) do
    ImageProcessor.get_width(file_path)
  end

  defp get_height_from_file(file_path) do
    ImageProcessor.get_height(file_path)
  end

  defp process_pdf_variant(input_path, output_path, dimension) do
    temp_prefix = generate_temp_prefix()

    case PdfProcessor.first_page_to_jpeg(input_path, temp_prefix) do
      {:ok, jpeg_path} ->
        result = process_image_variant(jpeg_path, output_path, "image/jpeg", dimension)
        File.rm(jpeg_path)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp generate_temp_prefix do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_pdf_#{random_name}")
  end

  defp generate_temp_path(extension) do
    temp_dir = System.tmp_dir!()
    random_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(temp_dir, "phoenix_kit_variant_#{random_name}.#{extension}")
  end
end
