defmodule PhoenixKit.Modules.Storage.VariantTempCleanupTest do
  @moduledoc """
  A variant that cannot be rendered must not leave its temp files behind.

  The downloaded original and the render target were only removed on the
  success path. A file ImageMagick cannot decode (an SVG on a host without
  an SVG delegate) fails every attempt, and each request for the missing
  variant re-queues `ProcessFileJob` — a host collected over a thousand
  stray `phoenix_kit_*.svg` copies in the temp dir within two days.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Dimension
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Users.Auth

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_variant_cleanup_#{n}")
    bucket_root = Path.join(root, "bucket")
    # The temp dir the code under test writes to — private to this test, so
    # what is left in it is this test's doing alone.
    work_dir = Path.join(root, "tmp")
    File.mkdir_p!(work_dir)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "variant-cleanup-test-#{n}",
        provider: "local",
        endpoint: bucket_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "variant-cleanup-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    source = Path.join(root, "broken.svg")
    File.write!(source, "not an image #{n}")
    checksum = :sha256 |> :crypto.hash(File.read!(source)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "image", user.uuid, checksum, "svg", "broken.svg")

    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", work_dir)

    on_exit(fn ->
      if previous_tmpdir,
        do: System.put_env("TMPDIR", previous_tmpdir),
        else: System.delete_env("TMPDIR")

      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    %{stored: file, work_dir: work_dir}
  end

  test "a failed variant leaves nothing in the temp dir", %{stored: file, work_dir: work_dir} do
    dimension = %Dimension{
      name: "thumbnail",
      width: 150,
      height: 150,
      quality: 85,
      format: "jpg",
      applies_to: "image"
    }

    assert {:error, _reason} = VariantGenerator.generate_variant(file, dimension)
    assert File.ls!(work_dir) == []
  end
end
