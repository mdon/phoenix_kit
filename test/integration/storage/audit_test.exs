defmodule PhoenixKit.Modules.Storage.AuditTest do
  @moduledoc """
  Every change to the site's storage configuration is written to the Activity log
  (`Storage.Audit`, plan `2026-10-03-job-runs.md` §7): who did it, what moved from
  what to what, permanently — and nothing for a change that did not happen, for a
  user's own library, profile or bucket, or ever a key or a secret.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Audit, Libraries, Profiles, VariantSets}
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.{Auth, Permissions, Roles}
  alias PhoenixKit.Users.Auth.Scope

  setup do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "audit-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{n: n, actor: [actor_uuid: user.uuid], user: user}
  end

  defp entries(action) do
    Repo.all(
      from e in Entry,
        where: e.module == "storage" and e.action == ^action,
        order_by: [asc: e.inserted_at, asc: e.uuid]
    )
  end

  defp newest(action), do: action |> entries() |> List.last()

  test "the module key is the storage module's own" do
    assert Audit.module_key() == Storage.module_key()
  end

  describe "profiles" do
    test "created, renamed and given another copy count, then deleted", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Audit #{ctx.n}"}, ctx.actor)

      assert %Entry{
               actor_uuid: actor,
               mode: "manual",
               permanent: true,
               resource_type: "storage_profile",
               metadata: %{"name" => name}
             } = newest("storage.profile.created")

      assert actor == ctx.user.uuid
      assert name == "Audit #{ctx.n}"

      {:ok, profile} =
        Profiles.update_profile(
          profile,
          %{name: "Renamed #{ctx.n}", copies_originals: 2},
          ctx.actor
        )

      assert %Entry{metadata: %{"changes" => changes, "name" => "Renamed" <> _}} =
               newest("storage.profile.updated")

      assert changes["name"] == %{"from" => "Audit #{ctx.n}", "to" => "Renamed #{ctx.n}"}
      assert changes["copies_originals"] == %{"from" => 1, "to" => 2}

      {:ok, _} = Profiles.delete_profile(profile, ctx.actor)
      assert %Entry{metadata: %{"name" => "Renamed" <> _}} = newest("storage.profile.deleted")
    end

    test "an update that changes nothing writes nothing", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Same #{ctx.n}"}, ctx.actor)
      before = length(entries("storage.profile.updated"))

      {:ok, _} = Profiles.update_profile(profile, %{name: "Same #{ctx.n}"}, ctx.actor)
      assert length(entries("storage.profile.updated")) == before
    end

    test "a refused change writes nothing", ctx do
      before = length(entries("storage.profile.deleted"))
      assert {:error, :default} = Profiles.delete_profile(Profiles.default_profile(), ctx.actor)
      assert length(entries("storage.profile.deleted")) == before
    end

    test "with no actor the entry says the system did it", ctx do
      {:ok, _} = Profiles.create_profile(%{name: "Nobody #{ctx.n}"})
      assert %Entry{actor_uuid: nil, mode: "auto"} = newest("storage.profile.created")
    end

    test "a bucket added, changed and removed names the bucket and what moved", ctx do
      {:ok, profile} = Profiles.create_profile(%{name: "Rows #{ctx.n}"}, ctx.actor)
      {:ok, bucket} = bucket!(ctx)

      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{}, ctx.actor)

      assert %Entry{metadata: %{"bucket" => bucket_name, "profile" => "Rows" <> _}} =
               newest("storage.profile.bucket_added")

      assert bucket_name == bucket.name

      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{status: "draining"}, ctx.actor)

      assert %Entry{
               metadata: %{"changes" => %{"status" => %{"from" => "active", "to" => "draining"}}}
             } =
               newest("storage.profile.bucket_changed")

      # the same again changes nothing and is not recorded twice
      count = length(entries("storage.profile.bucket_changed"))
      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{status: "draining"}, ctx.actor)
      assert length(entries("storage.profile.bucket_changed")) == count

      :ok = Profiles.remove_bucket(profile, bucket.uuid, ctx.actor)

      assert %Entry{metadata: %{"bucket" => ^bucket_name}} =
               newest("storage.profile.bucket_removed")

      # removing what is not there records nothing
      removed = length(entries("storage.profile.bucket_removed"))
      :ok = Profiles.remove_bucket(profile, bucket.uuid, ctx.actor)
      assert length(entries("storage.profile.bucket_removed")) == removed
    end
  end

  describe "libraries" do
    test "created, renamed, moved to a profile and a variant set, set, and deleted", ctx do
      {:ok, library} = Libraries.create_system_library(%{name: "Audited #{ctx.n}"}, ctx.actor)
      assert %Entry{resource_type: "storage_library"} = newest("storage.library.created")

      {:ok, library} = Libraries.rename_library(library, "Audited again #{ctx.n}", ctx.actor)

      assert %Entry{metadata: %{"changes" => %{"name" => %{"from" => from, "to" => to}}}} =
               newest("storage.library.renamed")

      assert {from, to} == {"Audited #{ctx.n}", "Audited again #{ctx.n}"}

      {:ok, profile} = Profiles.create_profile(%{name: "Cold #{ctx.n}"}, ctx.actor)
      {:ok, library} = Profiles.set_library_profile(library, profile.uuid, ctx.actor)

      assert %Entry{
               metadata: %{
                 "changes" => %{"profile" => %{"from" => "Default", "to" => "Cold" <> _}}
               }
             } =
               newest("storage.library.profile_changed")

      {:ok, set} = VariantSets.create_variant_set(%{name: "Small #{ctx.n}"}, ctx.actor)
      {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid, ctx.actor)

      assert %Entry{metadata: %{"changes" => %{"variant_set" => %{"to" => "Small" <> _}}}} =
               newest("storage.library.variant_set_changed")

      {:ok, library} = Libraries.put_setting(library, :annotated_thumbnails, true, ctx.actor)

      assert %Entry{
               metadata: %{
                 "changes" => %{
                   "annotated_thumbnails" => %{"from" => "site default", "to" => true}
                 }
               }
             } = newest("storage.library.setting_changed")

      {:ok, _} = Libraries.delete_library(library, ctx.actor)

      assert %Entry{metadata: %{"name" => "Audited again" <> _}} =
               newest("storage.library.deleted")
    end

    test "choosing what it already has records nothing", ctx do
      {:ok, library} = Libraries.create_system_library(%{name: "Still #{ctx.n}"}, ctx.actor)
      count = length(entries("storage.library.profile_changed"))

      {:ok, _} = Profiles.set_library_profile(library, nil, ctx.actor)
      assert length(entries("storage.library.profile_changed")) == count
    end
  end

  describe "variant sets and sizes" do
    test "a set created, switched, a size added, changed and deleted, then the set deleted",
         ctx do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Sizes #{ctx.n}"}, ctx.actor)
      assert %Entry{resource_type: "storage_variant_set"} = newest("storage.variant_set.created")

      {:ok, set} = VariantSets.update_variant_set(set, %{generate_tiles: true}, ctx.actor)

      assert %Entry{
               metadata: %{"changes" => %{"generate_tiles" => %{"from" => false, "to" => true}}}
             } =
               newest("storage.variant_set.updated")

      {:ok, dimension} =
        Storage.create_dimension(
          %{
            name: "banner",
            width: 1200,
            height: 300,
            quality: 80,
            format: "jpg",
            applies_to: "image"
          },
          set.uuid,
          ctx.actor
        )

      assert %Entry{metadata: %{"size" => "banner", "width" => 1200}} =
               newest("storage.variant_set.size_created")

      {:ok, dimension} = Storage.update_dimension(dimension, %{width: 1000}, ctx.actor)

      assert %Entry{
               metadata: %{
                 "size" => "banner",
                 "changes" => %{"width" => %{"from" => 1200, "to" => 1000}}
               }
             } =
               newest("storage.variant_set.size_updated")

      # reordering moves no pixels and is not recorded
      count = length(entries("storage.variant_set.size_updated"))
      {:ok, _} = Storage.update_dimension(dimension, %{order: 99}, ctx.actor)
      assert length(entries("storage.variant_set.size_updated")) == count

      {:ok, _} = Storage.delete_dimension(dimension, ctx.actor)
      assert %Entry{metadata: %{"size" => "banner"}} = newest("storage.variant_set.size_deleted")

      {:ok, _} = VariantSets.delete_variant_set(set, ctx.actor)
      assert %Entry{metadata: %{"name" => "Sizes" <> _}} = newest("storage.variant_set.deleted")
    end

    test "remaking every size is recorded once, and so is resetting the defaults", ctx do
      :ok = VariantSets.remake_all(ctx.actor)
      assert %Entry{actor_uuid: actor} = newest("storage.variant_set.remade")
      assert actor == ctx.user.uuid

      {:ok, _} = Storage.reset_dimensions_to_defaults(ctx.actor)
      assert %Entry{} = newest("storage.variant_set.sizes_reset")
    end
  end

  describe "buckets" do
    test "created, changed and deleted; only the fields that are not secret are named", ctx do
      {:ok, bucket} = bucket!(ctx)

      assert %Entry{
               resource_type: "storage_bucket",
               metadata: %{"name" => name, "provider" => "local"}
             } =
               newest("storage.bucket.created")

      assert name == bucket.name

      {:ok, bucket} =
        Storage.update_bucket(
          bucket,
          %{enabled: false, priority: 5, name: "Renamed #{ctx.n}"},
          ctx.actor
        )

      assert %Entry{metadata: %{"changes" => changes}} = newest("storage.bucket.updated")
      assert changes["enabled"] == %{"from" => true, "to" => false}
      assert changes["priority"] == %{"from" => 0, "to" => 5}
      assert changes["name"]["to"] == "Renamed #{ctx.n}"

      {:ok, _} = Storage.delete_bucket(bucket, ctx.actor)
      assert %Entry{metadata: %{"name" => "Renamed" <> _}} = newest("storage.bucket.deleted")
    end

    test "a secret is never in an entry, whatever the bucket carries", ctx do
      {:ok, bucket} =
        Storage.create_bucket(
          %{
            name: "Secretive #{ctx.n}",
            provider: "s3",
            bucket_name: "b",
            region: "eu-north-1",
            access_key_id: "AKIASECRETKEYID",
            secret_access_key: "very-secret-value",
            enabled: true,
            priority: 0
          },
          ctx.actor
        )

      {:ok, _} =
        Storage.update_bucket(
          bucket,
          %{
            access_key_id: "AKIAOTHERKEYID",
            secret_access_key: "another-secret",
            region: "eu-west-1"
          },
          ctx.actor
        )

      everything =
        Repo.all(
          from e in Entry, where: e.module == "storage" and like(e.action, "storage.bucket.%")
        )
        |> Enum.map_join(&inspect(&1.metadata))

      refute everything =~ "AKIA"
      refute everything =~ "secret"
      assert everything =~ "eu-west-1"
    end

    test "changing a bucket's priority moves the Default profile's write priority without an entry of its own",
         ctx do
      {:ok, bucket} = bucket!(ctx)
      before = length(entries("storage.profile.bucket_changed"))

      {:ok, _} = Storage.update_bucket(bucket, %{priority: 7}, ctx.actor)

      assert length(entries("storage.profile.bucket_changed")) == before
    end
  end

  describe "what is not in the history" do
    setup %{n: n} do
      {:ok, _} = Settings.update_boolean_setting("storage_user_libraries_enabled", true)
      {:ok, role} = Roles.create_role(%{name: "Audit librarians #{n}"})
      {:ok, _} = Permissions.grant_permission(role.uuid, "storage")
      {:ok, _} = Permissions.grant_permission(role.uuid, "storage.create_library")
      %{role: role}
    end

    test "a user's own library is theirs and private", %{role: role, n: n} do
      {:ok, owner} =
        Auth.register_user(%{
          "email" => "audit-owner-#{n}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, _} = Roles.assign_role(owner, role.name)
      scope = Scope.for_user(Repo.get!(Auth.User, owner.uuid))
      before = Repo.aggregate(from(e in Entry, where: e.module == "storage"), :count)

      {:ok, library} = Libraries.create_user_library(scope, %{"name" => "Private #{n}"})

      {:ok, library} =
        Libraries.rename_library(library, "Renamed private #{n}", actor_uuid: owner.uuid)

      {:ok, library} =
        Libraries.put_setting(library, :annotated_thumbnails, true, actor_uuid: owner.uuid)

      {:ok, _} = VariantSets.set_library_variant_set(library, nil, actor_uuid: owner.uuid)

      assert Repo.aggregate(from(e in Entry, where: e.module == "storage"), :count) == before
    end
  end

  defp bucket!(ctx) do
    root = Path.join(System.tmp_dir!(), "pk_audit_#{ctx.n}_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    Storage.create_bucket(
      %{
        name: "audit-#{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      },
      ctx.actor
    )
  end
end
