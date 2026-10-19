defmodule PhoenixKit.Users.Auth.SessionRef do
  @moduledoc """
  A live browser session as an actor, for code that runs on a person's behalf without a
  `Plug.Conn` (an assistant LiveView, a task it starts).

  A session is referred to by `{session_token_uuid, user_uuid}`: the `uuid` of its row in
  `phoenix_kit_users_tokens` and the user it belongs to. Neither is a secret, so the pair
  may travel in the signed (but not encrypted) session map of a nested LiveView; the raw
  session token must not, and never leaves the cookie session.

  `scope_for_session/2` rebuilds the user's `PhoenixKit.Users.Auth.Scope` from that row
  on every call, by the rules a web request follows
  (`PhoenixKit.Users.Auth.UserToken.verify_session_token_uuid_query/1`): the row is a
  `"session"` row and has not expired, its user is not a service user, and the scope is
  narrowed to the role this session acts as (`PhoenixKit.Users.ActiveRole`). Logging out,
  revoking the session or blocking the user takes effect on the next call.

  `from_session/1` reads the reference from a LiveView's session map.
  """

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserToken
  alias PhoenixKit.Utils.UUID, as: UUIDUtils

  @typedoc "`{session_token_uuid, user_uuid}`."
  @type t :: {String.t(), String.t()}

  @typedoc """
  Why a session cannot act: `:session_gone` (no such live session: logged out, revoked,
  expired, not a session row, or a service user's), `:mismatch` (the session belongs to
  another user) or `:inactive` (the user is blocked).
  """
  @type refusal :: :session_gone | :mismatch | :inactive

  @doc """
  The scope of the live session `session_token_uuid`, which must belong to `user_uuid`.

  Returns `{:ok, scope}` narrowed to the session's active role, or `{:error, reason}`
  (`t:refusal/0`). Never raises on a malformed reference.
  """
  @spec scope_for_session(term(), term()) :: {:ok, Scope.t()} | {:error, refusal()}
  def scope_for_session(session_token_uuid, user_uuid) do
    with {:ok, %User{} = user} <- session_user(session_token_uuid),
         :ok <- same_user(user, user_uuid),
         %User{} = active <- Auth.ensure_active_user(user) || {:error, :inactive} do
      {:ok, Scope.for_user(active)}
    end
  end

  @doc """
  The reference of the session a LiveView runs in, read from its session map: the
  `"user_token"` of the cookie session resolved to `{session_token_uuid, user_uuid}`.
  `:error` when there is no token or it is not a live session.
  """
  @spec from_session(map()) :: {:ok, t()} | :error
  def from_session(%{"user_token" => token}) when is_binary(token) do
    case Auth.get_session_token_record(token) do
      %UserToken{uuid: uuid, user_uuid: user_uuid} when is_binary(user_uuid) ->
        {:ok, {uuid, user_uuid}}

      _none ->
        :error
    end
  end

  def from_session(_session), do: :error

  defp session_user(token_uuid) do
    if UUIDUtils.valid?(token_uuid) do
      {:ok, query} = UserToken.verify_session_token_uuid_query(token_uuid)

      case RepoHelper.repo().one(query) do
        %User{} = user -> {:ok, user}
        nil -> {:error, :session_gone}
      end
    else
      {:error, :session_gone}
    end
  end

  defp same_user(%User{uuid: uuid}, uuid), do: :ok
  defp same_user(%User{}, _user_uuid), do: {:error, :mismatch}
end
