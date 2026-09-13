defmodule PhoenixKit.Users.OAuthConfigGoogleLiveCheckTest do
  @moduledoc """
  End-to-end coverage of `OAuthConfig.test_connection/3`'s Google path
  through `google_live_check/2`, via a `Req.Test` stub instead of a real
  network call — request shape sent, and all four response outcomes.

  The MAJOR bug this guards against: the check used to send a `redirect_uri`
  that fails Google's "Host TLDs must belong to the public suffix list"
  redirect-URI rule (an RFC 2606 `.invalid` host), which made Google answer
  `invalid_request` — verified live with fabricated, wrong credentials, not
  with a real registered app — instead of a real invalid_client/invalid_grant
  verdict, regardless of whether the credentials happened to be right. No
  `redirect_uri` should be sent.

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

  defp req_opts, do: [plug: {Req.Test, @stub_name}]

  test "sends no redirect_uri, and the given client_id/client_secret/grant_type verbatim" do
    test_pid = self()

    Req.Test.stub(@stub_name, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      send(test_pid, {:captured_params, params})

      Req.Test.json(conn, %{"error" => "invalid_grant"})
    end)

    # test_connection/3 itself does no trimming — that is
    # `PhoenixKitWeb.Live.Settings.Authorization`'s job, before it ever
    # builds this credentials map (see `trim_oauth_secrets/1` and
    # `trim_credential/1` there) — so whatever is passed in goes out as-is.
    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:ok, _message} = OAuthConfig.test_connection(:google, credentials, req_opts())

    assert_receive {:captured_params, params}
    refute Map.has_key?(params, "redirect_uri")
    assert params["client_id"] == credentials.client_id
    assert params["client_secret"] == credentials.client_secret
    assert params["grant_type"] == "authorization_code"
  end

  test "invalid_client is reported as an outright rejection" do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => "invalid_client"})
    end)

    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:error, message} = OAuthConfig.test_connection(:google, credentials, req_opts())
    assert message =~ "invalid_client"
  end

  test "invalid_grant is reported as an acceptance" do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_grant"})
    end)

    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:ok, message} = OAuthConfig.test_connection(:google, credentials, req_opts())
    assert message =~ "accepted"
  end

  test "invalid_request is reported as inconclusive, not as a rejection" do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => "invalid_request"})
    end)

    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:inconclusive, message} =
             OAuthConfig.test_connection(:google, credentials, req_opts())

    assert message =~ "inconclusive"
  end

  test "a transport failure is reported as inconclusive, not as a rejection" do
    Req.Test.stub(@stub_name, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    credentials = %{client_id: "some-client-id", client_secret: "some-client-secret-value"}

    assert {:inconclusive, message} =
             OAuthConfig.test_connection(:google, credentials, req_opts())

    assert message =~ "reach"
  end
end
