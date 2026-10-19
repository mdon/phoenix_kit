defmodule PhoenixKitWeb.Users.SessionRefMountTest do
  @moduledoc """
  How a LiveView rendered beside the page (a sticky `live_render`) learns which browser
  session it runs in: on mount it reads the cookie session's `"user_token"` and keeps
  only the id of the token row and its user (`SessionRef.from_session/1`), plus whether
  the active account is borrowed (`MultiSession.impersonated?/1`). Neither value is a
  secret, so both may travel in the signed (not encrypted) session map of a nested
  LiveView; the raw token never leaves the cookie session.
  """
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.SessionRef
  alias PhoenixKitWeb.Users.MultiSession

  defmodule Probe do
    @moduledoc false
    use Phoenix.LiveView

    alias PhoenixKit.Users.Auth.SessionRef
    alias PhoenixKitWeb.Users.MultiSession

    def mount(_params, session, socket) do
      {token_uuid, user_uuid} =
        case SessionRef.from_session(session) do
          {:ok, {token_uuid, user_uuid}} -> {token_uuid, user_uuid}
          :error -> {"none", "none"}
        end

      {:ok,
       Phoenix.Component.assign(socket,
         token_uuid: token_uuid,
         user_uuid: user_uuid,
         impersonated: MultiSession.impersonated?(session)
       )}
    end

    def render(assigns) do
      ~H"""
      <div
        id="session-ref-probe"
        data-token-uuid={@token_uuid}
        data-user-uuid={@user_uuid}
        data-impersonated={to_string(@impersonated)}
      >
      </div>
      """
    end
  end

  defp user! do
    {:ok, user} =
      Auth.register_user(%{
        email: "session_ref_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    user
  end

  defp probe(conn, session) do
    {:ok, view, _html} =
      conn
      |> init_test_session(session)
      |> live_isolated(Probe)

    view
  end

  test "a signed-in session gives the token row's id and the user, not the token", %{
    conn: conn
  } do
    user = user!()
    token = Auth.generate_user_session_token(user)
    token_uuid = Auth.get_session_token_record(token).uuid

    view = probe(conn, %{"user_token" => token})

    assert has_element?(view, "#session-ref-probe[data-token-uuid='#{token_uuid}']")
    assert has_element?(view, "#session-ref-probe[data-user-uuid='#{user.uuid}']")
    assert has_element?(view, "#session-ref-probe[data-impersonated='false']")

    assert {:ok, scope} = SessionRef.scope_for_session(token_uuid, user.uuid)
    assert scope.user.uuid == user.uuid
  end

  test "a session whose active account is not the root of its stack is borrowed", %{
    conn: conn
  } do
    operator = user!()
    target = user!()
    root = Auth.generate_user_session_token(operator)
    borrowed = Auth.generate_user_session_token(target)

    view =
      probe(conn, %{"user_token" => borrowed, "pk_session_accounts" => [root, borrowed]})

    assert has_element?(view, "#session-ref-probe[data-user-uuid='#{target.uuid}']")
    assert has_element?(view, "#session-ref-probe[data-impersonated='true']")
  end

  test "an anonymous or logged-out session gives no reference", %{conn: conn} do
    user = user!()
    token = Auth.generate_user_session_token(user)
    :ok = Auth.delete_user_session_token(token)

    assert has_element?(probe(conn, %{}), "#session-ref-probe[data-token-uuid='none']")

    assert has_element?(
             probe(conn, %{"user_token" => token}),
             "#session-ref-probe[data-token-uuid='none']"
           )

    refute MultiSession.impersonated?(%{})
  end
end
