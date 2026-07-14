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
      # does not inherit it, so the check would otherwise render its errors in
      # the default language while the caller renders its own in the operator's.
      Gettext.put_locale(PhoenixKitWeb.Gettext, "ru")

      assert {:error, "ru"} =
               Probe.run(fn -> {:error, Gettext.get_locale(PhoenixKitWeb.Gettext)} end)
    end

    # The regression these three guard: `Task.async/1` *links*, so a crash inside
    # the check kills a non-trapping caller — and every call site is a LiveView
    # callback, which does not trap exits. Swapping `spawn_monitor/1` back for a
    # Task would turn any library crash into a dead page. Each of these tests
    # would then fail with `{:caller_died, _}` instead of an error tuple.
    test "a raising check does not take the caller down with it" do
      assert {:answered, {:error, message}} =
               in_untrapped_caller(fn -> Probe.run(fn -> raise "boom" end) end)

      assert message =~ "Could not reach"
    end

    test "an exiting check does not take the caller down with it" do
      assert {:answered, {:error, _}} =
               in_untrapped_caller(fn -> Probe.run(fn -> exit(:boom) end) end)
    end

    test "a check killed from outside does not take the caller down with it" do
      assert {:answered, {:error, _}} =
               in_untrapped_caller(fn -> Probe.run(fn -> Process.exit(self(), :kill) end) end)
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
      assert_receive {:running, pid}
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
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
  # and reports whether that process survived. Asserting in the test process
  # would prove nothing: ExUnit's own trap settings are not the LiveView's.
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
