defmodule PhoenixKit.Modules.Storage.VariantSetGenerationTest do
  @moduledoc """
  Variants follow the variant set (V205, step 4): an upload gets its
  library's set's sizes, each recorded with the spec hash of the size that
  made it, and the file records the set it was made by; a set that makes
  no sizes makes none; a size change bumps the set's revision (a reorder
  does not); the standard sizes cannot be deleted or renamed and
  small/medium/large keep the aspect ratio; a missing size stands in as the
  nearest smaller one or a placeholder, never a full original; and
  `variant_for/2` picks a size by purpose.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Dimension,
    FileInstance,
    Libraries,
    ProcessFileJob,
    Profiles,
    VariantSets
  }

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_variant_sets_#{n}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "variant-sets-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, profile} = Profiles.create_profile(%{name: "Variant sets #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, set} = VariantSets.create_variant_set(%{name: "Photos #{n}"})
    {:ok, library} = Libraries.create_system_library(%{name: "Photos #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "variant-sets-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{set: set, library: library, user: user, dir: root}
  end

  defp image!(dir, name, width) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd("convert", ["-size", "#{width}x#{div(width, 2)}", "xc:red", path],
        stderr_to_stdout: true
      )

    path
  end

  defp upload!(ctx, width \\ 400) do
    path = image!(Path.join(ctx.dir, "src"), "p#{System.unique_integer([:positive])}.png", width)
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "p.png",
        library_uuid: ctx.library.uuid
      )

    :ok =
      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.png"}})

    Storage.get_file(file.uuid)
  end

  defp names(file), do: file.uuid |> Storage.list_file_instances() |> Enum.map(& &1.variant_name)

  describe "generation" do
    test "an upload gets its library's set's sizes, each with its spec hash", ctx do
      {:ok, grid} =
        Storage.create_dimension(
          %{name: "grid_2x", width: 64, quality: 80, applies_to: "image", format: "jpg"},
          ctx.set.uuid
        )

      file = upload!(ctx)

      assert "grid_2x" in names(file)
      assert "thumbnail" in names(file)

      instance = Storage.get_file_instance_by_name(file.uuid, "grid_2x")
      assert instance.spec_hash == VariantSets.spec_hash(grid)
      assert Storage.get_file_instance_by_name(file.uuid, "original").spec_hash == nil

      set = VariantSets.get_variant_set(ctx.set.uuid)
      assert file.placed_variant_set_uuid == set.uuid
      assert file.placed_variant_revision == set.revision
    end

    test "a size of another set is not made", ctx do
      {:ok, _} =
        Storage.create_dimension(%{
          name: "default_only",
          width: 32,
          quality: 80,
          applies_to: "image"
        })

      refute "default_only" in names(upload!(ctx))
    end

    test "a set that makes no sizes makes none, and the file is up to date", ctx do
      {:ok, set} = VariantSets.update_variant_set(ctx.set, %{generate_variants: false})
      file = upload!(ctx)

      assert names(file) == ["original"]

      assert {file.placed_variant_set_uuid, file.placed_variant_revision} ==
               {set.uuid, set.revision}
    end
  end

  describe "revisions" do
    test "a size change bumps its set's revision; a reorder does not", ctx do
      revision = fn -> VariantSets.get_variant_set(ctx.set.uuid).revision end
      start = revision.()

      {:ok, size} =
        Storage.create_dimension(
          %{name: "extra", width: 50, quality: 80, applies_to: "image"},
          ctx.set.uuid
        )

      assert revision.() == start + 1

      {:ok, size} = Storage.update_dimension(size, %{order: 42})
      assert revision.() == start + 1

      {:ok, size} = Storage.update_dimension(size, %{width: 60})
      assert revision.() == start + 2

      {:ok, _} = Storage.delete_dimension(size)
      assert revision.() == start + 3
    end
  end

  describe "standard sizes" do
    test "cannot be deleted or renamed", ctx do
      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)

      assert {:error, :standard_slot} = Storage.delete_dimension(thumbnail)
      assert {:error, changeset} = Storage.update_dimension(thumbnail, %{name: "thumb"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "small, medium and large keep the aspect ratio; thumbnail may be cropped", ctx do
      small = Storage.get_dimension_by_name("small", ctx.set.uuid)
      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)

      assert {:error, changeset} =
               Storage.update_dimension(small, %{maintain_aspect_ratio: false, height: 300})

      assert %{maintain_aspect_ratio: [_]} = errors_on(changeset)

      assert {:ok, _} =
               Storage.update_dimension(thumbnail, %{maintain_aspect_ratio: false, height: 150})
    end

    test "a custom size may be deleted", ctx do
      {:ok, size} =
        Storage.create_dimension(
          %{name: "custom", width: 50, quality: 80, applies_to: "image"},
          ctx.set.uuid
        )

      assert {:ok, _} = Storage.delete_dimension(size)
    end
  end

  describe "a missing size (G17)" do
    defp instance(variant, width, extra \\ %{}) do
      struct(
        FileInstance,
        Map.merge(
          %{variant_name: variant, width: width, mime_type: "image/jpeg", spec_hash: "x"},
          extra
        )
      )
    end

    defp file(ctx, width),
      do: %Storage.File{library_uuid: ctx.library.uuid, file_type: "image", width: width}

    test "stands in as the nearest smaller size the file has", ctx do
      instances = [instance("thumbnail", 150), instance("small", 300), instance("large", 1920)]

      assert {:instance, %{variant_name: "small"}} =
               VariantSets.stand_in(file(ctx, 4000), "medium", instances)
    end

    test "a render or annotation is never a stand-in", ctx do
      instances = [instance("thumbnail_annotated", 150, %{spec_hash: nil})]
      assert :placeholder = VariantSets.stand_in(file(ctx, 4000), "medium", instances)
    end

    test "with nothing smaller, a placeholder, unless the original is no larger", ctx do
      assert :placeholder = VariantSets.stand_in(file(ctx, 4000), "thumbnail", [])
      assert :original = VariantSets.stand_in(file(ctx, 100), "thumbnail", [])
    end

    test "a name that is not an image size gets the original, as before", ctx do
      assert :original = VariantSets.stand_in(file(ctx, 4000), "not_a_size", [])
      assert :original = VariantSets.stand_in(file(ctx, 4000), "original", [])
    end

    test "the controller serves the stand-in or asks for the placeholder", ctx do
      {:ok, set} = VariantSets.update_variant_set(ctx.set, %{generate_variants: false})
      assert set.generate_variants == false
      file = upload!(ctx, 1200)

      # Nothing is coming while the set makes no sizes: the original, as before.
      assert {:ok, %{variant_name: "original"}, :pending} =
               FileController.get_file_instance(file.uuid, "thumbnail")

      {:ok, _} = VariantSets.update_variant_set(set, %{generate_variants: true})
      assert {:error, :placeholder} = FileController.get_file_instance(file.uuid, "thumbnail")

      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)
      {:ok, _} = Storage.VariantGenerator.generate_variant(Storage.get_file(file.uuid), thumbnail)

      assert {:ok, %{variant_name: "thumbnail"}, :pending} =
               FileController.get_file_instance(file.uuid, "medium")
    end
  end

  describe "variant_for/2" do
    test "the narrowest size at least as wide as asked, of the right aspect", ctx do
      {:ok, _} =
        Storage.create_dimension(
          %{
            name: "square_400",
            width: 400,
            height: 400,
            maintain_aspect_ratio: false,
            quality: 80,
            applies_to: "image"
          },
          ctx.set.uuid
        )

      file = %Storage.File{library_uuid: ctx.library.uuid, file_type: "image"}
      widths = Map.new(VariantSets.list_dimensions(ctx.set.uuid), &{&1.name, &1.width})

      preserve = Storage.variant_for(file, min_width: 350, aspect: :preserve)
      assert widths[preserve] >= 350
      assert Storage.get_dimension_by_name(preserve, ctx.set.uuid).maintain_aspect_ratio

      assert Storage.variant_for(file, min_width: 350, aspect: :crop) == "square_400"
      assert Storage.variant_for(file, min_width: 100_000) == "large"
    end

    test "a file whose set has no fitting size gets the original", ctx do
      file = %Storage.File{library_uuid: ctx.library.uuid, file_type: "image"}
      assert Storage.variant_for(file, aspect: :crop, min_width: 100_000) == "original"
    end
  end

  test "Dimension knows the standard sizes" do
    assert Dimension.standard_slot?(%Dimension{name: "video_thumbnail"})
    refute Dimension.standard_slot?(%Dimension{name: "grid_2x"})
  end
end
