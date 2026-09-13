defmodule PhoenixKit.Users.OAuthConfigGoogleLiveCheckTest do
  @moduledoc """
  Pins the request shape `OAuthConfig.google_live_check/2` sends to Google's
  token endpoint, via a `Req.Test` stub, instead of a real network call.

  The MAJOR bug this guards against: the check used to send a `redirect_uri`
  Google's own OAuth 2.0 policy rejects outright (an RFC 2606 `.invalid`
  host, not on the public suffix list), which made Google answer
  `invalid_request` for every credential pair — right or wrong — before it
  ever evaluated client_id/client_secret. No `redirect_uri` should be sent.

  Separate module, `async: false`, and `Req.Test` mode is set to `:shared`
  (not the default per-process `:private` ownership) — the actual HTTP call
  happens inside `PhoenixKit.Integrations.Probe.run/2`'s spawned, linked
  child process, not this test process, so per-process stub ownership would
  not reach it.
  """
  use ExUnit.Case, async: false

  alias PhoenixKit.Users.OAuthConfig

  @stub_name :"PhoenixKit.Users.OAuthConfigGoogleLiveCheckTest.Stub"

  setup do
    Req.Test.set_req_test_to_shared()
    :ok
  end

  test "sends no redirect_uri — Google rejects a non-registered one regardless of the credentials" do
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      send(test_pid, {:captured_params, params})

      Req.Test.json(conn, %{"error" => "invalid_grant"})
    end)

    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:ok, message} =
             OAuthConfig.test_connection(:google, credentials, plug: {Req.Test, @stub_name})

    assert message =~ "accepted"

    assert_receive {:captured_params, params}
    refute Map.has_key?(params, "redirect_uri")
    assert params["client_id"] == credentials.client_id
    assert params["client_secret"] == credentials.client_secret
    assert params["grant_type"] == "authorization_code"
  end
end
