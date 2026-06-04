defmodule PhoenixKitWeb.Users.MultiSessionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Users.MultiSession

  describe "stack_tokens/1" do
    test "returns the explicit stack when present" do
      session = %{"user_token" => "a", "pk_session_accounts" => ["a", "b"]}
      assert MultiSession.stack_tokens(session) == ["a", "b"]
    end

    test "falls back to [active_token] when stack absent" do
      session = %{"user_token" => "a"}
      assert MultiSession.stack_tokens(session) == ["a"]
    end

    test "returns [] when no active token" do
      assert MultiSession.stack_tokens(%{}) == []
    end
  end

  describe "max_accounts/0" do
    test "is 5" do
      assert MultiSession.max_accounts() == 5
    end
  end
end
