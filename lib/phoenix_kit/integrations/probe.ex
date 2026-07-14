defmodule PhoenixKit.Integrations.Probe do
  @moduledoc """
  Runs a connection check in an isolated process under a hard deadline.

  Connection checks talk to the network, and the libraries behind them do not
  bound themselves:

    * `:gen_smtp_client.open/1` runs in the **calling** process and, past the TCP
      connect, waits on a hard-coded `?TIMEOUT` of 1_200_000 ms — the `timeout`
      option bounds only `connect`. A tarpit relay parks the caller for twenty
      minutes.
    * ExAws retries transport errors with backoff, which adds up to minutes.

  Every call site is a LiveView callback, so the only bound that actually holds
  is one imposed from outside.

  This is deliberately **not** `Task.async/1`, which *links*. A raise or an
  abnormal exit inside the check kills a non-trapping caller outright — before
  `Task.yield/2` can hand back `{:exit, reason}`, so that clause never runs — and
  a LiveView process does not trap exits. A linked check therefore turns any
  library crash into a dead page for the operator. LiveView's own `start_async`
  monitors rather than links for exactly this reason, and so do we:
  `spawn_monitor/1` turns a crash into an error message.

  `Task.Supervisor.async_nolink/2` (as `Users.QRLogin.location_for/1` uses, for
  the same hazard) would be the other way to unlink. `spawn_monitor/1` is used
  here because a connection check touches neither the repo nor a mock, so it
  needs nothing the supervisor offers — no `$callers`, no supervision — and
  `async_nolink` costs a dialyzer suppression: its `%Task{}` trips the opacity
  check at `Task.yield/2`.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  @typedoc "Talks to the network; answers `:ok` or a human-readable error."
  @type check :: (-> :ok | {:error, String.t()})

  @default_deadline 15_000

  @doc """
  Runs `check` in an isolated process, bounded by `deadline` milliseconds.

  Returns what `check` returned. If it crashes, exits, or overruns the deadline,
  returns `{:error, message}` — either way the caller is left standing.
  """
  @spec run(check(), timeout()) :: :ok | {:error, String.t()}
  def run(check, deadline \\ deadline()) when is_function(check, 0) do
    parent = self()
    ref = make_ref()

    # The check renders its own error messages, and Gettext keeps the locale in
    # the process dictionary — which a spawned process does not inherit. Without
    # this the operator would read half the failures in their own language and
    # half in English.
    locale = Gettext.get_locale(PhoenixKitWeb.Gettext)

    {pid, monitor} =
      spawn_monitor(fn ->
        Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
        send(parent, {ref, check.()})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.warning("Connection check crashed: #{inspect(reason)}")
        {:error, gettext("Could not reach the service")}
    after
      deadline ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        flush(ref)
        {:error, gettext("The service did not respond in time")}
    end
  end

  # A result that lands in the instant the deadline fires must not be left behind
  # in the caller's mailbox: the caller is a LiveView, and it would log the stray
  # reply as an unexpected message.
  defp flush(ref) do
    receive do
      {^ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp deadline do
    Application.get_env(:phoenix_kit, :integration_check_deadline, @default_deadline)
  end
end
