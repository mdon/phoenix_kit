defmodule PhoenixKit.Integration.Sitemap.RouterDiscoveryValidationTest do
  @moduledoc """
  Pins the pattern-validation contract the sitemap settings UI relies on:
  `RouterDiscovery.invalid_patterns/1` must flag exactly the patterns that
  `compile_patterns/2` would otherwise silently drop (with only a log
  warning) at collection time, so the settings UI can reject bad input
  before it's ever saved instead of persisting a pattern that quietly does
  nothing.

  Pure logic, no database needed.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.Sources.RouterDiscovery

  describe "invalid_patterns/1" do
    test "returns an empty list when every pattern compiles" do
      assert RouterDiscovery.invalid_patterns(["^/admin", "^/api", ".*"]) == []
    end

    test "flags a bare wildcard — a shell glob, not a valid regex" do
      assert RouterDiscovery.invalid_patterns(["^/admin", "*"]) == ["*"]
    end

    test "flags every pattern that fails to compile, preserving input order" do
      assert RouterDiscovery.invalid_patterns(["*", "^/ok", "("]) == ["*", "("]
    end

    test "returns an empty list for an empty input" do
      assert RouterDiscovery.invalid_patterns([]) == []
    end
  end

  describe "default_exclude_patterns/0" do
    test "returns the built-in list of exclude patterns" do
      defaults = RouterDiscovery.default_exclude_patterns()

      assert is_list(defaults)
      assert Enum.all?(defaults, &is_binary/1)
      assert "^/admin" in defaults
      # Every default must itself compile — the built-ins are never invalid.
      assert RouterDiscovery.invalid_patterns(defaults) == []
    end
  end

  describe "default_protected_pipelines/0" do
    test "returns the built-in list of protected pipeline names" do
      defaults = RouterDiscovery.default_protected_pipelines()

      assert is_list(defaults)
      assert Enum.all?(defaults, &is_atom/1)
      assert :phoenix_kit_admin_only in defaults
    end
  end
end
