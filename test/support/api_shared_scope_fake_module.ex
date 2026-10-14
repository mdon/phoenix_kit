defmodule PhoenixKit.API.KeyTestSupport.SharedScopeModule do
  @moduledoc """
  A stand-in feature module whose two admin tools declare the SAME scope but need
  different permissions (`media` and `jobs.manage`), for the tests that pin how a
  shared scope is granted: only to an owner who holds every permission behind it.
  """

  alias PhoenixKit.API.Tool

  def module_key, do: "apishared"
  def module_name, do: "API shared scope test module"
  def enabled?, do: true

  def scope, do: "apishared.things:read"

  def api_tools do
    [tool("read_a", "media"), tool("read_b", "jobs.manage")]
  end

  def handle(_input, _ctx), do: {:ok, %{}}

  defp tool(verb, permission) do
    Tool.new!(%{
      name: "apishared." <> verb,
      audience: :admin,
      scope: scope(),
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
