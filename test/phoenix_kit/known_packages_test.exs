defmodule PhoenixKit.KnownPackagesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.KnownPackages

  @stub_name :"PhoenixKit.KnownPackagesTest.Stub"

  @hex_newsletters %{
    "name" => "phoenix_kit_newsletters",
    "latest_version" => "0.3.1",
    "meta" => %{
      "description" => "Email newsletters. hex_docs_icon_name: hero-newspaper"
    }
  }

  @hex_posts %{
    "name" => "phoenix_kit_posts",
    "latest_version" => "0.2.0",
    "meta" => %{"description" => "Blog posts and tags. hex_docs_icon_name: hero-pencil-square"}
  }

  @hex_phoenix_kit %{
    "name" => "phoenix_kit",
    "latest_version" => "1.7.0",
    "meta" => %{"description" => "The core library."}
  }

  setup do
    KnownPackages.clear_cache()
    original_extras = Application.get_env(:phoenix_kit, :extra_known_packages, [])

    Application.put_env(:phoenix_kit, :_known_packages_req_opts,
      plug: {Req.Test, @stub_name},
      receive_timeout: 3000
    )

    on_exit(fn ->
      KnownPackages.clear_cache()
      Application.put_env(:phoenix_kit, :extra_known_packages, original_extras)
      Application.delete_env(:phoenix_kit, :_known_packages_req_opts)
    end)

    :ok
  end

  defp stub_hex(packages) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(packages))
    end)
  end

  describe "list/0 happy path" do
    test "returns shaped entries from Hex" do
      stub_hex([@hex_newsletters, @hex_posts])

      packages = KnownPackages.list()

      assert length(packages) == 2

      newsletters = Enum.find(packages, &(&1.package == "phoenix_kit_newsletters"))
      assert newsletters.key == "newsletters"
      assert newsletters.name == "Newsletters"
      assert newsletters.description == "Email newsletters."
      assert newsletters.icon == "hero-newspaper"
      assert newsletters.hex_url == "https://hex.pm/packages/phoenix_kit_newsletters"
      assert newsletters.source == "hex"
    end

    test "filters out phoenix_kit core package" do
      stub_hex([@hex_phoenix_kit, @hex_newsletters])

      packages = KnownPackages.list()

      package_names = Enum.map(packages, & &1.package)
      refute "phoenix_kit" in package_names
      assert "phoenix_kit_newsletters" in package_names
    end

    test "entry without icon marker gets default icon" do
      pkg = %{
        "name" => "phoenix_kit_crm",
        "latest_version" => "0.1.0",
        "meta" => %{"description" => "CRM module without marker"}
      }

      stub_hex([pkg])

      packages = KnownPackages.list()

      crm = Enum.find(packages, &(&1.package == "phoenix_kit_crm"))
      assert crm.icon == "hero-puzzle-piece"
      assert crm.description == "CRM module without marker"
    end

    test "humanizes multi-word package key" do
      pkg = %{
        "name" => "phoenix_kit_customer_support",
        "latest_version" => "0.1.0",
        "meta" => %{"description" => "Customer support tools."}
      }

      stub_hex([pkg])

      packages = KnownPackages.list()

      support = Enum.find(packages, &(&1.package == "phoenix_kit_customer_support"))
      assert support.name == "Customer Support"
    end
  end

  describe "caching" do
    test "second call does not re-hit Hex (cache hit)" do
      call_count = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([@hex_newsletters]))
      end)

      KnownPackages.list()
      KnownPackages.list()

      assert :counters.get(call_count, 1) == 1
    end

    test "after clear_cache/0 a new fetch happens" do
      call_count = :counters.new(1, [])

      Req.Test.stub(@stub_name, fn conn ->
        :counters.add(call_count, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!([@hex_newsletters]))
      end)

      KnownPackages.list()
      KnownPackages.clear_cache()
      KnownPackages.list()

      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "Hex failure handling" do
    test "Hex 500 returns no Hex-sourced entries with Logger.warning" do
      Req.Test.stub(@stub_name, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      log =
        capture_log(fn ->
          result = KnownPackages.list()
          refute Enum.any?(result, &(&1.source == "hex"))
        end)

      assert log =~ "Hex fetch failed"
    end

    test "Hex transport error returns list with Logger.warning" do
      Req.Test.stub(@stub_name, fn _conn ->
        raise "connection refused"
      end)

      log =
        capture_log(fn ->
          result = KnownPackages.list()
          assert is_list(result)
        end)

      assert log =~ "Hex fetch failed"
    end
  end

  describe "pagination" do
    test "fetches multiple pages via Link header" do
      page2_pkg = %{
        "name" => "phoenix_kit_crm",
        "latest_version" => "0.1.0",
        "meta" => %{"description" => "CRM module."}
      }

      page2_url = "https://hex.pm/api/packages?search=phoenix_kit_&sort=name&page=2"

      Req.Test.stub(@stub_name, fn conn ->
        {packages, add_link} =
          if String.contains?(conn.request_path <> "?" <> (conn.query_string || ""), "page=2") do
            {[page2_pkg], false}
          else
            {[@hex_newsletters], true}
          end

        conn =
          if add_link do
            Plug.Conn.put_resp_header(conn, "link", "<#{page2_url}>; rel=\"next\"")
          else
            conn
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(packages))
      end)

      packages = KnownPackages.list()

      package_names = Enum.map(packages, & &1.package)
      assert "phoenix_kit_newsletters" in package_names
      assert "phoenix_kit_crm" in package_names
    end
  end

  describe "extra_known_packages config" do
    test "valid config entries appear in result" do
      Application.put_env(:phoenix_kit, :extra_known_packages, [
        %{
          key: "private_billing",
          package: "my_app_billing",
          name: "Private Billing",
          description: "Internal billing module",
          icon: "hero-credit-card",
          hex_url: "https://hex.pm/packages/my_app_billing"
        }
      ])

      stub_hex([])

      packages = KnownPackages.list()

      billing = Enum.find(packages, &(&1.package == "my_app_billing"))
      assert billing != nil
      assert billing.source == "config"
      assert billing.name == "Private Billing"
    end

    test "config entry wins over Hex entry with same package" do
      Application.put_env(:phoenix_kit, :extra_known_packages, [
        %{
          key: "newsletters",
          package: "phoenix_kit_newsletters",
          name: "Newsletters (custom)",
          description: "Overridden via config",
          icon: "hero-star",
          hex_url: "https://hex.pm/packages/phoenix_kit_newsletters"
        }
      ])

      stub_hex([@hex_newsletters])

      packages = KnownPackages.list()

      newsletters_entries = Enum.filter(packages, &(&1.package == "phoenix_kit_newsletters"))
      assert length(newsletters_entries) == 1
      assert hd(newsletters_entries).name == "Newsletters (custom)"
      assert hd(newsletters_entries).source == "config"
    end
  end
end
