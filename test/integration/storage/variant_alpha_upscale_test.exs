defmodule PhoenixKit.Modules.Storage.VariantAlphaUpscaleTest do
  @moduledoc """
  Pipeline 2 of the size rules: a see-through image's JPEG sizes are written
  as PNG (its transparency would otherwise come out black), and a size is
  never larger than the original. Skipped where ImageMagick is missing.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    ImageProcessor,
    Libraries,
    ProcessFileJob,
    Profiles,
    VariantSets
  }

  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_variant_alpha_#{n}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "variant-alpha-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, profile} = Profiles.create_profile(%{name: "Alpha #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, set} = VariantSets.create_variant_set(%{name: "Alpha #{n}"})
    {:ok, library} = Libraries.create_system_library(%{name: "Alpha #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "variant-alpha-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{set: set, library: library, user: user, dir: root}
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp upload!(ctx, convert_args) do
    src = Path.join(ctx.dir, "src")
    File.mkdir_p!(src)
    path = Path.join(src, "p#{System.unique_integer([:positive])}.png")
    {_, 0} = System.cmd("convert", convert_args ++ ["png:" <> path], stderr_to_stdout: true)
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "p.png",
        library_uuid: ctx.library.uuid
      )

    :ok =
      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.png"}})

    Storage.get_file(file.uuid)
  end

  defp size!(ctx, attrs) do
    {:ok, d} = Storage.create_dimension(Map.merge(%{applies_to: "image"}, attrs), ctx.set.uuid)
    d
  end

  test "a JPEG size of a see-through image is written as PNG, transparency kept", ctx do
    if imagemagick?() do
      size!(ctx, %{name: "card", width: 64, quality: 80, format: "jpg"})

      file =
        upload!(ctx, [
          "-size",
          "200x100",
          "xc:none",
          "-fill",
          "red",
          "-draw",
          "circle 50,50 50,10"
        ])

      card = Storage.get_file_instance_by_name(file.uuid, "card")
      assert card.mime_type == "image/png"
      assert card.ext == "png"
      assert String.ends_with?(card.file_name, ".png")
    end
  end

  test "an opaque image's JPEG size stays JPEG", ctx do
    if imagemagick?() do
      size!(ctx, %{name: "card", width: 64, quality: 80, format: "jpg"})
      file = upload!(ctx, ["-size", "200x100", "xc:red"])

      card = Storage.get_file_instance_by_name(file.uuid, "card")
      assert card.mime_type == "image/jpeg"
    end
  end

  test "a size wider than the original is not upscaled", ctx do
    if imagemagick?() do
      size!(ctx, %{name: "huge", width: 1920, quality: 80, format: "png"})
      file = upload!(ctx, ["-size", "300x150", "xc:blue"])

      huge = Storage.get_file_instance_by_name(file.uuid, "huge")
      assert huge.width == 300
    end
  end

  test "a crop box larger than the original shrinks to fit, keeping its shape" do
    assert ImageProcessor.cap_to_original({400, 400}, {300, 150}) == {150, 150}
    assert ImageProcessor.cap_to_original({100, 50}, {300, 150}) == {100, 50}
  end

  test "remake_all marks every set's files stale" do
    before = VariantSets.list_variant_sets() |> Map.new(&{&1.uuid, &1.revision})
    :ok = VariantSets.remake_all()

    for set <- VariantSets.list_variant_sets(), Map.has_key?(before, set.uuid) do
      assert set.revision == before[set.uuid] + 1
    end
  end
end
