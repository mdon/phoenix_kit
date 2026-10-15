defmodule PhoenixKit.API.KeyTestSupport.FakeModule do
  @moduledoc """
  A stand-in feature module that declares API tools, for the key tests.

  Registered with `PhoenixKit.ModuleRegistry` by
  `PhoenixKit.API.KeyTestSupport.register_fake_module!/0`. Every permission is a
  core one (`media`, `media.manage`, `jobs.manage`), because core's own test
  environment does not load the shop, catalogue or warehouse packages.
  """

  alias PhoenixKit.API.Tool

  def module_key, do: "apikeytest"
  def module_name, do: "API key test module"
  def enabled?, do: true

  def api_tools do
    [
      admin_tool("list_things", "apikeytest.things:read", "media"),
      admin_tool("set_things", "apikeytest.things:write", "media.manage"),
      admin_tool("run_jobs", "apikeytest.jobs:run", "jobs.manage"),
      Tool.new!(%{
        name: "apikeytest.public_thing",
        audience: :public,
        title: "Public thing",
        description: "A public tool, which names neither a scope nor a permission.",
        input_schema: schema(),
        output_schema: schema(),
        handler: {__MODULE__, :handle}
      })
    ]
  end

  def handle(_input, _ctx), do: {:ok, %{}}

  defp admin_tool(verb, scope, permission) do
    Tool.new!(%{
      name: "apikeytest." <> verb,
      audience: :admin,
      scope: scope,
      permission: permission,
      title: String.capitalize(verb),
      description: "Test tool #{verb}.",
      input_schema: schema(),
      output_schema: schema(),
      handler: {__MODULE__, :handle}
    })
  end

  defp schema, do: %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
end
