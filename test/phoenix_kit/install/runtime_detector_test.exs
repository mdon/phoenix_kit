defmodule PhoenixKit.Install.RuntimeDetectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKit.Install.RuntimeDetector

  # Mirrors a stock `mix phx.new` config/runtime.exs (Phoenix 1.7+/1.8):
  # `import Config` on line 1, `System.get_env` / `config_env()` later, no
  # `:dev` block. This is the file 2.13.6 wrote the Local adapter into.
  @phoenix_runtime """
  import Config

  # config/runtime.exs is executed for all environments, including
  # during releases. It is executed after compilation and before the
  # system starts, so it is typically used to load production configuration
  # and secrets from environment variables or elsewhere. Do not define
  # any compile-time configuration in here, as it won't be applied.

  # The block below contains prod specific runtime configuration.

  if System.get_env("PHX_SERVER") do
    config :artpixels, ArtpixelsWeb.Endpoint, server: true
  end

  if config_env() == :prod do
    config :artpixels, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  end
  """

  @phoenix_dev """
  import Config

  config :artpixels, ArtpixelsWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: 4000],
    check_origin: false,
    code_reloader: true,
    debug_errors: true,
    secret_key_base: "devsecret",
    watchers: []

  config :artpixels, dev_routes: true

  config :logger, :console, format: "[$level] $message\\n"

  config :phoenix, :plug_init_mode, :runtime

  config :swoosh, :api_client, false
  """

  @dev_mailer """
  # PhoenixKit mailer configuration
  if config_env() == :dev do
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
  end
  """

  # Exact shape 2.13.6 wrote: indented snippet spliced in as line 1,
  # pushing `import Config` down. The next boot then dies with
  # `undefined function config/3 (there is no such import)` at line 2.
  @buggy_216_prefix """

    # PhoenixKit mailer configuration
    config :phoenix_kit, PhoenixKit.Mailer,
      adapter: Swoosh.Adapters.Local
  """

  describe "detect_config_pattern/2" do
    test "a stock Phoenix 1.8 layout (simple dev.exs + runtime.exs) uses dev.exs" do
      assert RuntimeDetector.detect_config_pattern(@phoenix_runtime, @phoenix_dev) == :dev_exs
    end

    test "runtime.exs is chosen when there is no simple dev.exs" do
      assert RuntimeDetector.detect_config_pattern(@phoenix_runtime, nil) == :runtime
    end

    test "runtime.exs is chosen when dev.exs has complex conditionals" do
      complex_dev = """
      import Config

      if System.get_env("DOCKER") do
        config :artpixels, Artpixels.Repo, hostname: "db"
      else
        config :artpixels, Artpixels.Repo, hostname: "localhost"
      end
      """

      assert RuntimeDetector.detect_config_pattern(@phoenix_runtime, complex_dev) == :runtime
    end

    test "falls back to config.exs when neither file is usable" do
      assert RuntimeDetector.detect_config_pattern(nil, nil) == :config_exs
    end
  end

  describe "find_runtime_insertion_point_in/1" do
    test "inserts after import Config on a stock Phoenix runtime.exs, never at line 1" do
      # Line 1 is `import Config`. Inserting AT line 1 is the 2.13.6 bug.
      assert RuntimeDetector.find_runtime_insertion_point_in(@phoenix_runtime) == 2
    end

    test "skips a comment header above import Config" do
      content = """
      # runtime configuration
      import Config

      config :app, key: true
      """

      assert RuntimeDetector.find_runtime_insertion_point_in(content) == 3
    end
  end

  describe "insert_after_import_config/2" do
    test "never places a config call above import Config" do
      result = RuntimeDetector.insert_after_import_config(@phoenix_runtime, @dev_mailer)

      first_code =
        result
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))

      assert first_code == "import Config"
      assert result =~ "config :phoenix_kit, PhoenixKit.Mailer"
    end

    test "adds import Config when the file has none" do
      result =
        RuntimeDetector.insert_after_import_config("config :app, key: true\n", @dev_mailer)

      assert String.starts_with?(String.trim(result), "import Config")
      assert result =~ "config :app, key: true"
    end

    @tag :tmp_dir
    test "result is evaluable by Config.Reader in :dev and :prod", %{tmp_dir: tmp} do
      # Minimal runtime.exs: has System.get_env so it looks like Phoenix's,
      # but no SECRET_KEY_BASE raise, so both envs evaluate.
      runtime = """
      import Config

      if System.get_env("PHX_SERVER") do
        config :artpixels, ArtpixelsWeb.Endpoint, server: true
      end
      """

      result = RuntimeDetector.insert_after_import_config(runtime, @dev_mailer)
      path = Path.join(tmp, "runtime.exs")
      File.write!(path, result)

      dev_cfg = Config.Reader.read!(path, env: :dev)

      assert get_in(dev_cfg, [:phoenix_kit, PhoenixKit.Mailer]) ==
               [adapter: Swoosh.Adapters.Local]

      prod_cfg = Config.Reader.read!(path, env: :prod)
      refute get_in(prod_cfg, [:phoenix_kit, PhoenixKit.Mailer])
    end
  end

  describe "ensure_import_config_first/1" do
    test "is a no-op on a well-formed stock Phoenix runtime.exs" do
      assert RuntimeDetector.ensure_import_config_first(@phoenix_runtime) == @phoenix_runtime
    end

    test "is idempotent after a repair" do
      buggy = @buggy_216_prefix <> @phoenix_runtime
      once = RuntimeDetector.ensure_import_config_first(buggy)
      assert RuntimeDetector.ensure_import_config_first(once) == once
    end

    test "leaves a comment header above import Config alone" do
      content = """
      # runtime configuration
      import Config

      config :app, key: true
      """

      assert RuntimeDetector.ensure_import_config_first(content) == content
    end

    test "prepends import Config when the file has config calls and no import" do
      content = "config :app, key: true\n"
      result = RuntimeDetector.ensure_import_config_first(content)
      assert String.starts_with?(String.trim(result), "import Config")
      assert result =~ "config :app, key: true"
    end

    @tag :tmp_dir
    test "repairs the 2.13.6 line-1 insertion so Config.Reader can evaluate it", %{
      tmp_dir: tmp
    } do
      buggy = @buggy_216_prefix <> @phoenix_runtime
      path = Path.join(tmp, "runtime.exs")

      File.write!(path, buggy)

      # The original bug: config/3 is called before import Config.
      assert_raise CompileError, fn ->
        capture_io(:stderr, fn ->
          Config.Reader.read!(path, env: :dev)
        end)
      end

      repaired = RuntimeDetector.ensure_import_config_first(buggy)
      File.write!(path, repaired)

      first_code =
        repaired
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.find(&(&1 != "" and not String.starts_with?(&1, "#")))

      assert first_code == "import Config"
      assert repaired =~ "config :phoenix_kit, PhoenixKit.Mailer"

      cfg = Config.Reader.read!(path, env: :dev)

      assert get_in(cfg, [:phoenix_kit, PhoenixKit.Mailer]) ==
               [adapter: Swoosh.Adapters.Local]
    end

    @tag :tmp_dir
    test "wraps the 2.13.6 Local adapter so it does not apply in :prod", %{tmp_dir: tmp} do
      buggy =
        @buggy_216_prefix <>
          """
          import Config

          if System.get_env("PHX_SERVER") do
            config :artpixels, ArtpixelsWeb.Endpoint, server: true
          end
          """

      repaired =
        buggy
        |> RuntimeDetector.ensure_import_config_first()
        |> RuntimeDetector.wrap_unguarded_local_mailer()

      path = Path.join(tmp, "runtime.exs")
      File.write!(path, repaired)

      assert get_in(Config.Reader.read!(path, env: :dev), [:phoenix_kit, PhoenixKit.Mailer]) ==
               [adapter: Swoosh.Adapters.Local]

      refute get_in(Config.Reader.read!(path, env: :prod), [:phoenix_kit, PhoenixKit.Mailer])
    end
  end

  describe "wrap_unguarded_local_mailer/1" do
    test "is a no-op when the adapter is already behind config_env() == :dev" do
      content = """
      import Config

      #{@dev_mailer}
      """

      assert RuntimeDetector.wrap_unguarded_local_mailer(content) == content
    end
  end
end
