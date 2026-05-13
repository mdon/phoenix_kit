defmodule PhoenixKit.Integrations.IntegrationsTest do
  @moduledoc """
  Unit tests for the Integrations context (no DB required).
  See test/integration/integrations_test.exs for full DB integration tests.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations

  describe "validate_connection/1 (no DB)" do
    test "returns error for invalid input" do
      assert {:error, _} = Integrations.validate_connection("")
    end
  end

  describe "list_providers/0" do
    test "returns a list of provider maps" do
      providers = Integrations.list_providers()
      assert is_list(providers)
      assert length(providers) >= 2
      keys = Enum.map(providers, & &1.key)
      assert "google" in keys
      assert "openrouter" in keys
    end
  end
end
