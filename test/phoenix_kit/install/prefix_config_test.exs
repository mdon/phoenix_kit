defmodule PhoenixKit.Install.PrefixConfigTest do
  # async: false — mutates the :phoenix_kit application env.
  use ExUnit.Case, async: false

  alias PhoenixKit.Install.PrefixConfig

  setup do
    original = Application.get_env(:phoenix_kit, :prefix)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:phoenix_kit, :prefix)
        value -> Application.put_env(:phoenix_kit, :prefix, value)
      end
    end)

    :ok
  end

  describe "resolve_prefix/1" do
    test "explicit --prefix option wins" do
      Application.put_env(:phoenix_kit, :prefix, "from_config")
      assert PrefixConfig.resolve_prefix(prefix: "from_flag") == "from_flag"
    end

    test "falls back to config :phoenix_kit, :prefix" do
      Application.put_env(:phoenix_kit, :prefix, "companyplexus")
      assert PrefixConfig.resolve_prefix([]) == "companyplexus"
    end

    test "defaults to public when neither is set" do
      Application.delete_env(:phoenix_kit, :prefix)
      assert PrefixConfig.resolve_prefix([]) == "public"
    end

    test "ignores blank or non-binary config values" do
      Application.put_env(:phoenix_kit, :prefix, "")
      assert PrefixConfig.resolve_prefix([]) == "public"

      Application.put_env(:phoenix_kit, :prefix, :auth)
      assert PrefixConfig.resolve_prefix([]) == "public"
    end

    test "raises on an invalid explicit --prefix instead of passing it through" do
      # Regression: --prefix "" / quoting-requiring values used to flow
      # into tooling SQL and the generated migration, failing only at
      # mix ecto.migrate time.
      for bad <- ["", "My-App", "sp ace", "1abc"] do
        assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
          PrefixConfig.resolve_prefix(prefix: bad)
        end
      end
    end

    test "raises on an invalid configured prefix" do
      Application.put_env(:phoenix_kit, :prefix, "Bad-Prefix")

      assert_raise ArgumentError, ~r/invalid PhoenixKit schema prefix/, fn ->
        PrefixConfig.resolve_prefix([])
      end
    end
  end
end
