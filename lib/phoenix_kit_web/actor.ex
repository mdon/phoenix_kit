defmodule PhoenixKitWeb.Actor do
  @moduledoc """
  Who is acting, read from a LiveView socket, a `Plug.Conn` or an assigns
  map — the one place modules ask, instead of each reading its own assign.

  The admin `live_session` puts both `:phoenix_kit_current_scope` and
  `:phoenix_kit_current_user` on the socket. The scope is the canonical
  one (it is what permission checks read), so it wins; the bare user is
  the fallback for callers that only have that — a test harness, a plain
  controller. Modules used to pick one or the other, so the same action
  could log an actor in one module and none in the next.

      PhoenixKit.Activity.log("crm", "crm.company_updated",
        PhoenixKitWeb.Actor.opts(socket) ++ [resource_uuid: company.uuid])
  """

  alias PhoenixKit.Users.Auth.Scope

  @typedoc "Anything that knows who is acting."
  @type source :: Phoenix.LiveView.Socket.t() | Plug.Conn.t() | Scope.t() | map() | nil

  @doc """
  The acting user's uuid, or `nil` when nobody is signed in.

      PhoenixKitWeb.Actor.uuid(socket)
      PhoenixKitWeb.Actor.uuid(conn)
      PhoenixKitWeb.Actor.uuid(scope)
      PhoenixKitWeb.Actor.uuid(%{phoenix_kit_current_user: user})
  """
  @spec uuid(source()) :: String.t() | nil
  def uuid(%Scope{user: user}), do: user_uuid(user)
  def uuid(%{assigns: %{} = assigns}), do: uuid(assigns)

  def uuid(%{} = assigns) do
    case Map.get(assigns, :phoenix_kit_current_scope) do
      %Scope{} = scope -> uuid(scope)
      _ -> nil
    end || user_uuid(Map.get(assigns, :phoenix_kit_current_user))
  end

  def uuid(_), do: nil

  @doc """
  `[actor_uuid: uuid]` for a context call that logs, or `[]` when nobody
  is signed in — so it can be appended to other options as is.
  """
  @spec opts(source()) :: keyword()
  def opts(source) do
    case uuid(source) do
      nil -> []
      uuid -> [actor_uuid: uuid]
    end
  end

  @doc """
  The acting user's first role name (not PII), or `nil` — for audit
  metadata that wants to say which role acted.
  """
  @spec role(source()) :: String.t() | nil
  def role(%Scope{} = scope) do
    case Scope.user_roles(scope) do
      [role | _] when is_binary(role) -> role
      _ -> nil
    end
  end

  def role(%{assigns: %{} = assigns}), do: role(assigns)
  def role(%{} = assigns), do: role(Map.get(assigns, :phoenix_kit_current_scope))

  def role(_), do: nil

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil
end
