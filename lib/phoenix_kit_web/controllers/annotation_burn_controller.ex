defmodule PhoenixKitWeb.AnnotationBurnController do
  @moduledoc """
  Accepts a picture with its annotations already drawn into it, and stores it
  as one of the file's variants.

  ## Why the client renders it

  The browser has the annotation layer on screen, drawn by the same engine
  that will draw it next time. Composing there means the stored picture IS
  what the user was looking at: the same fonts, the same label plates, the
  same smooth marker strokes, and no second renderer to keep in step with
  the first. `Etcher.Raster` remains the server-side path for backfill and
  for files nobody has open, where an approximation is the right trade.

  ## What this means for trust

  The bytes come from a client, so they are treated as a picture and nothing
  more: re-encoded through ImageMagick into the variant slot, never served
  back as uploaded. The caller must be signed in and allowed to edit the
  file, and the annotation set is not consulted — this endpoint replaces a
  rendering, it cannot change what the file's annotations ARE.

  ## Current scope

  The burn arrives at full resolution and is resized into whichever slots
  the caller names (`thumbnail` by default) in one request — making one is
  expensive enough that nobody should have to send it twice. `original` is
  not writable: the picture as uploaded stays the source of truth, and a
  rendering that overwrote it would make the annotations unremovable.
  """
  use PhoenixKitWeb, :controller

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Users.Auth.User

  # A 5000px burn as JPEG is a few MB; the cap is generous enough for a
  # large board and small enough that nothing silly gets spooled to disk.
  @max_bytes 60 * 1024 * 1024
  @accepted ~w(image/jpeg image/png)
  # The slots a burn may be written into. `original` is not among them: the
  # source of truth stays the picture as it was uploaded, and a rendering
  # that overwrote it would make the annotations unremovable.
  @writable ~w(thumbnail small medium large)
  @default_variants ~w(thumbnail)

  @doc """
  `POST /api/files/:file_uuid/burn` — multipart, field `image`.

  Answers with the variant that was written and a fresh signed URL for it,
  so a caller can show the result without guessing the URL or waiting for a
  page reload.
  """
  def create(conn, %{"file_uuid" => file_uuid} = params) do
    with {:ok, user} <- require_user(conn),
         {:ok, file} <- fetch_file(file_uuid),
         :ok <- authorize(user, file),
         {:ok, upload} <- extract_image(params),
         :ok <- accept_type(upload),
         {:ok, source} <- readable_size(upload),
         {:ok, variants} <- requested_variants(params),
         {:ok, written} <- write_variants(file, source, variants) do
      json(conn, %{written: written})
    else
      {:error, reason} -> fail(conn, reason)
    end
  end

  def create(conn, _params), do: fail(conn, :no_file)

  # ── the steps ────────────────────────────────────────────────────────────

  defp require_user(conn) do
    case conn.assigns[:phoenix_kit_current_user] do
      %User{} = user -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  defp fetch_file(uuid) do
    case Storage.get_file(uuid) do
      %Storage.File{} = file -> {:ok, file}
      _ -> {:error, :not_found}
    end
  end

  # Whoever owns the file, or anyone who can reach the admin area — the same
  # pair who can edit its annotations in the first place. A burn is a
  # rendering OF those annotations, so the right to make one follows the
  # right to have drawn them.
  defp authorize(%User{} = user, file) do
    cond do
      file.user_uuid && file.user_uuid == user.uuid -> :ok
      User.admin?(user) -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp extract_image(%{"image" => %Plug.Upload{} = upload}), do: {:ok, upload}
  defp extract_image(_), do: {:error, :no_file}

  defp accept_type(%Plug.Upload{content_type: type}) when type in @accepted, do: :ok
  defp accept_type(_), do: {:error, :bad_type}

  defp readable_size(%Plug.Upload{path: path} = upload) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size <= @max_bytes -> {:ok, upload}
      {:ok, %{size: size}} when size > @max_bytes -> {:error, :too_large}
      _ -> {:error, :no_file}
    end
  end

  # One upload, every size asked for: the burn is expensive to make and a
  # caller should not have to send it again per slot.
  defp requested_variants(params) do
    asked =
      case params["variants"] || params["variant"] do
        list when is_list(list) -> list
        name when is_binary(name) -> String.split(name, ",", trim: true)
        _ -> @default_variants
      end
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    cond do
      asked == [] -> {:ok, @default_variants}
      Enum.all?(asked, &(&1 in @writable)) -> {:ok, asked}
      true -> {:error, :bad_variant}
    end
  end

  defp write_variants(file, source, variants) do
    written =
      Enum.reduce_while(variants, [], fn variant, acc ->
        case write_variant(file, source, variant) do
          {:ok, instance} ->
            {:cont,
             [
               %{
                 variant: variant,
                 width: instance.width,
                 height: instance.height,
                 size: instance.size,
                 url: URLSigner.signed_url(file.uuid, variant, version: instance, locale: :none)
               }
               | acc
             ]}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case written do
      {:error, reason} -> {:error, reason}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  # Re-encoded rather than stored as it arrived: the bytes are a client's,
  # and passing them through ImageMagick is what makes them a picture this
  # server vouches for rather than a file it was handed.
  defp write_variant(file, %Plug.Upload{path: path}, variant) do
    out = Path.join(System.tmp_dir!(), "pk_burn_#{System.unique_integer([:positive])}.jpg")
    {w, h} = variant_box(variant)

    args = [
      path,
      "-auto-orient",
      "-resize",
      "#{w}x#{h}>",
      "-strip",
      "-quality",
      "90",
      "jpg:#{out}"
    ]

    try do
      case System.cmd("convert", args, stderr_to_stdout: true) do
        {_, 0} ->
          # The key of the original this burn was drawn over. If that
          # original has been replaced since the browser composed it — a
          # crop, a rotate, a re-upload — the store rolls the write back
          # rather than filing a rendering of a picture that no longer
          # exists.
          VariantGenerator.store_prepared_variant(file, variant, out, "jpg", "image/jpeg",
            source_key: original_key(file)
          )

        {stderr, code} ->
          Logger.warning("burn convert exited #{code} for #{file.uuid}: #{stderr}")
          {:error, :convert_failed}
      end
    after
      File.rm(out)
    end
  end

  defp original_key(file) do
    case Storage.get_file_instance_by_name(file.uuid, "original") do
      %Storage.FileInstance{file_name: key} -> key
      _ -> nil
    end
  end

  # The size this slot is configured for, so a burn lands at the dimensions
  # everything else expects rather than at one hard-coded here.
  defp variant_box(variant) do
    Storage.list_dimensions()
    |> Enum.find(&(&1.name == variant))
    |> case do
      %{width: w, height: h} when is_integer(w) and is_integer(h) -> {w, h}
      _ -> {150, 150}
    end
  end

  # ── answers ──────────────────────────────────────────────────────────────

  defp fail(conn, reason) do
    {status, code, message} =
      case reason do
        :unauthorized ->
          {:unauthorized, "UNAUTHORIZED", "Sign in first"}

        :forbidden ->
          {:forbidden, "FORBIDDEN", "Not yours to re-render"}

        :not_found ->
          {:not_found, "NOT_FOUND", "No such file"}

        :no_file ->
          {:bad_request, "NO_FILE", "Send the picture as `image`"}

        :bad_type ->
          {:bad_request, "BAD_TYPE", "JPEG or PNG only"}

        :bad_variant ->
          {:bad_request, "BAD_VARIANT", "Writable slots: #{Enum.join(@writable, ", ")}"}

        :too_large ->
          {:request_entity_too_large, "TOO_LARGE", "That is larger than a burn gets"}

        _ ->
          {:internal_server_error, "FAILED", "Could not store the rendering"}
      end

    conn |> put_status(status) |> json(%{error: code, message: message})
  end
end
