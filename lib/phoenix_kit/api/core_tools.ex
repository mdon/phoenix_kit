defmodule PhoenixKit.API.CoreTools do
  @moduledoc """
  The tools core itself provides, in the `system` namespace.

  They need no module and no scope: every valid key may call them.
  `system.get_identity` answers "who am I and what may I do" and is the first
  thing to call when setting a key up.
  """

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.Users.Auth

  @doc "The tools core declares; `PhoenixKit.API.Registry` adds them to every module's."
  @spec tools() :: [Tool.t()]
  def tools do
    [
      Tool.new!(
        name: "system.get_identity",
        audience: :admin,
        scope: nil,
        permission: nil,
        title: "Get identity",
        description:
          "Returns the API key making the call, the user that owns it, the scopes " <>
            "the key effectively holds right now and the tools those scopes unlock. " <>
            "Scopes the owner has lost since the key was created are not listed.",
        input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        output_schema: output_schema(),
        handler: {__MODULE__, :get_identity},
        annotations: %{read_only: true, destructive: false, idempotent: true, open_world: false}
      )
    ]
  end

  @doc """
  Handler of `system.get_identity`.

  Returns `{:ok, map}` with `key` (`prefix`, `name`, `expires_at`,
  `requires_approval`), `owner` (`id`, `email`, `service_user`), `scopes`
  (the effective scopes) and `tools` (`name`, `scope`, `read_only` of every
  tool they unlock).
  """
  @spec get_identity(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def get_identity(_input, %{actor: actor, scopes: scopes, audience: audience}) do
    key = Keys.get_key(actor.key_uuid)
    owner = actor.user_uuid && Auth.get_user(actor.user_uuid)

    {:ok,
     %{
       "key" => key_info(key, actor),
       "owner" => owner_info(owner, actor),
       "scopes" => scopes,
       "tools" => tool_info(audience, scopes)
     }}
  end

  defp key_info(nil, actor), do: %{"prefix" => actor.key_prefix}

  defp key_info(key, _actor) do
    %{
      "prefix" => key.prefix,
      "name" => key.name,
      "expires_at" => key.expires_at && DateTime.to_iso8601(key.expires_at),
      "requires_approval" => key.requires_approval
    }
  end

  defp owner_info(nil, actor), do: %{"id" => actor.user_uuid}

  defp owner_info(owner, _actor) do
    %{
      "id" => owner.uuid,
      "email" => owner.email,
      "service_user" => owner.api_only == true
    }
  end

  defp tool_info(audience, scopes) do
    audience
    |> Registry.visible_tools(scopes)
    |> Enum.map(fn tool ->
      %{
        "name" => tool.name,
        "scope" => tool.scope,
        "read_only" => tool.annotations[:read_only] == true
      }
    end)
  end

  defp output_schema do
    %{
      "type" => "object",
      "required" => ["key", "owner", "scopes", "tools"],
      "properties" => %{
        "key" => %{"type" => "object"},
        "owner" => %{"type" => "object"},
        "scopes" => %{"type" => "array", "items" => %{"type" => "string"}},
        "tools" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }
  end
end
