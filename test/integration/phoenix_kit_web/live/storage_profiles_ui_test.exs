defmodule PhoenixKitWeb.Live.StorageProfilesUITest do
  @moduledoc """
  The V205 editors: the Storage profiles tab of Settings → Media (profiles,
  their copy counts and bucket rows), the variant sets page (a tab per set,
  its flags, sizes created in the set, standard sizes kept), and the
  profile and set pickers of the Libraries tab.
  """

  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Profiles, VariantSets}
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    {user, _token} = create_admin_user()

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "ui-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: Path.join(System.tmp_dir!(), "pk_ui_bucket"),
        enabled: true,
        priority: 0
      })

    %{conn: log_in_user(conn, user), bucket: bucket}
  end

  defp settings(conn) do
    {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
    render_click(view, "switch_settings_tab", %{"tab" => "profiles"})
    view
  end

  describe "the Storage profiles tab" do
    test "creates a profile, adds a bucket, changes its row and deletes it", ctx do
      view = settings(ctx.conn)

      view |> element("#media-profiles button", "New profile") |> render_click()

      view
      |> form("#media-profiles-new", %{"profile" => %{"name" => "Cold storage"}})
      |> render_submit()

      profile = Enum.find(Profiles.list_profiles(), &(&1.name == "Cold storage"))
      assert profile
      assert render(view) =~ "Cold storage"

      view
      |> form("#media-profiles-add-#{profile.uuid}", %{"bucket_uuid" => ctx.bucket.uuid})
      |> render_submit()

      assert [%{bucket_uuid: bucket_uuid}] = Profiles.get_profile(profile.uuid).buckets
      assert bucket_uuid == ctx.bucket.uuid

      view
      |> form("#media-profiles-row-#{profile.uuid}-#{ctx.bucket.uuid}", %{
        "row" => %{"role" => "backup", "status" => "read_only"}
      })
      |> render_change()

      assert [%{role: "backup", status: "read_only"}] = Profiles.get_profile(profile.uuid).buckets

      view
      |> form("#media-profiles-form-#{profile.uuid}", %{
        "profile" => %{"copies_originals" => "2", "min_copies_on_write" => "2"}
      })
      |> render_submit()

      assert %{copies_originals: 2, min_copies_on_write: 2} = Profiles.get_profile(profile.uuid)

      view
      |> element("#media-profiles-#{profile.uuid} button", "Delete")
      |> render_click()

      refute Profiles.get_profile(profile.uuid)
    end

    test "the Default profile lists the buckets and cannot be deleted", ctx do
      view = settings(ctx.conn)
      default = Profiles.default_uuid()

      assert has_element?(view, "#media-profiles-#{default}-#{ctx.bucket.uuid}")
      refute has_element?(view, "#media-profiles-#{default} button", "Delete")
    end
  end

  describe "the variant sets page" do
    test "creates a set, saves its flags, and a new size lands in it", %{conn: conn} do
      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media/dimensions"))

      view
      |> form("#variant-set-new-form", %{"new_set" => %{"name" => "Photography"}})
      |> render_submit()

      set = Enum.find(VariantSets.list_variant_sets(), &(&1.name == "Photography"))
      assert set
      assert_patch(view, Routes.path("/admin/settings/media/dimensions?set=#{set.uuid}"))

      view
      |> form("#variant-set-form-#{set.uuid}", %{
        "variant_set" => %{"generate_tiles" => "true", "selectable" => "true"}
      })
      |> render_submit()

      assert %{generate_tiles: true, selectable: true} = VariantSets.get_variant_set(set.uuid)

      # The standard sizes it started with cannot be deleted from the page.
      html = render(view)
      assert html =~ "standard"
      refute html =~ ~s(phx-click="delete_dimension")

      {:ok, form_view, _html} =
        live(conn, Routes.path("/admin/settings/media/dimensions/new/image?set=#{set.uuid}"))

      form_view
      |> form("#dimension-form", %{
        "dimension" => %{"name" => "grid_2x", "width" => "480", "quality" => "80"}
      })
      |> render_submit()

      assert Storage.get_dimension_by_name("grid_2x", set.uuid)
      refute Storage.get_dimension_by_name("grid_2x")
    end
  end

  describe "the Libraries tab" do
    test "picks a library's profile and variant set", %{conn: conn} do
      {:ok, library} =
        Libraries.create_system_library(%{name: "Picked #{System.unique_integer([:positive])}"})

      {:ok, profile} = Profiles.create_profile(%{name: "Picked profile"})
      {:ok, set} = VariantSets.create_variant_set(%{name: "Picked set"})

      {:ok, view, _html} = live(conn, Routes.path("/admin/settings/media"))
      render_click(view, "switch_settings_tab", %{"tab" => "libraries"})

      view
      |> form("#media-libraries-storage-#{library.uuid}", %{
        "storage" => %{"profile" => profile.uuid, "set" => set.uuid}
      })
      |> render_change()

      library = Libraries.get_library(library.uuid)
      assert library.storage_profile_uuid == profile.uuid
      assert library.variant_set_uuid == set.uuid
    end
  end
end
