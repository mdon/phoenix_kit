defmodule PhoenixKit.API.MCP.VersionsTest do
  @moduledoc """
  The table of MCP revisions and the config that narrows it. The application
  environment is global, so these tests are not async and put every key back.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.API.MCP.Versions

  @warning_kinds [:unknown_revision, :empty_revisions, :extra_revisions]

  setup do
    for key <- [:mcp_protocol_versions, :mcp_extra_revisions] do
      previous = Application.fetch_env(:phoenix_kit, key)
      Application.delete_env(:phoenix_kit, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:phoenix_kit, key, value)
          :error -> Application.delete_env(:phoenix_kit, key)
        end
      end)
    end

    forget_warnings()
    on_exit(&forget_warnings/0)
    :ok
  end

  defp forget_warnings do
    for kind <- @warning_kinds, do: :persistent_term.erase({Versions, :warned, kind})
  end

  defp put_env(key, value), do: Application.put_env(:phoenix_kit, key, value)

  defp count(log, text), do: log |> String.split(text) |> length() |> Kernel.-(1)

  describe "the table" do
    test "the known revisions, newest first, and the one a missing header means" do
      assert Versions.known() == ["2025-11-25", "2025-06-18", "2025-03-26"]
      assert Versions.implied() == "2025-03-26"
    end

    test "every profile has every flag, and the flags are the ones the code reads" do
      assert Versions.flags() ==
               [:structured_content, :output_schema, :tool_title, :server_title]

      for version <- Versions.known() do
        assert version |> Versions.profile() |> Map.keys() |> Enum.sort() ==
                 Enum.sort(Versions.flags())
      end
    end

    test "2025-11-25 and 2025-06-18 have every flag on" do
      for version <- ["2025-11-25", "2025-06-18"], flag <- Versions.flags() do
        assert Versions.feature?(version, flag), "#{version} #{flag}"
      end
    end

    test "2025-03-26 has none: text only, no titles" do
      for flag <- Versions.flags() do
        refute Versions.feature?("2025-03-26", flag), "2025-03-26 #{flag}"
      end
    end

    test "a revision that is not in the table has no profile and no flag" do
      assert Versions.profile("2026-07-28") == nil
      assert Versions.profile(nil) == nil
      assert Versions.profile(20_250_626) == nil
      refute Versions.feature?("2026-07-28", :structured_content)
      refute Versions.feature?(nil, :tool_title)
    end

    test "a flag nobody reads is an error, not a quiet false" do
      assert_raise FunctionClauseError, fn -> Versions.feature?("2025-06-18", :batching) end
    end
  end

  describe "supported/0 by default" do
    test "is every known revision, and latest/0 is the newest" do
      assert Versions.supported() == Versions.known()
      assert Versions.latest() == "2025-11-25"
    end

    test "supported?/1 takes the three, and nothing else" do
      for version <- ["2025-11-25", "2025-06-18", "2025-03-26"] do
        assert Versions.supported?(version)
      end

      for other <- ["2026-07-28", "1999-01-01", "", nil, 1, %{}, ["2025-06-18"]] do
        refute Versions.supported?(other), inspect(other)
      end
    end
  end

  describe "negotiate/1" do
    test "a supported revision is echoed" do
      for version <- Versions.supported(), do: assert(Versions.negotiate(version) == version)
    end

    test "an older revision that is not supported gets the newest supported" do
      assert Versions.negotiate("2024-11-05") == "2025-11-25"
    end

    test "a newer revision that is not supported (2026-07-28) gets the newest supported" do
      assert Versions.negotiate("2026-07-28") == "2025-11-25"
    end

    test "garbage gets the newest supported" do
      for garbage <- [nil, "", "not a date", 42, %{}, ["2025-06-18"], :"2025-06-18"] do
        assert Versions.negotiate(garbage) == "2025-11-25", inspect(garbage)
      end
    end
  end

  describe ":mcp_protocol_versions" do
    test "narrows what is supported but not what is known" do
      put_env(:mcp_protocol_versions, ["2025-06-18", "2025-03-26"])

      assert Versions.supported() == ["2025-06-18", "2025-03-26"]
      assert Versions.known() == ["2025-11-25", "2025-06-18", "2025-03-26"]
      refute Versions.supported?("2025-11-25")
      assert Versions.profile("2025-11-25")
    end

    test "negotiates down from a revision it no longer speaks" do
      put_env(:mcp_protocol_versions, ["2025-06-18", "2025-03-26"])

      assert Versions.negotiate("2025-11-25") == "2025-06-18"
      assert Versions.negotiate("2025-03-26") == "2025-03-26"
    end

    test "gives the order: the head is the most preferred" do
      put_env(:mcp_protocol_versions, ["2025-03-26", "2025-11-25"])

      assert Versions.supported() == ["2025-03-26", "2025-11-25"]
      assert Versions.latest() == "2025-03-26"
      assert Versions.negotiate("1999-01-01") == "2025-03-26"
    end

    test "is read at call time" do
      assert Versions.supported?("2025-11-25")
      put_env(:mcp_protocol_versions, ["2025-03-26"])
      refute Versions.supported?("2025-11-25")
      Application.delete_env(:phoenix_kit, :mcp_protocol_versions)
      assert Versions.supported?("2025-11-25")
    end

    test "a repeated entry counts once" do
      put_env(:mcp_protocol_versions, ["2025-06-18", "2025-06-18"])
      assert Versions.supported() == ["2025-06-18"]
    end

    test "an unknown entry is ignored, with one warning for the node and no value in it" do
      put_env(:mcp_protocol_versions, ["2025-06-18", "2026-07-28", "secret-looking-entry"])

      log =
        capture_log(fn ->
          for _ <- 1..5, do: assert(Versions.supported() == ["2025-06-18"])
          assert Versions.supported?("2025-06-18")
        end)

      assert count(log, ":mcp_protocol_versions has an entry") == 1
      refute log =~ "2026-07-28"
      refute log =~ "secret-looking-entry"
    end

    test "an empty list falls back to every known revision, with one warning" do
      put_env(:mcp_protocol_versions, [])

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert(Versions.supported() == Versions.known())
        end)

      assert count(log, "enables no known MCP revision") == 1
    end

    test "a list of nothing but unknown entries falls back too" do
      put_env(:mcp_protocol_versions, ["2026-07-28"])

      log = capture_log(fn -> assert Versions.supported() == Versions.known() end)

      assert log =~ "enables no known MCP revision"
      assert log =~ "not a known MCP revision"
      refute log =~ "2026-07-28"
    end

    test "something that is not a list falls back, with one warning" do
      put_env(:mcp_protocol_versions, "2025-06-18")

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert(Versions.supported() == Versions.known())
        end)

      assert count(log, "not a list of revisions") == 1
    end
  end

  describe ":mcp_extra_revisions" do
    test "adds a revision to the table, newest first, with the flags it names" do
      put_env(:mcp_extra_revisions, [
        {"2027-01-01", %{structured_content: true, tool_title: true}}
      ])

      assert Versions.known() == ["2027-01-01", "2025-11-25", "2025-06-18", "2025-03-26"]
      assert Versions.supported() == Versions.known()
      assert Versions.latest() == "2027-01-01"
      assert Versions.negotiate("2027-01-01") == "2027-01-01"

      assert Versions.profile("2027-01-01") == %{
               structured_content: true,
               output_schema: false,
               tool_title: true,
               server_title: false
             }
    end

    test "takes flags as a keyword list too" do
      put_env(:mcp_extra_revisions, [{"2027-01-01", [output_schema: true]}])

      assert Versions.feature?("2027-01-01", :output_schema)
      refute Versions.feature?("2027-01-01", :tool_title)
    end

    test ":mcp_protocol_versions can keep serving the old ones while the new one is in the table" do
      put_env(:mcp_extra_revisions, [{"2027-01-01", %{structured_content: true}}])
      put_env(:mcp_protocol_versions, ["2025-11-25", "2025-06-18"])

      assert Versions.supported() == ["2025-11-25", "2025-06-18"]
      assert Versions.known() |> hd() == "2027-01-01"
      assert Versions.negotiate("2027-01-01") == "2025-11-25"
    end

    test "a built-in revision is not overridden" do
      put_env(:mcp_extra_revisions, [
        {"2025-03-26", %{structured_content: true, output_schema: true}}
      ])

      refute Versions.feature?("2025-03-26", :structured_content)
      assert Versions.known() == ["2025-11-25", "2025-06-18", "2025-03-26"]
    end

    test "a bad entry is ignored with one warning, and the good ones stay" do
      put_env(:mcp_extra_revisions, [
        {"2027-01-01", %{tool_title: true}},
        {"tomorrow", %{}},
        {"2027-02-02", :on},
        :nonsense
      ])

      log =
        capture_log(fn ->
          for _ <- 1..3, do: assert(hd(Versions.known()) == "2027-01-01")
          assert length(Versions.known()) == 4
        end)

      assert count(log, ":mcp_extra_revisions has an entry") == 1
      refute log =~ "tomorrow"
    end

    test "something that is not a list is ignored" do
      put_env(:mcp_extra_revisions, %{"2027-01-01" => %{}})

      log =
        capture_log(fn ->
          assert Versions.known() == ["2025-11-25", "2025-06-18", "2025-03-26"]
        end)

      assert log =~ ":mcp_extra_revisions is not a list"
    end
  end
end
