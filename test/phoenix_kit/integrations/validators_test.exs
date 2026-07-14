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

    test "a tarpit relay is cut off at the deadline instead of hanging the caller" do
      # gen_smtp bounds only the TCP connect; every read after it waits on a
      # hard-coded 20-minute timeout, in the CALLING process. Both call sites are
      # LiveView callbacks, so without an outer deadline one silent relay parks a
      # LiveView process for twenty minutes.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)

      # Accept the connection and then say nothing at all — no SMTP banner.
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        Process.sleep(:infinity)
        :gen_tcp.close(socket)
      end)

      Application.put_env(:phoenix_kit, :integration_check_deadline, 300)
      on_exit(fn -> Application.delete_env(:phoenix_kit, :integration_check_deadline) end)

      creds = %{
        "host" => "127.0.0.1",
        "port" => port,
        "username" => "u",
        "password" => "p"
      }

      {elapsed_us, result} = :timer.tc(fn -> Validators.smtp(creds) end)

      assert {:error, message} = result
      assert message =~ "did not respond"
      # Comfortably under gen_smtp's own 20-minute read timeout.
      assert elapsed_us < 5_000_000
    end
  end
end
