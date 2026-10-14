defmodule PhoenixKit.API.OutputShape do
  @moduledoc """
  The output schema a client is told a tool answers with: MCP's `outputSchema`
  and the `200` response of the OpenAPI document.

  A read-only tool answers with its own `output_schema`. Any other tool (a
  write tool, `PhoenixKit.API.ControlFields.write_tool?/1`) may answer with a
  **preview** instead: a dry run, a confirmation request or a pending approval.
  Its schema is therefore
  `{"type": "object", "anyOf": [success, preview]}`. It is `anyOf`, not
  `oneOf`, because a preview also satisfies a success schema that does not
  forbid extra properties, which would make `oneOf` reject it. The root keeps
  `"type": "object"` because MCP client libraries require an object schema
  there.

  A tool with no `output_schema` has no output shape. Keys are turned into
  strings at every depth and the root is forced to `"type": "object"` (a tool
  answers with a map); the rest of the schema is passed through as declared,
  `PhoenixKit.API.ToolLint` is what checks that it is sound.
  """

  alias PhoenixKit.API.ControlFields
  alias PhoenixKit.API.Tool

  @preview_shape %{
    "type" => "object",
    "description" =>
      "The call changed nothing and is not finished. A dry run (send the call again without dry_run), " <>
        "a request for confirmation (send the same arguments with the confirm_token) or a pending " <>
        "approval (poll system.get_approval with the approval_id until a person has decided).",
    "required" => ["executed"],
    "properties" => %{
      "executed" => %{"type" => "boolean", "enum" => [false]},
      "preview" => %{"type" => "object"},
      "confirm_token" => %{"type" => "string"},
      "expires_at" => %{"type" => "string"},
      "expires_in_seconds" => %{"type" => "integer"},
      "approval_id" => %{"type" => "string"},
      "dry_run" => %{"type" => "boolean"},
      "status" => %{"type" => "string", "enum" => ["confirmation_required", "pending_approval"]}
    }
  }

  @doc "The schema of a preview or approval answer."
  @spec preview_shape() :: map()
  def preview_shape, do: @preview_shape

  @doc "The output schema to show for `tool`, with string keys, or `nil` when the tool has none."
  @spec for_tool(Tool.t()) :: map() | nil
  def for_tool(%Tool{output_schema: nil}), do: nil

  def for_tool(%Tool{output_schema: schema} = tool) do
    success = schema |> stringify() |> Map.put("type", "object")

    if ControlFields.write_tool?(tool),
      do: %{"type" => "object", "anyOf" => [success, @preview_shape]},
      else: success
  end

  defp stringify(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
