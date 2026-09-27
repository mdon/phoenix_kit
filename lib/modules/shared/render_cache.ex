defmodule PhoenixKit.Modules.Shared.RenderCache do
  @moduledoc """
  Whether the HTML a component just rendered is safe to keep.

  A missing file is a finished answer: the placeholder is what the next
  request produces too, and a renderer may cache it. A lookup that
  *raised* — a column the running code expects but the database does not
  have yet, a dead connection — is not finished. The placeholder is still
  what this request shows, and the next request has to try again.

  `lookup/2` runs the query. `take/1` is what a caching renderer wraps the
  whole render in: `{:ok, html}` may be stored, `{:retry, html}` must not.

  The mark lives on the calling process for that `take/1`. Nested renders
  propagate failures to their enclosing render; a later independent render
  starts clean. Lookups in tasks or other processes are not tracked.
  """

  require Logger

  @key {__MODULE__, :lookup_failed}

  @doc """
  Records that the lookup inside the current `take/1` raised.

  `lookup/2` does this itself. Other code calls it when it has already
  rescued the error and still rendered a placeholder.
  """
  @spec lookup_failed() :: :ok
  def lookup_failed do
    if Process.get(@key) != nil, do: Process.put(@key, true)
    :ok
  end

  @doc """
  Runs `fun`. Returns whatever it returns, including nil for a missing file.

  If `fun` raises, or the database call exits (a dead pool exits rather
  than raises), records the failure and returns `fallback`.
  """
  @spec lookup((-> term()), term()) :: term()
  def lookup(fun, fallback) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      give_up(error, fallback)
  catch
    :exit, reason ->
      give_up(reason, fallback)
  end

  @doc """
  Runs `fun` and reports whether its result may be cached.

  `{:ok, result}` — no lookup raised.
  `{:retry, result}` — one did. `result` is still the rendered page
  (placeholders included); do not store it.

  Nested calls track their own result and propagate failures to the enclosing
  call. Cleans up when `fun` raises, exits or throws as well.
  """
  @spec take((-> result)) :: {:ok | :retry, result} when result: term()
  def take(fun) when is_function(fun, 0) do
    previous = Process.put(@key, false)

    try do
      result = fun.()
      status = if Process.get(@key), do: :retry, else: :ok
      {status, result}
    after
      failed = Process.delete(@key)
      if previous != nil, do: Process.put(@key, previous or failed)
    end
  end

  defp give_up(reason, fallback) do
    lookup_failed()
    Logger.warning("Render lookup failed and will be tried again: #{summary(reason)}")
    fallback
  end

  defp summary(reason) do
    reason
    |> summary_text()
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.slice(0, 300)
  end

  defp summary_text(%{__exception__: true} = error), do: Exception.message(error)
  defp summary_text(reason) when is_binary(reason) or is_atom(reason), do: to_string(reason)
  defp summary_text(reason), do: inspect(reason)
end
