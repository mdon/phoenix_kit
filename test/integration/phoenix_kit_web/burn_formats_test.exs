defmodule PhoenixKitWeb.BurnFormatsTest do
  @moduledoc """
  The burn endpoint end to end, by what the stored picture is (review of
  PR #935): a photo burns as WebP, a see-through picture as a PNG, an animated
  GIF as a GIF that still plays with the markup drawn on every frame — and an
  old JPEG burn is replaced, not left behind next to the new one.
  """

  use PhoenixKit.DataCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Conn, only: [assign: 3]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.AnnotationBurnController, as: Burn

  @buckets_cache :phoenix_kit_buckets_cache

  @moduletag :tmp_dir

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup %{tmp_dir: tmp_dir} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(tmp_dir, "bucket")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "burn-formats-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "burn-formats-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{owner: owner}
  end

  defp convert!(args), do: {_, 0} = System.cmd("convert", args, stderr_to_stdout: true)

  # A real picture of the given kind, stored as a file with its original.
  defp store!(ctx, ext, mime) do
    path = Path.join(ctx.tmp_dir, "source.#{ext}")
    # Storage keys are content-addressed and shared between tests; bytes of
    # its own keep this test's objects its own.
    unique = ["-set", "comment", "burn-formats-#{System.unique_integer([:positive])}"]

    case ext do
      "gif" ->
        frames =
          for i <- 0..2 do
            ["(", "-size", "120x60", "xc:white", "-fill", "red"] ++
              ["-draw", "rectangle #{i * 30},20 #{i * 30 + 19},39", "-set", "delay", "10", ")"]
          end

        convert!(List.flatten(frames) ++ unique ++ ["-loop", "0", "-layers", "optimize", path])

      _ ->
        convert!(
          ~w[-size 120x60 xc:white -fill red -draw] ++
            ["rectangle 10,20 29,39"] ++ unique ++ [path]
        )
    end

    checksum = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.owner.uuid, checksum, ext, "photo.#{ext}")

    # `store_file_in_buckets` takes the type from the extension; say what it is.
    assert file.mime_type == mime
    file
  end

  # What the browser sends: the markup alone for a GIF, the whole picture
  # otherwise. Here a 120x60 canvas with a blue square, for both.
  defp markup!(ctx, ext) do
    path = Path.join(ctx.tmp_dir, "burn.#{ext}")

    case ext do
      "jpg" ->
        convert!(~w[-size 120x60 xc:white -fill blue -draw] ++ ["rectangle 0,0 9,9", path])

      _ ->
        convert!(~w[-size 120x60 xc:none -fill blue -draw] ++ ["rectangle 0,0 9,9", path])
    end

    %Plug.Upload{path: path, filename: "burn.#{ext}", content_type: "image/#{ext}"}
  end

  defp burn(ctx, file, upload, extra \\ %{}) do
    params =
      Map.merge(
        %{"file_uuid" => file.uuid, "image" => upload, "variants" => "burned"},
        extra
      )

    build_conn()
    |> assign(:phoenix_kit_current_user, ctx.owner)
    |> Burn.create(params)
  end

  # The instance row and the stored bytes, read back through the buckets the
  # way the file route does.
  defp stored(file, variant) do
    instance = Storage.get_file_instance_by_name(file.uuid, variant)
    {:ok, path} = Storage.Manager.retrieve_file(instance.file_name)
    {instance, path}
  end

  defp frames(path) do
    {out, 0} = System.cmd("identify", ["-format", "%n\n", path])
    out |> String.split("\n", trim: true) |> hd() |> String.to_integer()
  end

  test "a photo burns as WebP", ctx do
    file = store!(ctx, "jpg", "image/jpeg")

    conn = burn(ctx, file, markup!(ctx, "jpg"))

    assert %{"written" => [%{"variant" => "burned"}]} =
             Phoenix.json_library().decode!(conn.resp_body)

    {instance, path} = stored(file, "burned")
    assert instance.ext == "webp"
    assert instance.mime_type == "image/webp"
    assert {"WEBP\n", 0} = System.cmd("identify", ["-format", "%m\n", path])
  end

  test "a later burn of another kind replaces the old copy instead of keeping both", ctx do
    file = store!(ctx, "jpg", "image/jpeg")

    # An old JPEG burn, as the endpoint wrote them before WebP.
    jpeg = Path.join(ctx.tmp_dir, "old.jpg")
    convert!(~w[-size 120x60 xc:white] ++ [jpeg])

    {:ok, _} =
      VariantGenerator.store_prepared_variant(
        file,
        "burned",
        jpeg,
        "jpg",
        "image/jpeg"
      )

    assert {%{ext: "jpg"}, _} = stored(file, "burned")

    burn(ctx, file, markup!(ctx, "jpg"))

    {instance, _} = stored(file, "burned")
    assert instance.ext == "webp"

    rows =
      Repo.all(
        from(i in Storage.FileInstance,
          where: i.file_uuid == ^file.uuid and i.variant_name == "burned"
        )
      )

    assert [_one] = rows
  end

  test "an animated GIF stays a GIF that plays, with the markup on every frame", ctx do
    file = store!(ctx, "gif", "image/gif")

    layout = %{
      "canvas_w" => "120",
      "canvas_h" => "60",
      "picture_x" => "0",
      "picture_y" => "0",
      "picture_w" => "120",
      "picture_h" => "60"
    }

    conn = burn(ctx, file, markup!(ctx, "png"), layout)
    assert conn.status in [nil, 200]

    {instance, path} = stored(file, "burned")
    assert instance.ext == "gif"
    assert instance.mime_type == "image/gif"
    assert frames(path) == 3

    {out, 0} =
      System.cmd("convert", [
        path,
        "-coalesce",
        "-format",
        "%[fx:round(255*p{5,5}.b)],%[fx:round(255*p{5,5}.r)]\n",
        "info:"
      ])

    # Blue (b=255, r=0) on each of the three frames.
    assert String.split(out, "\n", trim: true) == List.duplicate("255,0", 3)
  end

  test "an animated GIF burned without a layout is kept as the still it is", ctx do
    file = store!(ctx, "gif", "image/gif")

    burn(ctx, file, markup!(ctx, "png"))

    {instance, path} = stored(file, "burned")
    assert instance.ext == "png"
    assert frames(path) == 1
  end

  test "a forged layout does not crash the request", ctx do
    file = store!(ctx, "gif", "image/gif")

    conn =
      burn(ctx, file, markup!(ctx, "png"), %{
        "canvas_w" => %{"a" => "1"},
        "canvas_h" => "60",
        "picture_x" => "0",
        "picture_y" => "0",
        "picture_w" => "120",
        "picture_h" => "60"
      })

    # No usable layout: the still fallback, not a 500.
    assert conn.status in [nil, 200]
    assert {%{ext: "png"}, _} = stored(file, "burned")
  end
end
