defmodule PhoenixKit.PubSub.Manager do
  @moduledoc """
  PubSub Manager for PhoenixKit admin live updates.

  Manages its own PubSub system independent of parent applications.
  Automatically starts when needed and provides simple broadcast/subscribe API.
  """

  use GenServer
  require Logger

  @pubsub_name :phoenix_kit_internal_pubsub
  @manager_name __MODULE__

  ## Public API

  @doc """
  Broadcasts a message to a topic.
  Starts the manager if not already running.
  """
  def broadcast(topic, message) do
    ensure_started_internal()
    Phoenix.PubSub.broadcast(@pubsub_name, topic, message)
  end

  @doc """
  Subscribes to a topic.
  Starts the manager if not already running.
  """
  def subscribe(topic) do
    ensure_started_internal()
    Phoenix.PubSub.subscribe(@pubsub_name, topic)
  end

  @doc """
  Unsubscribes from a topic.
  """
  def unsubscribe(topic) do
    ensure_started_internal()
    Phoenix.PubSub.unsubscribe(@pubsub_name, topic)
  end

  @doc """
  Starts the PubSub manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @manager_name)
  end

  @doc """
  Ensures the PubSub manager is started.
  Public function that can be called from other modules.
  """
  def ensure_started do
    ensure_started_internal()
  end

  ## Private Functions

  defp ensure_started_internal do
    case GenServer.whereis(@manager_name) do
      nil ->
        case start_link() do
          {:ok, _pid} ->
            Logger.debug("PhoenixKit.PubSub.Manager started")
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          error ->
            Logger.error("Failed to start PhoenixKit.PubSub.Manager: #{inspect(error)}")
            error
        end

      _pid ->
        :ok
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Start our own PubSub system
    children = [
      {Phoenix.PubSub, name: @pubsub_name, adapter: Phoenix.PubSub.PG2}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, supervisor_pid} ->
        Logger.debug("PhoenixKit PubSub system started with PID: #{inspect(supervisor_pid)}")
        {:ok, %{supervisor: supervisor_pid, pubsub_name: @pubsub_name}}

      {:error, reason} ->
        Logger.error("Failed to start PhoenixKit PubSub system: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      pubsub_name: state.pubsub_name,
      supervisor_pid: state.supervisor,
      running: Process.alive?(state.supervisor)
    }

    {:reply, status, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("PhoenixKit.PubSub.Manager terminating: #{inspect(reason)}")

    # Supervisor will handle cleanup of PubSub
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor)
    end

    :ok
  end
end
