defmodule PhoenixKit.API.LegacyTest do
  @moduledoc """
  `PhoenixKit.API.Legacy`, the one module that holds the names the public API
  had before it was made module-neutral. It is deleted in 3.0.0; so is this
  file.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.API.Legacy

  describe "the deprecated paths" do
    test "are the REST and MCP paths the public API had" do
      assert Legacy.alias_paths() == [["api", "shop", "v1"], ["mcp", "shop"]]
    end
  end

  describe "the Deprecation header" do
    test "is the RFC 9745 timestamp of 2026-10-20T00:00:00Z" do
      assert Legacy.deprecation() == "@1792454400"
      assert Legacy.deprecation() == "@#{DateTime.to_unix(~U[2026-10-20 00:00:00Z])}"
    end
  end
end
