defmodule PhoenixKit.Modules.Storage.ProfilesTest do
  @moduledoc """
  Storage profiles and variant sets (V205), the contexts: a library with no
  profile or set resolves to the Default, every placement change bumps a
  revision (a rename does not), the Default and anything in use cannot be
  deleted, a bucket joins the Default when created and leaves every profile
  when deleted, a new set starts with the standard slots, and a user
  library may only pick a selectable set.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, Library, Profiles, StorageProfile, VariantSets}
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp bucket!(attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: "profiles-#{System.unique_integer([:positive])}",
            provider: "local",
            endpoint: Path.join(System.tmp_dir!(), "pk_profiles"),
            enabled: true,
            priority: 0
          },
          attrs
        )
      )

    bucket
  end

  defp library! do
    {:ok, library} =
      Libraries.create_system_library(%{name: "Profiles #{System.unique_integer([:positive])}"})

    library
  end

  defp revision(uuid), do: Profiles.get_profile(uuid).revision

  describe "resolving" do
    test "a library with no profile or set uses the Defaults, and Media is one" do
      library = library!()

      assert Profiles.profile_uuid_for(library) == Profiles.default_uuid()
      assert Profiles.profile_uuid_for(nil) == Profiles.default_uuid()
      assert %StorageProfile{is_default: true} = Profiles.for_library(library)
      assert VariantSets.set_uuid_for(library.uuid) == VariantSets.default_uuid()
      assert VariantSets.for_library(nil).is_default
    end

    test "a library points at its own profile and set" do
      library = library!()
      {:ok, profile} = Profiles.create_profile(%{name: "Cloud"})
      {:ok, set} = VariantSets.create_variant_set(%{name: "Photos"})

      {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
      {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

      assert Profiles.for_library(library.uuid).uuid == profile.uuid
      assert VariantSets.for_library(library.uuid).uuid == set.uuid

      # Naming the Default stores nil: the library follows whatever is Default.
      {:ok, library} = Profiles.set_library_profile(library, Profiles.default_uuid())
      assert library.storage_profile_uuid == nil
    end

    test "an unknown profile or set is refused" do
      library = library!()
      assert {:error, :not_found} = Profiles.set_library_profile(library, Ecto.UUID.generate())

      assert {:error, :not_found} =
               VariantSets.set_library_variant_set(library, Ecto.UUID.generate())
    end
  end

  describe "revisions" do
    test "copy counts and bucket rows bump the revision; a rename does not" do
      {:ok, profile} = Profiles.create_profile(%{name: "Revisions"})
      assert profile.revision == 1

      {:ok, profile} = Profiles.update_profile(profile, %{name: "Renamed"})
      assert profile.revision == 1

      {:ok, profile} = Profiles.update_profile(profile, %{copies_originals: 2})
      assert profile.revision == 2

      bucket = bucket!()
      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{role: "backup"})
      assert revision(profile.uuid) == 3

      # Saving the same values again changes nothing.
      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{role: "backup"})
      assert revision(profile.uuid) == 3

      :ok = Profiles.remove_bucket(profile, bucket.uuid)
      assert revision(profile.uuid) == 4
    end

    test "min copies on write cannot exceed the copies of an original" do
      {:ok, profile} = Profiles.create_profile(%{name: "Min"})

      assert {:error, changeset} =
               Profiles.update_profile(profile, %{copies_originals: 2, min_copies_on_write: 3})

      assert %{min_copies_on_write: [_]} = errors_on(changeset)
    end

    test "a storage class is only allowed on a backup copy" do
      {:ok, profile} = Profiles.create_profile(%{name: "Classes"})
      bucket = bucket!()

      assert {:error, changeset} =
               Profiles.put_bucket(profile, bucket.uuid, %{
                 role: "primary",
                 storage_class: "GLACIER"
               })

      assert %{storage_class: [_]} = errors_on(changeset)

      assert {:ok, _} =
               Profiles.put_bucket(profile, bucket.uuid, %{
                 role: "backup",
                 storage_class: "GLACIER"
               })
    end

    test "a set's generation flags bump its revision; a rename or selectable does not" do
      {:ok, set} = VariantSets.create_variant_set(%{name: "Flags"})
      {:ok, set} = VariantSets.update_variant_set(set, %{name: "Flags 2", selectable: true})
      assert set.revision == 1

      {:ok, set} = VariantSets.update_variant_set(set, %{generate_tiles: true})
      assert set.revision == 2
    end
  end

  describe "deleting" do
    test "the Defaults cannot be deleted" do
      assert {:error, :default} = Profiles.delete_profile(Profiles.default_profile())

      assert {:error, :default} =
               VariantSets.delete_variant_set(VariantSets.default_variant_set())
    end

    test "a profile or set a library uses cannot be deleted; an unused one can" do
      {:ok, profile} = Profiles.create_profile(%{name: "Used"})
      {:ok, set} = VariantSets.create_variant_set(%{name: "Used set"})
      {:ok, library} = Profiles.set_library_profile(library!(), profile.uuid)
      {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

      assert {:error, :in_use} = Profiles.delete_profile(profile)
      assert {:error, :in_use} = VariantSets.delete_variant_set(set)

      {:ok, library} = Profiles.set_library_profile(library, nil)
      {:ok, _library} = VariantSets.set_library_variant_set(library, nil)

      assert {:ok, _} = Profiles.delete_profile(profile)
      assert {:ok, _} = VariantSets.delete_variant_set(set)
      assert VariantSets.list_dimensions(set.uuid) == []
    end
  end

  describe "buckets" do
    test "a new bucket joins the Default, served after the others, its priority kept" do
      first = bucket!()
      second = bucket!(%{priority: 3})

      rows = Map.new(Profiles.default_profile().buckets, &{&1.bucket_uuid, &1})

      assert %{role: "primary", stores: "all", status: "active", write_priority: nil} =
               rows[first.uuid]

      assert rows[second.uuid].write_priority == 3
      assert rows[second.uuid].serve_order > rows[first.uuid].serve_order
    end

    test "changing a bucket's priority changes its write priority in the Default" do
      bucket = bucket!()
      {:ok, _} = Storage.update_bucket(bucket, %{priority: 2})

      row = Enum.find(Profiles.default_profile().buckets, &(&1.bucket_uuid == bucket.uuid))
      assert row.write_priority == 2
    end

    test "deleting an empty bucket takes it out of every profile" do
      bucket = bucket!()
      {:ok, profile} = Profiles.create_profile(%{name: "Holds it"})
      {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
      before = revision(profile.uuid)

      assert {:ok, _} = Storage.delete_bucket(bucket)

      refute Enum.any?(Profiles.default_profile().buckets, &(&1.bucket_uuid == bucket.uuid))
      assert Profiles.get_profile(profile.uuid).buckets == []
      assert revision(profile.uuid) == before + 1
    end
  end

  describe "variant sets" do
    test "a new set starts with the Default's standard slots" do
      Storage.reset_dimensions_to_defaults()
      {:ok, set} = VariantSets.create_variant_set(%{name: "Standard"})

      names = set.uuid |> VariantSets.list_dimensions() |> Enum.map(& &1.name) |> Enum.sort()

      assert names == Enum.sort(VariantSets.standard_slots())
      assert VariantSets.missing_standard_slots(set.uuid) == []
    end

    test "resetting the Default's sizes leaves other sets alone" do
      Storage.reset_dimensions_to_defaults()
      {:ok, set} = VariantSets.create_variant_set(%{name: "Kept"})
      count = length(VariantSets.list_dimensions(set.uuid))

      Storage.reset_dimensions_to_defaults()

      assert length(VariantSets.list_dimensions(set.uuid)) == count

      assert Storage.get_dimension_by_name("thumbnail").variant_set_uuid ==
               VariantSets.default_uuid()

      assert Storage.get_dimension_by_name("thumbnail", set.uuid).variant_set_uuid == set.uuid
    end

    test "a user library may only pick a selectable set" do
      {:ok, owner} =
        Auth.register_user(%{
          "email" => "profiles-#{System.unique_integer([:positive])}@example.com",
          "password" => "ValidPassword123!"
        })

      {:ok, library} =
        %Library{}
        |> Ecto.Changeset.change(
          name: "Mine",
          kind: "user",
          visibility: "private",
          owner_uuid: owner.uuid,
          key_prefix: "lib-#{System.unique_integer([:positive])}",
          slug: "mine"
        )
        |> Repo.insert()

      {:ok, hidden} = VariantSets.create_variant_set(%{name: "Admin only"})
      {:ok, open} = VariantSets.create_variant_set(%{name: "Open", selectable: true})

      assert {:error, :not_selectable} = VariantSets.set_library_variant_set(library, hidden.uuid)
      assert {:ok, _} = VariantSets.set_library_variant_set(library, open.uuid)
      assert open.uuid in Enum.map(VariantSets.list_selectable(), & &1.uuid)
      refute hidden.uuid in Enum.map(VariantSets.list_selectable(), & &1.uuid)
    end
  end
end
