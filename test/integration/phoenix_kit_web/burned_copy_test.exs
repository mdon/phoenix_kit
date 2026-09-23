defmodule PhoenixKitWeb.BurnedCopyTest do
  @moduledoc """
  The burned copy the media viewer opens with (review of PR #853):

    * the viewer finds the burn under the names the burn endpoint WRITES —
      #853 looked it up as `annotated`, which nothing writes, so the viewer
      never opened on it;
    * recording the fingerprint merges into `metadata` as it is now, instead
      of writing back the map loaded before a seconds-long burn;
    * a fingerprint is handed back only while a burn is stored, so an image
      edit (which deletes every variant) does not stop the next burn;
    * `burn_stored` builds the canvas from the stored instance, never from a
      URL the client sends.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.AnnotationBurnController, as: Burn
  alias PhoenixKitWeb.Components.MediaBrowser
  alias PhoenixKitWeb.Components.MediaCanvasViewer

  @buckets_cache :phoenix_kit_buckets_cache

  setup do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    tmp_root = Path.join(System.tmp_dir!(), "pk_burned_copy_#{n}")
    source = Path.join(System.tmp_dir!(), "pk_burned_copy_src_#{n}.jpg")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "burned-copy-test-#{n}",
        provider: "local",
        endpoint: tmp_root,
        enabled: true,
        priority: 0
      })

    start_supervised!(
      {Oban, name: Oban, repo: PhoenixKit.Test.Repo, testing: :manual, queues: [], plugins: []}
    )

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(tmp_root)
      File.rm(source)
    end)

    {:ok, owner} =
      Auth.register_user(%{
        "email" => "burned-copy-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    File.write!(source, "picture bytes #{n}")
    checksum = :sha256 |> :crypto.hash(File.read!(source)) |> Base.encode16(case: :lower)

    {:ok, stored} =
      Storage.store_file_in_buckets(source, "image", owner.uuid, checksum, "jpg", "photo.jpg")

    %{stored: stored}
  end

  # A stored burn: an instance row under `variant`, as `store_prepared_variant`
  # leaves one. The bytes are not read by anything under test.
  defp add_burn!(file, variant, {w, h}) do
    {:ok, instance} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: variant,
        file_name: "#{file.uuid}_#{variant}.jpg",
        mime_type: "image/jpeg",
        ext: "jpg",
        checksum: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
        size: 1234,
        width: w,
        height: h,
        processing_status: "completed"
      })

    instance
  end

  defp instances(file),
    do: Repo.all(from(i in Storage.FileInstance, where: i.file_uuid == ^file.uuid))

  # The file map `MediaBrowser` hands the viewer: urls keyed by variant name,
  # exactly as `generate_urls_from_instances/4` builds them.
  defp viewer_file(file) do
    instances = instances(file)

    %{
      file_uuid: file.uuid,
      urls: Map.new(instances, &{&1.variant_name, "/file/#{file.uuid}/#{&1.variant_name}/t"}),
      burn_size: MediaBrowser.burn_size(instances),
      burn_fingerprint: MediaBrowser.burn_fingerprint(Repo.reload!(file), instances)
    }
  end

  describe "the viewer finds the burn the endpoint wrote" do
    test "a stored `burned_large` is the copy the viewer opens with", %{stored: file} do
      add_burn!(file, "burned", {800, 450})
      add_burn!(file, "burned_large", {1920, 1080})

      viewer = viewer_file(file)

      assert viewer.burn_size == %{variant: "burned_large", w: 1920, h: 1080}
      assert MediaCanvasViewer.burned?(viewer)
      assert MediaBrowser.viewer_open_url(viewer) == viewer.urls["burned_large"]
    end

    test "a card-sized `burned` alone is still opened with", %{stored: file} do
      add_burn!(file, "burned", {800, 450})

      viewer = viewer_file(file)

      assert viewer.burn_size == %{variant: "burned", w: 800, h: 450}
      assert MediaCanvasViewer.burned?(viewer)
    end

    test "no burn, no burned view", %{stored: file} do
      viewer = viewer_file(file)

      assert viewer.burn_size == nil
      refute MediaCanvasViewer.burned?(viewer)
      assert MediaBrowser.viewer_open_url(viewer) == viewer.urls["small"]
    end
  end

  describe "recording the fingerprint" do
    test "keeps what changed in metadata while the burn ran", %{stored: file} do
      # The struct the burn request loaded at its start...
      loaded = Repo.get!(StorageFile, file.uuid)

      # ...then, while it composes and uploads, the user rotates the picture.
      {:ok, _} = Storage.update_file_metadata(file, &Map.put(&1, "rotation", 90))

      :ok = Burn.remember_fingerprint(loaded, "a1b2c3d4")

      metadata = Repo.get!(StorageFile, file.uuid).metadata
      assert metadata["rotation"] == 90
      assert metadata["burn"]["fingerprint"] == "a1b2c3d4"
    end

    test "is not handed back once the burn it described is gone", %{stored: file} do
      :ok = Burn.remember_fingerprint(file, "a1b2c3d4")
      burn = add_burn!(file, "burned_large", {1920, 1080})

      assert viewer_file(file).burn_fingerprint == "a1b2c3d4"

      # An image edit deletes every variant of the file, the burns included,
      # but leaves `metadata["burn"]`. Handing it back would tell the client
      # its unchanged drawing is already burned, and no burn would ever be
      # made again.
      Repo.delete!(burn)

      assert viewer_file(file).burn_fingerprint == nil
    end
  end

  describe "burn_stored" do
    defp socket(file) do
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, file: %{file_uuid: file.uuid}}}
    end

    test "builds the canvas from the stored instance, not the client's URL", %{stored: file} do
      instance = add_burn!(file, "burned_large", {1920, 1080})

      {:noreply, socket} =
        MediaCanvasViewer.handle_event(
          "burn_stored",
          %{
            "variant" => "burned_large",
            "url" => "https://attacker.example/x.png",
            "width" => 1,
            "height" => 1,
            "fingerprint" => "a1b2c3d4"
          },
          socket(file)
        )

      canvas = inspect(socket.assigns.burn_canvas, limit: :infinity)
      assert canvas =~ "/file/#{file.uuid}/burned_large/"
      refute canvas =~ "attacker.example"
      assert canvas =~ "1920"

      # Versioned by the stored bytes, so a new burn always remounts the
      # `phx-update="ignore"` canvas and an identical one never needs to.
      assert socket.assigns.burn_version == URLSigner.version(instance)
    end

    test "ignores a slot that is not a burn, or one with nothing stored", %{stored: file} do
      for params <- [%{"variant" => "original"}, %{"variant" => "burned_large"}] do
        {:noreply, socket} = MediaCanvasViewer.handle_event("burn_stored", params, socket(file))
        refute Map.has_key?(socket.assigns, :burn_canvas)
      end
    end
  end

  describe "a poke while the burned copy is showing" do
    defp viewer_socket(assigns) do
      %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
    end

    defp poked_file(fingerprint, version) do
      %{
        burn_fingerprint: fingerprint,
        burn_size: %{variant: "burned_large", w: 20, h: 10},
        urls: %{"burned_large" => "/file/x/burned_large/tok?v=#{version}"}
      }
    end

    test "the burn this viewer just stored is not built again" do
      # `burn_stored` records the checksum; the poke names the fingerprint.
      # Treating those as different remounts the canvas for the same picture.
      version = "0123456789abcdef"
      socket = viewer_socket(%{burn_mode: true, burn_version: version, burn_canvas: :current})

      {:ok, updated} =
        MediaCanvasViewer.update(%{burn_refreshed: poked_file("fp-new", version)}, socket)

      assert updated.assigns.burn_canvas == :current
      assert updated.assigns.burn_version == version
    end

    test "a newer burn from someone else replaces the canvas" do
      socket =
        viewer_socket(%{burn_mode: true, burn_version: "old-fingerprint", burn_canvas: :current})

      {:ok, updated} =
        MediaCanvasViewer.update(
          %{burn_refreshed: poked_file("new-fingerprint", "fedcba9876543210")},
          socket
        )

      assert updated.assigns.burn_version == "new-fingerprint"
      assert updated.assigns.burn_canvas != :current
    end

    test "an open editor keeps the drawing on screen" do
      socket =
        viewer_socket(%{burn_mode: false, burn_version: "old-fingerprint", burn_canvas: :current})

      {:ok, updated} =
        MediaCanvasViewer.update(
          %{burn_refreshed: poked_file("new-fingerprint", "fedcba9876543210")},
          socket
        )

      assert updated.assigns.burn_canvas == :current
      assert updated.assigns.burn_version == "old-fingerprint"
    end
  end
end
