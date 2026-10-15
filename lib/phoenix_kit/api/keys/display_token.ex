defmodule PhoenixKit.API.Keys.DisplayToken do
  @moduledoc """
  A one-time token held by the Settings LiveView. Inspection redacts its value so
  LiveView termination reports cannot print it; HTML rendering still shows it once.
  """
  @derive {Inspect, except: [:value]}
  @enforce_keys [:value]
  defstruct [:value]

  defimpl Phoenix.HTML.Safe do
    alias Phoenix.HTML.Engine

    def to_iodata(%{value: value}), do: Engine.html_escape(value)
  end
end
