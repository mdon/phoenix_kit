defmodule PhoenixKitWeb.StorageApiAuthzTest do
  @moduledoc """
  The authorization decisions behind the storage HTTP API — the upload owner
  resolver and the file-info read guard. Both endpoints live in the
  unauthenticated `[:browser, :phoenix_kit_auto_setup]` scope, so the guard is
  the controller's own, and these functions are it (issue #687 class: an
  anonymous, attacker-controlled write / signed-URL handout).
  """
  use PhoenixKit.DataCase, async: true

  import Plug.Test, only: [conn: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.RateLimiter
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.FileController
  alias PhoenixKitWeb.UploadController

  # The first registered user is auto-promoted to Owner; seed one so the users
  # these tests build are genuinely non-privileged.
  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  defp unique_email, do: "storage_#{System.unique_integer([:positive])}@example.com"

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  # A user who holds a module permission but NOT the Owner/Admin system role.
  # `can_access_admin_area?/1` is true for them; `system_role?/1` is not — the
  # exact distinction the storage gates must honor.
  defp permission_holder_user do
    user = plain_user()
    user_role = Roles.get_role_by_name("User")
    {:ok, _} = Permissions.grant_permission(user_role.uuid, "media")
    Repo.get!(Auth.User, user.uuid)
  end

  # A user with the blanket superadmin ("*") grant — Owner-equivalent for
  # every module-access check, `has_module_access?/2` included, without
  # depending on this shared test database's actual Owner (assigning the
  # Owner role directly is refused — `Roles.assign_role/2` protects it — and
  # "first user becomes Owner" only holds for a database with no prior
  # Owner, which this shared `phoenix_kit_test` does not guarantee).
  defp superadmin_user do
    user = plain_user()
    user_role = Roles.get_role_by_name("User")
    {:ok, _} = Permissions.grant_permission(user_role.uuid, Permissions.superadmin_key())
    Repo.get!(Auth.User, user.uuid)
  end

  defp make_file(owner_uuid) do
    checksum = "cs_#{System.unique_integer([:positive])}"

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "photo.jpg",
        file_name: "photo.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: checksum,
        user_file_checksum: "u_#{checksum}",
        size: 1234,
        status: "active",
        user_uuid: owner_uuid
      })

    file
  end

  defp trashed_file(owner_uuid) do
    {:ok, file} = owner_uuid |> make_file() |> Storage.trash_file()
    file
  end

  defp system_managed_file(owner_uuid) do
    {:ok, file} =
      owner_uuid
      |> make_file()
      |> Ecto.Changeset.change(system_managed: true, status: "trashed")
      |> Repo.update()

    file
  end

  defp conn_for(user) do
    conn(:get, "/") |> Plug.Conn.assign(:phoenix_kit_current_user, user)
  end

  describe "UploadController.resolve_upload_user/2 — the anonymous-write hole" do
    test "an unauthenticated request is refused, even with a user_uuid param" do
      assert {:error, :no_user} =
               UploadController.resolve_upload_user(nil, %{"user_uuid" => "any-victim-uuid"})
    end

    test "an authenticated non-admin is attributed to themselves, override ignored" do
      user = plain_user()

      assert {:ok, uuid} =
               UploadController.resolve_upload_user(user, %{"user_uuid" => "someone-else"})

      assert uuid == user.uuid
    end

    test "an authenticated non-admin with no override is attributed to themselves" do
      user = plain_user()
      assert {:ok, uuid} = UploadController.resolve_upload_user(user, %{})
      assert uuid == user.uuid
    end

    test "an authenticated admin may override the owner" do
      admin = admin_user()

      assert {:ok, "target-uuid"} =
               UploadController.resolve_upload_user(admin, %{"user_uuid" => "target-uuid"})
    end

    test "a mere permission holder (not Owner/Admin) cannot override the owner" do
      user = permission_holder_user()

      # Proves this is the middle case: the broad `can_access_admin_area?/1`
      # predicate would have let them through — `system_role?/1` does not.
      assert Scope.can_access_admin_area?(Scope.for_user(user))
      refute Scope.system_role?(Scope.for_user(user))

      assert {:ok, uuid} =
               UploadController.resolve_upload_user(user, %{"user_uuid" => "someone-else"})

      assert uuid == user.uuid
    end
  end

  describe "FileController file-info read guard — anonymous handout + enumeration" do
    test "require_user refuses an unauthenticated caller" do
      assert {:error, :no_user} = FileController.require_user(nil)
      user = plain_user()
      assert {:ok, ^user} = FileController.require_user(user)
    end

    test "the owner may read their file" do
      owner = plain_user()
      file = make_file(owner.uuid)
      assert {:ok, got} = FileController.authorize_file_read(file, owner)
      assert got.uuid == file.uuid
    end

    test "a non-owner cannot tell a foreign file from a missing one (no oracle)" do
      owner = plain_user()
      stranger = plain_user()
      file = make_file(owner.uuid)

      assert {:error, :not_found} = FileController.authorize_file_read(file, stranger)
      assert {:error, :not_found} = FileController.authorize_file_read(nil, stranger)
    end

    test "an admin may read any file" do
      owner = plain_user()
      admin = admin_user()
      file = make_file(owner.uuid)
      assert {:ok, got} = FileController.authorize_file_read(file, admin)
      assert got.uuid == file.uuid
    end

    test "a mere permission holder cannot read another user's file" do
      owner = plain_user()
      holder = permission_holder_user()
      file = make_file(owner.uuid)

      assert Scope.can_access_admin_area?(Scope.for_user(holder))
      refute Scope.system_role?(Scope.for_user(holder))
      assert {:error, :not_found} = FileController.authorize_file_read(file, holder)
    end
  end

  describe "FileController.get_servable_file/2 — the trashed-file read guard (issue #841)" do
    test "an active file is servable for anyone, unchanged" do
      owner = plain_user()
      file = make_file(owner.uuid)

      for user <- [nil, owner, plain_user(), permission_holder_user(), admin_user()] do
        assert {:ok, got} = FileController.get_servable_file(conn_for(user), file.uuid)
        assert got.uuid == file.uuid
      end
    end

    test "a trashed file is not found for an anonymous caller" do
      owner = plain_user()
      file = trashed_file(owner.uuid)

      assert {:error, :not_found} = FileController.get_servable_file(conn_for(nil), file.uuid)
    end

    test "a trashed file is not found for its own owner without the media permission" do
      owner = plain_user()
      file = trashed_file(owner.uuid)

      assert {:error, :not_found} = FileController.get_servable_file(conn_for(owner), file.uuid)
    end

    test "a trashed file is not found for an unrelated plain user" do
      owner = plain_user()
      stranger = plain_user()
      file = trashed_file(owner.uuid)

      assert {:error, :not_found} =
               FileController.get_servable_file(conn_for(stranger), file.uuid)
    end

    test "a trashed file IS servable for a 'media' permission holder — the Trash tab needs it" do
      owner = plain_user()
      holder = permission_holder_user()
      file = trashed_file(owner.uuid)

      assert {:ok, got} = FileController.get_servable_file(conn_for(holder), file.uuid)
      assert got.uuid == file.uuid
    end

    test "a trashed file IS servable for an Admin" do
      owner = plain_user()
      admin = admin_user()
      file = trashed_file(owner.uuid)

      assert {:ok, got} = FileController.get_servable_file(conn_for(admin), file.uuid)
      assert got.uuid == file.uuid
    end

    test "a trashed file IS servable for a superadmin ('*') grant — Owner-equivalent" do
      owner = plain_user()
      admin = superadmin_user()
      file = trashed_file(owner.uuid)

      assert {:ok, got} = FileController.get_servable_file(conn_for(admin), file.uuid)
      assert got.uuid == file.uuid
    end

    test "a system-managed file is never servable, even trashed, even for an Admin" do
      owner = plain_user()
      admin = admin_user()
      file = system_managed_file(owner.uuid)

      assert {:error, :not_found} = FileController.get_servable_file(conn_for(admin), file.uuid)
    end

    test "a missing file is not found, same as before" do
      assert {:error, :not_found} =
               FileController.get_servable_file(conn_for(nil), Ecto.UUID.generate())
    end
  end

  describe "FileController.authorize_trashed_read/1" do
    test "false for nil (anonymous)" do
      refute FileController.authorize_trashed_read(nil)
    end

    test "false for a plain user, true for a 'media' holder, an Admin, and a superadmin grant" do
      refute FileController.authorize_trashed_read(plain_user())
      assert FileController.authorize_trashed_read(permission_holder_user())
      assert FileController.authorize_trashed_read(admin_user())
      assert FileController.authorize_trashed_read(superadmin_user())
    end
  end

  describe "FileController.show/2 — trashed file end-to-end (issue #841)" do
    test "404s for an anonymous caller even with a syntactically valid token" do
      owner = plain_user()
      file = trashed_file(owner.uuid)
      token = URLSigner.generate_token(file.uuid, "original")

      conn =
        FileController.show(conn_for(nil), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => token
        })

      assert conn.status == 404
    end

    test "404s for a plain (non-owner, non-media) caller even with a valid token" do
      owner = plain_user()
      stranger = plain_user()
      file = trashed_file(owner.uuid)
      token = URLSigner.generate_token(file.uuid, "original")

      conn =
        FileController.show(conn_for(stranger), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => token
        })

      assert conn.status == 404
    end

    test "an active (non-trashed) file's serving is unaffected: token failure still 401, not 404" do
      owner = plain_user()
      file = make_file(owner.uuid)

      conn =
        FileController.show(conn_for(nil), %{
          "file_uuid" => file.uuid,
          "variant" => "original",
          "token" => "not-a-real-token"
        })

      assert conn.status == 401
    end
  end

  describe "FileController.info_details/2 — the file's text in the info response" do
    test "is in the language the locale parameter names, else the primary language's" do
      file = make_file(plain_user().uuid)
      {:ok, file} = Storage.update_file_details(file, %{"title" => "Harbour", "alt" => "Boats"})
      {:ok, file} = Storage.update_file_details(file, %{"title" => "Sadam"}, lang: "et")

      assert FileController.info_details(file, "et") ==
               %{title: "Sadam", alt: "Boats", description: nil}

      assert FileController.info_details(file, nil).title == "Harbour"
    end

    test "a locale that is not shaped like a language code reads the primary language" do
      file = make_file(plain_user().uuid)
      {:ok, file} = Storage.update_file_details(file, %{"title" => "Harbour"})

      for forged <- ["../../etc", "", String.duplicate("a", 300), ["et"], %{"x" => "y"}] do
        assert FileController.info_details(file, forged).title == "Harbour"
      end
    end
  end

  describe "RateLimiter.check_upload_rate_limit/1" do
    test "allows the first request and is keyed on the account" do
      assert :ok = RateLimiter.check_upload_rate_limit(Ecto.UUID.generate())
    end
  end
end
