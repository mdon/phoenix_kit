defmodule PhoenixKit.Install.EndpointIntegrationTest do
  @moduledoc """
  `EndpointIntegration.add_body_guard/1`: the installer step that puts
  `PhoenixKit.API.BodyGuard` ahead of `Plug.Parsers` in the host endpoint, on
  `mix phoenix_kit.install` and on `mix phoenix_kit.update`.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.EndpointIntegration

  @endpoint_file "lib/my_app_web/endpoint.ex"

  # What `mix phx.new` generates, trimmed.
  @generated_endpoint """
  defmodule MyAppWeb.Endpoint do
    use Phoenix.Endpoint, otp_app: :my_app

    plug Plug.Static,
      at: "/",
      from: :my_app,
      gzip: false

    plug Plug.RequestId
    plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

    plug Plug.Parsers,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library()

    plug Plug.MethodOverride
    plug Plug.Head
    plug Plug.Session, @session_options
    plug MyAppWeb.Router
  end
  """

  defp project(content \\ @generated_endpoint) do
    test_project(app_name: :my_app, files: %{@endpoint_file => content})
  end

  defp endpoint_source(igniter) do
    igniter.rewrite |> Rewrite.source!(@endpoint_file) |> Rewrite.Source.get(:content)
  end

  # The formatter in a bare test project writes `plug(X)`, a host with
  # `import_deps: [:phoenix]` keeps `plug X`; both are one plug call.
  defp plug_calls(source) do
    ~r/plug\(?\s*([A-Z][\w.]*)/
    |> Regex.scan(source, capture: :all_but_first)
    |> List.flatten()
  end

  defp warned?(igniter), do: Enum.any?(igniter.warnings, &(&1 =~ "PhoenixKit.API.BodyGuard"))

  test "adds the plug immediately before Plug.Parsers" do
    igniter = project() |> EndpointIntegration.add_body_guard() |> apply_igniter!()

    calls = igniter |> endpoint_source() |> plug_calls()

    assert Enum.slice(calls, 0, 5) == [
             "Plug.Static",
             "Plug.RequestId",
             "Plug.Telemetry",
             "PhoenixKit.API.BodyGuard",
             "Plug.Parsers"
           ]

    refute warned?(igniter)
  end

  test "leaves the rest of the endpoint as it was" do
    source =
      project() |> EndpointIntegration.add_body_guard() |> apply_igniter!() |> endpoint_source()

    assert source =~ "use Phoenix.Endpoint, otp_app: :my_app"
    assert source =~ "json_decoder: Phoenix.json_library()"
    assert source =~ "MyAppWeb.Router"
  end

  test "is idempotent: a second run changes nothing" do
    once = project() |> EndpointIntegration.add_body_guard() |> apply_igniter!()
    twice = once |> EndpointIntegration.add_body_guard() |> apply_igniter!()

    assert endpoint_source(once) == endpoint_source(twice)
    assert length(Regex.scan(~r/PhoenixKit\.API\.BodyGuard/, endpoint_source(twice))) == 1
  end

  test "an endpoint that already has the plug, anywhere, is left alone" do
    already =
      String.replace(
        @generated_endpoint,
        "plug Plug.MethodOverride",
        "plug PhoenixKit.API.BodyGuard\n  plug Plug.MethodOverride"
      )

    igniter = project(already) |> EndpointIntegration.add_body_guard()

    assert endpoint_source(igniter) == already
    refute warned?(igniter)
  end

  test "finds Plug.Parsers written with parentheses" do
    content =
      String.replace(
        @generated_endpoint,
        ~r/plug Plug.Parsers,.*?json_decoder: Phoenix.json_library\(\)/s,
        "plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)"
      )

    calls =
      project(content)
      |> EndpointIntegration.add_body_guard()
      |> apply_igniter!()
      |> endpoint_source()
      |> plug_calls()

    guard = Enum.find_index(calls, &(&1 == "PhoenixKit.API.BodyGuard"))
    parsers = Enum.find_index(calls, &(&1 == "Plug.Parsers"))
    assert guard + 1 == parsers
  end

  test "finds Plug.Parsers that takes its options from a module attribute" do
    content =
      @generated_endpoint
      |> String.replace(
        ~r/plug Plug.Parsers,.*?json_decoder: Phoenix.json_library\(\)/s,
        "plug Plug.Parsers, @parsers"
      )
      |> String.replace(
        "plug Plug.Static",
        "@parsers [parsers: [:json], json_decoder: Jason]\n\n  plug Plug.Static"
      )

    calls =
      project(content)
      |> EndpointIntegration.add_body_guard()
      |> apply_igniter!()
      |> endpoint_source()
      |> plug_calls()

    assert "PhoenixKit.API.BodyGuard" in calls
  end

  test "warns, and changes nothing, when the endpoint has no Plug.Parsers" do
    content = """
    defmodule MyAppWeb.Endpoint do
      use Phoenix.Endpoint, otp_app: :my_app

      plug MyAppWeb.Router
    end
    """

    igniter = project(content) |> EndpointIntegration.add_body_guard()

    assert warned?(igniter)
    assert igniter.warnings |> Enum.join("\n") =~ "before `plug Plug.Parsers`"
    refute endpoint_source(igniter) =~ "BodyGuard"
  end

  test "warns when there is no endpoint at the conventional place" do
    igniter = test_project(app_name: :my_app, files: %{}) |> EndpointIntegration.add_body_guard()

    assert warned?(igniter)
  end

  test "stays silent in PhoenixKit's own project, whose endpoint carries the plug in source" do
    igniter =
      test_project(app_name: :phoenix_kit, files: %{}) |> EndpointIntegration.add_body_guard()

    refute warned?(igniter)
  end
end
