defmodule PhoenixKit.Integrations.ValidatorsTest do
  # async: false — one test swaps the global check deadline.
  use ExUnit.Case, async: false

  alias PhoenixKit.Integrations.Validators

  describe "aws_ses/1 refuses to guess" do
    test "a blank region is an error, not a silent probe of us-east-1" do
      # ExAws defaults a missing region to us-east-1, so without this guard the
      # check would pass against the wrong account/region while the send path
      # (which interpolates the region into the hostname) raises at send time.
      creds = %{"access_key" => "AKIA_T", "secret_key" => "S", "aws_region" => ""}
      assert {:error, message} = Validators.aws_ses(creds)
      assert message =~ "Region"
    end

    test "missing keys are reported without a network round trip" do
      assert {:error, _} = Validators.aws_ses(%{"aws_region" => "eu-central-1"})
    end
  end

  # AWS briefly answers a *correct* request with SignatureDoesNotMatch right after it
  # has rejected a bad signature from the same key — which is exactly what an operator
  # produces by pasting a wrong key, fixing it, and pressing Test again. Telling them
  # their good keys are invalid sends them off to reissue credentials that were never
  # the problem, so a verdict of "invalid" is confirmed before it is delivered.
  describe "the invalid-credentials verdict is confirmed before it is delivered" do
    test "a key that fails once and then succeeds is NOT called invalid" do
      requester = stub([{:invalid, "SignatureDoesNotMatch"}, :ok])

      assert :ok == Validators.request_send_quota("eu-central-1", %{}, requester)
    end

    test "a key that fails twice is called invalid" do
      requester = stub([{:invalid, "SignatureDoesNotMatch"}, {:invalid, "SignatureDoesNotMatch"}])

      assert {:error, message} = Validators.request_send_quota("eu-central-1", %{}, requester)
      assert message =~ "Invalid credentials"
    end

    test "a key that works is not retried" do
      requester = stub([:ok, {:invalid, "should never be asked for"}])

      assert :ok == Validators.request_send_quota("eu-central-1", %{}, requester)
    end

    test "a non-credential error is returned as-is, without a retry" do
      requester = stub([{:error, "AWS SES is busy"}, :ok])

      assert {:error, "AWS SES is busy"} =
               Validators.request_send_quota("eu-central-1", %{}, requester)
    end
  end

  describe "interpret_ses_error/1" do
    test "signature and token failures mean the credentials are wrong" do
      for code <- ~w(SignatureDoesNotMatch InvalidClientTokenId UnrecognizedClientException
                     InvalidAccessKeyId ExpiredToken TokenRefreshRequired) do
        assert {:invalid, ^code} = Validators.interpret_ses_error(aws_error(code))
      end
    end

    test "AccessDenied passes: the key is valid, it just cannot read the send quota" do
      # AWS's own least-privilege guidance grants only ses:SendEmail, which cannot
      # call GetSendQuota. A red cross on a correctly configured integration teaches
      # operators to ignore the check. (It does not prove the key can *send* — see
      # the module doc.)
      assert :ok == Validators.interpret_ses_error(aws_error("AccessDenied"))
      assert :ok == Validators.interpret_ses_error(aws_error("AccessDeniedException"))
    end

    test "throttling says so instead of blaming the credentials" do
      assert {:error, message} = Validators.interpret_ses_error(aws_error("Throttling"))
      assert message =~ "busy"
    end

    test "an unrecognised code is surfaced verbatim rather than guessed at" do
      assert {:error, message} = Validators.interpret_ses_error(aws_error("MessageRejected"))
      assert message =~ "MessageRejected"
    end

    test "a body with no code, and anything that is not an HTTP error, are transport failures" do
      assert {:error, message} =
               Validators.interpret_ses_error({:http_error, 500, %{body: "<html>502</html>"}})

      assert message =~ "Could not reach"
      assert {:error, _} = Validators.interpret_ses_error(:timeout)
    end
  end

  describe "smtp/1" do
    test "an unreachable relay is rejected" do
      # Nothing listens on port 1 — fails immediately, no outside network needed.
      creds = %{"host" => "127.0.0.1", "port" => "1", "username" => "u", "password" => "p"}
      assert {:error, _reason} = Validators.smtp(creds)
    end

    test "an unparseable port is reported as such" do
      creds = %{"host" => "127.0.0.1", "port" => "nope", "username" => "u", "password" => "p"}
      assert {:error, message} = Validators.smtp(creds)
      assert message =~ "port"
    end

    test "a relay that advertises no AUTH verb passes" do
      # An internal smarthost that authenticates by IP. Sending works there, so a red
      # cross would be a lie about a working relay — and the operator could not avoid
      # it, since username/password are required fields. `auth: :always` is what makes
      # a *wrong password* fail closed, so the no-AUTH case is carved out rather than
      # weakening it.
      port = relay_without_auth()

      creds = %{"host" => "127.0.0.1", "port" => port, "username" => "", "password" => ""}

      assert :ok == Validators.smtp(creds)
    end

    test "a tarpit relay is cut off at the deadline instead of hanging the caller" do
      # gen_smtp bounds only the TCP connect; every read after it waits on a
      # hard-coded 20-minute timeout, in the CALLING process. Both call sites are
      # LiveView callbacks, so without an outer deadline one silent relay parks a
      # LiveView process for twenty minutes.
      port = silent_relay()

      Application.put_env(:phoenix_kit, :integration_check_deadline, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :integration_check_deadline) end)

      creds = %{"host" => "127.0.0.1", "port" => port, "username" => "u", "password" => "p"}

      {elapsed_us, result} = :timer.tc(fn -> Validators.smtp(creds) end)

      assert {:error, message} = result
      assert message =~ "did not respond"
      # Comfortably under gen_smtp's own 20-minute read timeout.
      assert elapsed_us < 5_000_000
    end
  end

  # --- helpers ---------------------------------------------------------------

  # Answers the given results in order. A plain closure beats a mocking library here:
  # the thing under test is "how many times is AWS asked, and what is done with each
  # answer", which is exactly what a queue makes visible.
  defp stub(results) do
    {:ok, agent} = Agent.start_link(fn -> results end)
    on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

    fn _region, _data ->
      Agent.get_and_update(agent, fn
        [result | rest] -> {result, rest}
        [] -> raise "the requester was called more times than the test allows"
      end)
    end
  end

  # Accepts the connection and then says nothing at all — no SMTP banner.
  defp silent_relay do
    listener = listen()

    server =
      spawn(fn ->
        {:ok, _socket} = :gen_tcp.accept(listener)
        # Hold it open: an acceptor that exits closes the socket with it, and the
        # client would see a dropped connection rather than the silence under test.
        Process.sleep(:infinity)
      end)

    # spawn_link would NOT do: a normal exit does not propagate, so the acceptor, the
    # listener and the accepted socket would outlive the test for the life of the VM.
    reap(server, listener)
    port(listener)
  end

  # Greets, answers EHLO, and advertises no AUTH — an IP-authenticated smarthost.
  defp relay_without_auth do
    listener = listen()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        :gen_tcp.send(socket, "220 relay.internal ESMTP\r\n")
        {:ok, _ehlo} = :gen_tcp.recv(socket, 0, 5_000)
        :gen_tcp.send(socket, "250-relay.internal\r\n250-8BITMIME\r\n250 SIZE 10240000\r\n")
        # The client gives up at the auth step; hold the socket until we are reaped.
        Process.sleep(:infinity)
      end)

    reap(server, listener)
    port(listener)
  end

  defp listen do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :line])

    listener
  end

  defp port(listener) do
    {:ok, port} = :inet.port(listener)
    port
  end

  defp reap(server, listener) do
    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)
  end

  defp aws_error(code) do
    {:http_error, 403,
     %{body: "<ErrorResponse><Error><Code>#{code}</Code><Message>x</Message></Error></ErrorResponse>"}}
  end
end
