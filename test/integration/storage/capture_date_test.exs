defmodule PhoenixKit.Modules.Storage.CaptureDateIntegrationTest do
  @moduledoc """
  Capture dates recorded against real stored bytes: the backfill job dating
  files stored before V200, and `ProcessFileJob`'s write refusing to
  downgrade a date. Files are stored in a local bucket under a temp directory
  exactly as an upload stores them; with Oban in `:manual` testing mode no
  `ProcessFileJob` runs, so every stored file starts without a date — the
  state of a file uploaded before V200.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob
  alias PhoenixKit.Test.ExifFixture
  alias PhoenixKit.Users.Auth

  unless ExifFixture.available?() and System.find_executable("identify"),
    do: @moduletag(:skip)

  # `Manager` caches the enabled-bucket list in `:persistent_term`; without a
  # reset a test reads through the previous test's (already removed) bucket.
  @buckets_cache :phoenix_kit_buckets_cache

  @exif %{date_time_original: "2018:07:31 23:04:05", offset_time_original: "-07:00"}

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_capture_date_#{n}")
    sources = Path.join(System.tmp_dir!(), "pk_capture_date_src_#{n}")
    File.mkdir_p!(sources)

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "capture-date-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "capture-date-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm_rf(sources)
    end)

    %{user: user, sources: sources}
  end

  # Stores a JPEG carrying `tags` under the upload name `name`.
  defp store_jpeg!(ctx, name, tags \\ %{}) do
    path = Path.join(ctx.sources, "#{System.unique_integer([:positive])}.jpg")
    ExifFixture.write_jpeg!(path, tags)
    store!(ctx.user, path, "image", "jpg", name)
  end

  defp store!(user, path, file_type, ext, name) do
    checksum = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)
    {:ok, file} = Storage.store_file_in_buckets(path, file_type, user.uuid, checksum, ext, name)
    file
  end

  defp reload(file), do: Repo.get!(StorageFile, file.uuid)

  defp set!(file, fields) do
    {1, _} = Repo.update_all(from(f in StorageFile, where: f.uuid == ^file.uuid), set: fields)
    reload(file)
  end

  describe "CaptureDateBackfillJob.record/1" do
    test "dates a stored photo from its EXIF", ctx do
      file = store_jpeg!(ctx, "holiday.jpg", @exif)
      assert file.taken_at == nil

      assert CaptureDateBackfillJob.record(file.uuid) == :ok

      assert %{
               taken_at: ~U[2018-08-01 06:04:05Z],
               taken_on: ~D[2018-07-31],
               taken_at_offset: -25_200,
               taken_at_source: "exif"
             } = reload(file)
    end

    test "without EXIF, from the date in the file name", ctx do
      file = store_jpeg!(ctx, "IMG_20180701_120000.jpg")

      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "filename", taken_on: ~D[2018-07-01]} = reload(file)
    end

    test "never touches a date set by hand", ctx do
      file =
        ctx
        |> store_jpeg!("holiday.jpg", @exif)
        |> set!(
          taken_at: ~U[2001-01-01 12:00:00Z],
          taken_on: ~D[2001-01-01],
          taken_at_source: "manual"
        )

      assert CaptureDateBackfillJob.record(file.uuid) == :kept
      assert %{taken_on: ~D[2001-01-01], taken_at_source: "manual"} = reload(file)
    end

    test "dates an edited image from its unedited backup, not its edited bytes", ctx do
      # An edit keeps only the ICC profile, so the file's own bytes carry no
      # EXIF; the date is still in the unedited original it points at.
      edited = store_jpeg!(ctx, "holiday.jpg")

      backup =
        ctx
        |> store_jpeg!("unedited-original", @exif)
        |> set!(system_managed: true, parent_file_uuid: edited.uuid)

      edited = set!(edited, original_file_uuid: backup.uuid)

      assert CaptureDateBackfillJob.record(edited.uuid) == :ok
      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(edited)
    end

    test "a file whose bytes are gone is still dated, from its name", ctx do
      file = store_jpeg!(ctx, "IMG_20180701_120000.jpg")

      {_, _} =
        Repo.delete_all(
          from(i in PhoenixKit.Modules.Storage.FileInstance, where: i.file_uuid == ^file.uuid)
        )

      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "filename"} = reload(file)
    end

    test "a file that no longer exists is :gone" do
      assert CaptureDateBackfillJob.record(UUIDv7.generate()) == :gone
    end
  end

  describe "a pass" do
    test "run_pass/1 dates every image once, skipping backups and documents", ctx do
      a = store_jpeg!(ctx, "a.jpg", @exif)
      b = store_jpeg!(ctx, "IMG_20180701_120000.jpg")
      c = store_jpeg!(ctx, "c.jpg")

      _backup =
        ctx |> store_jpeg!("b.jpg", @exif) |> set!(system_managed: true, parent_file_uuid: a.uuid)

      pdf = Path.join(ctx.sources, "doc.pdf")
      File.write!(pdf, "%PDF-1.4 not really")
      document = store!(ctx.user, pdf, "document", "pdf", "IMG_20180701_120000.pdf")

      assert CaptureDateBackfillJob.pending_count() == 3

      parent = self()
      totals = CaptureDateBackfillJob.run_pass(&send(parent, {:progress, &1}))

      assert totals == %{ok: 3}
      assert_received {:progress, %{ok: 3}}
      assert CaptureDateBackfillJob.pending_count() == 0

      assert reload(a).taken_at_source == "exif"
      assert reload(b).taken_at_source == "filename"
      assert reload(c).taken_at_source == "inserted_at"
      assert reload(document).taken_at == nil
    end

    test "a re-run keeps every date it already recorded", ctx do
      file = store_jpeg!(ctx, "holiday.jpg", @exif)
      assert CaptureDateBackfillJob.run_pass() == %{ok: 1}

      # Nothing is pending any more; recording the file again rewrites the
      # same EXIF date (an equal source may replace an equal one).
      assert CaptureDateBackfillJob.run_pass() == %{}
      assert CaptureDateBackfillJob.record(file.uuid) == :ok
      assert %{taken_at_source: "exif", taken_on: ~D[2018-07-31]} = reload(file)
    end

    test "only one pass is queued at a time" do
      assert {:ok, %Oban.Job{conflict?: false}} = CaptureDateBackfillJob.enqueue()
      assert {:ok, %Oban.Job{conflict?: true}} = CaptureDateBackfillJob.enqueue()
    end

    test "a batch that reaches the end does not enqueue a successor", ctx do
      store_jpeg!(ctx, "holiday.jpg", @exif)

      assert CaptureDateBackfillJob.perform(%Oban.Job{args: %{}}) == :ok

      assert Repo.aggregate(
               from(j in "oban_jobs",
                 where: j.worker == "PhoenixKit.Modules.Storage.Workers.CaptureDateBackfillJob"
               ),
               :count
             ) == 0
    end
  end

  describe "ProcessFileJob.update_file_with_metadata/3" do
    test "never downgrades an EXIF date to a weaker one", ctx do
      file =
        ctx
        |> store_jpeg!("IMG_20200101_120000.jpg")
        |> set!(
          taken_at: ~U[2018-08-01 06:04:05Z],
          taken_on: ~D[2018-07-31],
          taken_at_offset: -25_200,
          taken_at_source: "exif"
        )

      source = Storage.get_file_instance_by_name(file.uuid, "original").file_name

      weaker = %{
        width: 64,
        height: 48,
        taken_at: ~U[2020-01-01 12:00:00Z],
        taken_on: ~D[2020-01-01],
        taken_at_offset: nil,
        taken_at_source: "filename"
      }

      assert ProcessFileJob.update_file_with_metadata(file, source, weaker) == :ok

      # The dimensions are written; the date is left as it was.
      assert %{width: 64, taken_on: ~D[2018-07-31], taken_at_source: "exif"} = reload(file)
    end

    test "records a date on a file that has none", ctx do
      file = store_jpeg!(ctx, "holiday.jpg")
      source = Storage.get_file_instance_by_name(file.uuid, "original").file_name

      attrs = %{
        taken_at: ~U[2018-08-01 06:04:05Z],
        taken_on: ~D[2018-07-31],
        taken_at_offset: -25_200,
        taken_at_source: "exif"
      }

      assert ProcessFileJob.update_file_with_metadata(file, source, attrs) == :ok
      assert %{taken_on: ~D[2018-07-31], taken_at_source: "exif", status: "active"} = reload(file)
    end
  end
end
