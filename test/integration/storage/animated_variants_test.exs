defmodule PhoenixKit.Modules.Storage.AnimatedVariantsTest do
  @moduledoc """
  An animated GIF's proportional sizes stay animated GIFs; the sizes cropped to a box,
  and a size told not to, are the first frame. The file records its frames and length,
  and is no longer offered to the image editor, which would flatten it.
  """
  use PhoenixKit.DataCase, async: false

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Bucket, Dimension, ImageEditing, ProcessFileJob, VariantSets}
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    Repo.update_all(Bucket, set: [enabled: false])
    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "anim-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{"email" => "anim-#{n}@example.com", "password" => "ValidPassword123!"})

    %{tmp: tmp, user: user, bucket: bucket}
  end

  # 300x100, a red square moving over three frames (so the colours are not shared with
  # another test: Storage deduplicates by checksum).
  defp gif!(ctx, name \\ "sig.gif") do
    path = Path.join(ctx.tmp, name)
    seed = :rand.uniform(200)

    frames =
      for i <- 0..2 do
        [
          "(",
          "-size",
          "300x100",
          "xc:rgb(#{seed},200,200)",
          "-fill",
          "red",
          "-draw",
          "rectangle #{i * 80},30 #{i * 80 + 39},69",
          "-set",
          "delay",
          "20",
          ")"
        ]
      end

    {_, 0} =
      System.cmd("convert", List.flatten(frames) ++ ["-loop", "0", "-layers", "optimize", path])

    path
  end

  defp upload!(ctx, path, ext \\ "gif") do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, ext, "sig.#{ext}") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "sig.#{ext}"}
      })

    Storage.get_file(file.uuid)
  end

  defp stored(ctx, file, name) do
    instance = Storage.get_file_instance_by_name(file.uuid, name)
    {instance, Path.join(Local.root(ctx.bucket), instance.file_name)}
  end

  defp frames(path) do
    {out, 0} = System.cmd("identify", ["-format", "%n\n", path], stderr_to_stdout: true)
    out |> String.split("\n", trim: true) |> hd() |> String.to_integer()
  end

  defp size(path) do
    {out, 0} = System.cmd("identify", ["-format", "%Wx%H", path <> "[0]"], stderr_to_stdout: true)
    out
  end

  test "the file records its frames and length, and cannot be edited", ctx do
    file = upload!(ctx, gif!(ctx))

    assert %{"frames" => 3, "duration_ms" => 600} = file.metadata["animation"]
    refute ImageEditing.editable?(file)
  end

  test "sizes that keep proportions stay animated; boxes are the first frame", ctx do
    file = upload!(ctx, gif!(ctx))

    for name <- ["thumbnail", "small", "medium", "large"] do
      {instance, path} = stored(ctx, file, name)
      assert instance.mime_type == "image/gif", name
      assert instance.ext == "gif", name
      assert frames(path) == 3, name
    end

    # The thumbnail is 150 wide, the others are never enlarged past the 300 original.
    {_, thumb} = stored(ctx, file, "thumbnail")
    assert size(thumb) == "150x50"
    {_, medium} = stored(ctx, file, "medium")
    assert size(medium) == "300x100"

    # A square is cropped, so it is one picture.
    {instance, square} = stored(ctx, file, "thumbnail_square")
    assert instance.mime_type != "image/gif"
    assert frames(square) == 1
  end

  test "a size told not to keep the animation is the first frame", ctx do
    {:ok, _} =
      Storage.update_dimension(
        Repo.one!(
          from d in Dimension,
            where: d.name == "small" and d.variant_set_uuid == ^VariantSets.default_uuid()
        ),
        %{keep_animation: false}
      )

    file = upload!(ctx, gif!(ctx))

    {instance, small} = stored(ctx, file, "small")
    refute instance.mime_type == "image/gif"
    assert frames(small) == 1
    {_, medium} = stored(ctx, file, "medium")
    assert frames(medium) == 3
  end

  test "with animated_renditions off every size is a still picture", ctx do
    Application.put_env(:phoenix_kit, :animated_renditions, false)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :animated_renditions) end)

    file = upload!(ctx, gif!(ctx))

    {instance, medium} = stored(ctx, file, "medium")
    refute instance.mime_type == "image/gif"
    assert frames(medium) == 1
  end

  test "a GIF with one frame is an ordinary picture", ctx do
    path = Path.join(ctx.tmp, "one.gif")
    {_, 0} = System.cmd("convert", ["-size", "300x100", "xc:rgb(10,20,30)", path])
    file = upload!(ctx, path)

    refute Map.has_key?(file.metadata || %{}, "animation")
    {instance, _} = stored(ctx, file, "medium")
    refute instance.mime_type == "image/gif"
  end

  test "keeping the original format with animation off and alternative WebP sizes are stills",
       ctx do
    dimension = fn name ->
      Repo.one!(
        from d in Dimension,
          where: d.name == ^name and d.variant_set_uuid == ^VariantSets.default_uuid()
      )
    end

    {:ok, _} =
      Storage.update_dimension(dimension.("small"), %{format: nil, keep_animation: false})

    {:ok, _} =
      Storage.update_dimension(dimension.("medium"), %{alternative_formats: ["webp"]})

    file = upload!(ctx, gif!(ctx))

    {instance, small} = stored(ctx, file, "small")
    assert instance.mime_type == "image/gif"
    assert frames(small) == 1

    {instance, alternative} = stored(ctx, file, "medium_webp")
    assert instance.mime_type == "image/webp"
    assert frames(alternative) == 1

    {_, medium} = stored(ctx, file, "medium")
    assert frames(medium) == 3
  end

  test "a transparent GIF with a cropped first frame records and resizes its full canvas", ctx do
    path = Path.join(ctx.tmp, "cropped.gif")
    seed = :rand.uniform(200)

    {_, 0} =
      System.cmd("convert", [
        "(",
        "-size",
        "300x100",
        "xc:none",
        "-fill",
        "rgb(#{seed},20,30)",
        "-draw",
        "rectangle 100,30 139,69",
        "-set",
        "delay",
        "20",
        ")",
        "(",
        "-size",
        "300x100",
        "xc:none",
        "-fill",
        "rgb(#{seed},20,30)",
        "-draw",
        "rectangle 120,30 159,69",
        "-set",
        "delay",
        "20",
        ")",
        "-loop",
        "0",
        "-layers",
        "optimize",
        path
      ])

    file = upload!(ctx, path)
    assert {file.width, file.height} == {300, 100}
    {instance, thumbnail} = stored(ctx, file, "thumbnail")
    assert {instance.width, instance.height} == {150, 50}
    assert size(thumbnail) == "150x50"
  end
end
