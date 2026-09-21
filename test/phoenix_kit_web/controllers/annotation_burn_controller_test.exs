defmodule PhoenixKitWeb.AnnotationBurnControllerTest do
  @moduledoc """
  The burn endpoint's decisions that don't need a database: which slots a
  client may overwrite, who may ask, and which bytes count as a picture.

  The viewer's ladder (`small`, `medium`, `large`, `original`) is the
  invariant. Those are the rungs the editor paints and then draws the live
  shapes on top of. A burn stored in any of them draws every annotation twice.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitWeb.AnnotationBurnController, as: Burn

  @ladder ~w(small medium large original)

  describe "writable slots" do
    test "the viewer's ladder is not writable" do
      writable = Burn.writable_variants()

      assert "thumbnail" in writable
      assert "burned" in writable
      assert MapSet.disjoint?(MapSet.new(writable), MapSet.new(@ladder))
    end

    test "a request for the ladder is refused, not partially applied" do
      assert Burn.variants_from_params(%{"variants" => "thumbnail,small,medium,large"}) ==
               {:error, :bad_variant}

      assert Burn.variants_from_params(%{"variants" => "original"}) == {:error, :bad_variant}
    end

    test "thumbnail and burned are accepted, and the default is thumbnail" do
      assert Burn.variants_from_params(%{"variants" => "burned, thumbnail"}) ==
               {:ok, ~w(burned thumbnail)}

      assert Burn.variants_from_params(%{}) == {:ok, ~w(thumbnail)}
      assert Burn.variants_from_params(%{"variants" => ""}) == {:ok, ~w(thumbnail)}
    end

    test "a list of names is accepted the same way as a comma string" do
      assert Burn.variants_from_params(%{"variants" => ["thumbnail", "burned", "thumbnail"]}) ==
               {:ok, ~w(thumbnail burned)}
    end
  end

  describe "who may burn" do
    test "the owner, an Owner/Admin, or a media-module holder" do
      file = %{user_uuid: "file-owner"}
      owner = %User{uuid: "file-owner"}
      other = %User{uuid: "someone-else"}
      user_scope = scope(["User"], [])
      media_scope = scope(["User"], ["media"])
      admin_scope = scope(["Admin"], [])

      assert Burn.allowed?(file, owner, user_scope)
      refute Burn.allowed?(file, other, user_scope)
      assert Burn.allowed?(file, other, media_scope)
      assert Burn.allowed?(file, other, admin_scope)
    end

    test "a file with no owner is not claimable by matching nil" do
      refute Burn.allowed?(%{user_uuid: nil}, %User{uuid: nil}, scope(["User"], []))
    end
  end

  describe "picture bytes" do
    test "jpeg and png magic pass; a content-type claim is not consulted" do
      assert Burn.image_magic?(<<0xFF, 0xD8, 0xFF, 0xE0, "rest">>)
      assert Burn.image_magic?(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, "rest">>)
      refute Burn.image_magic?(<<0x89, "PNG is not enough">>)
      refute Burn.image_magic?("<?php")
      refute Burn.image_magic?(:eof)
    end
  end

  describe "source version" do
    test "a named version must be the original the file has now" do
      assert Burn.source_version_ok?("abcdef0123456789", "abcdef0123456789")
      refute Burn.source_version_ok?("abcdef0123456789", "0000000000000000")
    end

    test "no version on either side is not a disagreement" do
      assert Burn.source_version_ok?(nil, nil)
      assert Burn.source_version_ok?("abcdef0123456789", nil)
      assert Burn.source_version_ok?(nil, "abcdef0123456789")
      assert Burn.source_version_ok?("abcdef0123456789", "")
    end
  end

  defp scope(roles, permissions) do
    %Scope{
      authenticated?: true,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end
end
