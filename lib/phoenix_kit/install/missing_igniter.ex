defmodule PhoenixKit.Install.MissingIgniter do
  @moduledoc """
  Stand-in for the `mix phoenix_kit.*` tasks that cannot exist without igniter.

  Igniter is an optional dependency (see `mix.exs`), and every task that drives
  it is wrapped in `if Code.ensure_loaded?(Igniter.Mix.Task)`. Without a
  fallback the guard's `else` branch defines nothing at all, so the task simply
  vanishes and Mix reports:

      ** (Mix) The task "phoenix_kit.update" could not be found

  which names neither PhoenixKit nor igniter, and leaves a host stranded on an
  old schema with nothing to search for. This module defines a task that exists
  purely to explain the situation and print the one line to add.

  ## Why the dep is optional at all

  A stock `mix phx.new` app declares `{:igniter, "~> 0.6", only: [:dev, :test]}`.
  A non-optional dep here resolves for all environments, and Mix refuses to
  converge the two — which broke `mix igniter.install phoenix_kit` on every
  freshly generated project. Optional means the host's own declaration wins.

  The cost is this case: a host that never declared igniter itself was getting
  it transitively, and an upgrade drops it. That is what the message covers.

  ## Why the compile-time guard is not enough

  `Code.ensure_loaded?/1` runs when PhoenixKit is compiled into the host's
  `_build`, and PhoenixKit is not recompiled when the host's own dependency
  list changes. A host that installed PhoenixKit while igniter was on the path
  keeps a beam that took the igniter branch; drop igniter afterwards and that
  stale beam is still what Mix loads. The guard's `else` branch was never
  compiled, so instead of the message below the host gets:

      ** (UndefinedFunctionError) function Igniter.Mix.Task.help_requested?/1
      is undefined (module Igniter.Mix.Task is not available)

  which is the failure this module exists to prevent. Every igniter-backed
  task therefore also calls `ensure_available!/1` at the top of its `run/1`,
  so the same guidance is printed whether the branch was chosen at compile
  time or the compiled branch turned out to be a lie.
  """

  @doc """
  The guidance printed when a task is invoked without igniter available.
  """
  @spec message(String.t()) :: String.t()
  def message(task) do
    """
    `mix #{task}` needs the :igniter dependency, which is not available in this project.

    PhoenixKit declares igniter as an OPTIONAL dependency so that it converges with
    the `{:igniter, "~> 0.6", only: [:dev, :test]}` that `mix phx.new` generates.
    The trade-off is that a project which never declared igniter itself does not
    get it from PhoenixKit either.

    Add it to your mix.exs deps and re-run:

        {:igniter, "~> 0.7", only: [:dev, :test]}

    then:

        mix deps.get
        mix #{task}

    Everything that does not generate or patch code — `mix phoenix_kit.status`,
    `mix phoenix_kit.gen.migration`, `mix phoenix_kit.assets.rebuild` — works
    without igniter and is unaffected.
    """
  end

  @doc """
  Raises `message/1` unless igniter is actually loadable right now.

  Called at the top of `run/1` in every igniter-backed task. The tasks are
  wrapped in a compile-time `Code.ensure_loaded?/1` guard, but that decision
  can outlive the dependency that justified it (see the moduledoc), so the
  same question is asked again at runtime.

  `igniter_module` exists so the failing branch is testable; callers pass the
  task name only.
  """
  @spec ensure_available!(String.t(), module()) :: :ok
  def ensure_available!(task, igniter_module \\ Igniter.Mix.Task) do
    if Code.ensure_loaded?(igniter_module) do
      :ok
    else
      Mix.raise(message(task))
    end
  end

  @doc """
  Defines the body of a stand-in task. The caller supplies its own
  `@moduledoc` — generating one from here would hide it from static analysis.
  """
  defmacro __using__(opts) do
    task = Keyword.fetch!(opts, :task)
    helper = __MODULE__

    quote do
      use Mix.Task

      @shortdoc "Unavailable — requires the optional :igniter dependency"

      @impl Mix.Task
      def run(_args), do: Mix.raise(unquote(helper).message(unquote(task)))
    end
  end
end
