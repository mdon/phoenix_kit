defmodule PhoenixKit.Modules.Storage.RetrieveFileExtensionTest do
  @moduledoc """
  `Storage.retrieve_file/1` copies the stored original to a temp path that
  keeps its extension. ImageMagick identifies some formats — ICO among them —
  by extension alone, so an extensionless copy made `ProcessFileJob` fail
  every variant of an `.ico` upload with "no decode delegate for this image
  format".
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Users.Auth

  # `Manager` caches the enabled-bucket list in `:persistent_term`; without a
  # reset a test reads through the previous test's (already removed) bucket.
  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_retrieve_ext_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "retrieve-ext-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    # `store_file_in_buckets/6` queues `ProcessFileJob` via `Oban.insert/3`;
    # `:manual` testing only inserts the row.
    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "retrieve-ext-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    source = Path.join(System.tmp_dir!(), "pk_retrieve_ext_source_#{n}.ico")

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm(source)
    end)

    %{user: user, source: source}
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp store!(user, source) do
    checksum = :sha256 |> :crypto.hash(File.read!(source)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(source, "image", user.uuid, checksum, "ico", "favicon.ico")

    file
  end

  test "the temp copy keeps the stored original's extension", %{user: user, source: source} do
    File.write!(source, "icon bytes #{System.unique_integer()}")
    file = store!(user, source)

    assert {:ok, path, _file} = Storage.retrieve_file(file.uuid)
    on_exit(fn -> File.rm(path) end)

    assert Path.extname(path) == ".ico"
    assert File.read!(path) == File.read!(source)
  end

  @tag :integration
  test "ImageMagick identifies an ICO from the temp copy", %{user: user, source: source} do
    if imagemagick?() do
      {_, 0} = System.cmd("convert", ["-size", "32x32", "xc:red", source], stderr_to_stdout: true)
      file = store!(user, source)

      assert {:ok, path, _file} = Storage.retrieve_file(file.uuid)
      on_exit(fn -> File.rm(path) end)

      assert {"ICO", 0} =
               System.cmd("identify", ["-format", "%m", path <> "[0]"], stderr_to_stdout: true)
    end
  end
end
