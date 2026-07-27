defmodule PhoenixKit.Notifications.TypesTest do
  # No DB — Types.list/0 reads static core types + the persistent_term module
  # registry, never the repo.
  use ExUnit.Case, async: true

  alias PhoenixKit.Notifications.Types

  describe "list/0 normalizes core types with sub-types" do
    test "types carry a sub_types list (composed dotted keys) and posts/comments are split" do
      types = Map.new(Types.list(), &{&1.key, &1})

      # Every type has a sub_types list (flat types → []).
      assert Enum.all?(Types.list(), &is_list(&1.sub_types))

      comments = types["comments"]
      sub_keys = Enum.map(comments.sub_types, & &1.key)
      assert "comments.replies" in sub_keys
      assert "comments.reactions" in sub_keys

      # Fully-split types own no actions at the base.
      assert comments.actions == []
      assert types["posts"].actions == []

      # Flat types keep their actions and have no sub-types.
      assert types["account"].sub_types == []
      assert "user.password_changed" in types["account"].actions
      assert types["security"].sub_types == []
    end
  end

  describe "key_for_action/1 (most-specific)" do
    test "resolves to a sub-type key when a sub-type claims the action" do
      assert Types.key_for_action("comment.replied") == "comments.replies"
      assert Types.key_for_action("comment.liked") == "comments.reactions"
      assert Types.key_for_action("post.liked") == "posts.likes"
      assert Types.key_for_action("post.commented") == "posts.comments"
      assert Types.key_for_action("post.mentioned") == "posts.mentions"
    end

    test "resolves to the base key for a flat type" do
      assert Types.key_for_action("user.password_changed") == "account"
      assert Types.key_for_action("user.new_login_detected") == "security"
    end

    test "returns nil for an unclaimed action (fail-open at the caller)" do
      assert Types.key_for_action("totally.unknown") == nil
      assert Types.key_for_action(nil) == nil
    end
  end

  describe "type_for_action/1 (base key, back-compat)" do
    test "returns the BASE key even when a sub-type owns the action" do
      assert Types.type_for_action("comment.replied") == "comments"
      assert Types.type_for_action("post.liked") == "posts"
      assert Types.type_for_action("user.password_changed") == "account"
      assert Types.type_for_action("totally.unknown") == nil
    end
  end

  describe "parent_type_key/1" do
    test "dotted → base, base → nil, unknown shapes → nil" do
      assert Types.parent_type_key("comments.replies") == "comments"
      assert Types.parent_type_key("comments") == nil
      assert Types.parent_type_key(nil) == nil
    end
  end

  describe "all_pref_keys/0 and base_keys/0" do
    test "all_pref_keys includes every base + every sub key, de-duped" do
      keys = Types.all_pref_keys()

      assert "comments" in keys
      assert "comments.replies" in keys
      assert "comments.reactions" in keys
      assert "posts" in keys
      assert "posts.likes" in keys
      assert "account" in keys
      assert length(keys) == length(Enum.uniq(keys))
    end

    test "base_keys are the masters only (no sub keys)" do
      bases = Types.base_keys()
      assert "comments" in bases
      assert "posts" in bases
      refute "comments.replies" in bases
    end
  end

  describe "default_for/1 is total" do
    test "base key, dotted sub key, and unknown key" do
      assert Types.default_for("comments") == true
      assert Types.default_for("comments.replies") == true
      # TOTAL: unknown keys must return true (the fail-open backstop).
      assert Types.default_for("nope.nope") == true
      assert Types.default_for("account") == true
    end
  end
end
