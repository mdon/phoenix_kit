defmodule PhoenixKit.Integrations.ProbeTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Integrations.Probe

  describe "run/2" do
    test "hands back what the check answered" do
      assert :ok == Probe.run(fn -> :ok end)
      assert {:error, "nope"} == Probe.run(fn -> {:error, "nope"} end)
    end

    test "runs the check with the caller's locale" do
      # Gettext keeps the locale in the process dictionary and a spawned process
      # does not inherit it, so the check would otherwise render its errors in the
      # default language while the caller renders its own in the operator's.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")

      assert {:error, "ru"} =
               Probe.run(fn -> {:error, Gettext.get_locale(PhoenixKitWeb.Gettext)} end)
    end
  end

  # A check must be watched in both directions. Getting one right and not the
  # other is how this module's first cut shipped a bug: `Task.async/1` links, so a
  # crashing check killed the LiveView; replacing it with a bare `spawn_monitor/1`
  # fixed that and silently introduced the opposite leak, because the deadline
  # lives in the caller and dies with it.
  describe "the check cannot take the caller down" do
    test "when it raises" do
      assert {:answered, {:error, message}} =
               in_untrapped_caller(fn -> Probe.run(fn -> raise "boom" end) end)

      assert message =~ "Could not reach"
    end

    test "when it exits abnormally" do
      assert {:answered, {:error, _}} =
               in_untrapped_caller(fn -> Probe.run(fn -> exit(:boom) end) end)
    end

    test "when it is still running at the deadline" do
      assert {:answered, {:error, message}} =
               in_untrapped_caller(fn -> Probe.run(fn -> Process.sleep(:infinity) end, 100) end)

      assert message =~ "did not respond in time"
    end
  end

  describe "the caller cannot lose the check" do
    test "reaps the check when the caller dies mid-flight" do
      test = self()

      caller =
        spawn(fn ->
          Probe.run(
            fn ->
              send(test, {:check_running, self()})
              Process.sleep(:infinity)
            end,
            60_000
          )
        end)

      assert_receive {:check_running, check}, 2_000
      assert Process.alive?(check)

      ref = Process.monitor(check)

      # The operator hits refresh: the LiveView goes away while the check is still
      # blocked. Unlinked, the check would sit in gen_smtp's 20-minute ?TIMEOUT
      # holding its socket, with nothing left alive to fire the deadline.
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^ref, :process, ^check, _reason}, 2_000
    end

    test "kills a check that overruns the deadline" do
      parent = self()

      assert {:error, message} =
               Probe.run(
                 fn ->
                   send(parent, {:running, self()})
                   Process.sleep(:infinity)
                 end,
                 100
               )

      assert message =~ "did not respond in time"

      # The point of the deadline is to let go of the socket, not merely to stop
      # waiting on it.
      assert_receive {:running, check}
      ref = Process.monitor(check)
      assert_receive {:DOWN, ^ref, :process, ^check, reason}, 1_000
      assert reason in [:killed, :noproc]
    end

    test "leaves no stray reply in the caller's mailbox when the deadline fires" do
      assert {:error, _} = Probe.run(fn -> Process.sleep(50) end, 49)

      # The caller is a LiveView; a late reply would surface as an unexpected
      # message in handle_info/2.
      refute_receive _any, 200
    end
  end

  # Runs `fun` in a process that does NOT trap exits — exactly like a LiveView —
  # and reports whether that process survived. Asserting in the test process would
  # prove nothing: ExUnit's trap settings are not the LiveView's.
  defp in_untrapped_caller(fun) do
    parent = self()
    pid = spawn(fn -> send(parent, {:answered, fun.()}) end)
    ref = Process.monitor(pid)

    receive do
      {:answered, result} ->
        Process.demonitor(ref, [:flush])
        {:answered, result}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:caller_died, reason}
    after
      5_000 -> flunk("the caller never answered")
    end
  end
end
