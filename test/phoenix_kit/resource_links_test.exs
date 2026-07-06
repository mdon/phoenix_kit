defmodule PhoenixKit.ResourceLinksTest do
  @moduledoc """
  Unit tests for the shared resource deep-link resolver.

  Covers the DB-free paths: item filtering, unknown-type fallthrough, and the
  `url/1` prefix/raw dispatch. Handler- and template-backed resolution are
  exercised through the integration suites of their call sites (comments
  moderation + activity feed).
  """
  use ExUnit.Case, async: true

  # These paths deliberately fail open (→ %{}) when no DB connection is checked
  # out, logging a rescued warning; capture it so the suite output stays clean.
  @moduletag capture_log: true

  alias PhoenixKit.ResourceLinks

  describe "resolve/1" do
    test "skips items missing a resource_type or resource_uuid" do
      items = [
        %{resource_type: nil, resource_uuid: "abc", metadata: %{}},
        %{resource_type: "post", resource_uuid: nil, metadata: %{}},
        %{resource_type: "", resource_uuid: "abc", metadata: %{}}
      ]

      assert ResourceLinks.resolve(items) == %{}
    end

    test "returns an empty map for a resource_type with no handler and no template" do
      items = [%{resource_type: "no_such_type_xyz", resource_uuid: "abc", metadata: %{}}]

      assert ResourceLinks.resolve(items) == %{}
    end

    test "tolerates items with no metadata key" do
      items = [%{resource_type: "no_such_type_xyz", resource_uuid: "abc"}]

      assert ResourceLinks.resolve(items) == %{}
    end
  end

  describe "info_for/3" do
    test "looks up a resolved pair, nil when absent" do
      context = %{{"post", "u1"} => %{title: "Hello", path: "/p/u1", prefixed: true}}

      assert ResourceLinks.info_for(context, "post", "u1") == %{
               title: "Hello",
               path: "/p/u1",
               prefixed: true
             }

      assert ResourceLinks.info_for(context, "post", "missing") == nil
    end
  end

  describe "url/1" do
    test "returns host-template paths verbatim when not prefixed" do
      assert ResourceLinks.url(%{path: "https://example.com/x", prefixed: false}) ==
               "https://example.com/x"
    end

    test "applies the phoenix_kit prefix to prefixed paths" do
      # Routes.path/1 prepends the configured url_prefix; with the default root
      # prefix the path is returned unchanged, but it must not raise and must be
      # a binary starting from the given raw path.
      url = ResourceLinks.url(%{path: "/admin/users/view/abc", prefixed: true})
      assert is_binary(url)
      assert String.ends_with?(url, "/admin/users/view/abc")
    end
  end

  describe "handlers/0" do
    test "auto-registers the loaded core handlers" do
      handlers = ResourceLinks.handlers()

      # The user + file handlers ship in core and are always loaded in the suite.
      assert handlers["user"] == PhoenixKit.Users.CommentResources
      assert handlers["file"] == PhoenixKit.Annotations
    end
  end
end
