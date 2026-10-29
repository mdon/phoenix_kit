defmodule PhoenixKitWeb.Components.MediaBrowser.Removal do
  @moduledoc false
  # The media browser's side of `PhoenixKit.Modules.Storage.RemovalGuard`: which
  # module stands guard, what it is asked and how its answers are read. Every
  # call into the host's module goes through here, so one place fails closed:
  # a module that raises, exits or answers a shape that is not the contract
  # removes nothing, and the log names the module and the exception, never
  # the request.

  require Logger

  alias PhoenixKit.Modules.Storage.RemovalGuard
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @doc "The guard of a browser: its `removal_guard` attribute (`false` = none), else the configured one."
  def guard(assigns) do
    case Map.get(assigns, :removal_guard) do
      false -> nil
      module when is_atom(module) and module not in [nil, true] -> module
      _ -> RemovalGuard.configured()
    end
  end

  @doc "The `ctx` the guard is given."
  def ctx(assigns, action, folder_uuid) do
    scope =
      case Map.get(assigns, :phoenix_kit_current_scope) do
        %Scope{} = scope -> scope
        _ -> Scope.for_user(Map.get(assigns, :phoenix_kit_current_user))
      end

    %{scope: scope, action: action, folder_uuid: folder_uuid}
  end

  @doc """
  `{:ok, places}` — the places the guard names for `uuids`, read into the
  contract's shape — or `:error` when it failed or answered something else.
  """
  def places(module, uuids, ctx) do
    with {:ok, answer} <- call(module, :places, fn -> module.places(uuids, ctx) end),
         {:ok, places} <- read_places(answer, MapSet.new(uuids)) do
      {:ok, places}
    else
      _ -> :error
    end
  end

  @doc "The text of the release button for this person, or nil (none, or the module failed)."
  def release_label(module, ctx) do
    if exported?(module, :release, 2) and exported?(module, :release_label, 1) do
      case call(module, :release_label, fn -> module.release_label(ctx) end) do
        {:ok, label} when is_binary(label) and label != "" -> label
        _ -> nil
      end
    end
  end

  @doc "`:ok`, or `{:error, message}` where `message` is a string to show or nil."
  def release(module, uuids, ctx) do
    if exported?(module, :release, 2) do
      case call(module, :release, fn -> module.release(uuids, ctx) end) do
        {:ok, :ok} -> :ok
        {:ok, {:error, message}} when is_binary(message) -> {:error, message}
        _ -> {:error, nil}
      end
    else
      {:error, nil}
    end
  end

  defp exported?(module, fun, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)

  defp call(module, what, fun) do
    {:ok, fun.()}
  rescue
    exception ->
      log_failure(module, what, exception.__struct__)
      :error
  catch
    kind, _reason ->
      log_failure(module, what, kind)
      :error
  end

  defp log_failure(module, what, why) do
    Logger.error("MediaBrowser removal guard #{inspect(module)}.#{what} failed: #{inspect(why)}")
  end

  defp read_places(answer, requested) when is_list(answer) do
    answer
    |> Enum.reduce_while({:ok, []}, fn place, {:ok, acc} ->
      case read_place(place, requested) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, place} -> {:cont, {:ok, [place | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, places} -> {:ok, Enum.reverse(places)}
      :error -> :error
    end
  end

  defp read_places(_answer, _requested), do: :error

  # A place of a file that was not asked about is dropped; one that is no
  # map, or names no file, is a contract break.
  defp read_place(%{file_uuid: uuid} = place, requested) when is_binary(uuid) do
    if MapSet.member?(requested, uuid) do
      read_place_fields(uuid, place)
    else
      {:ok, nil}
    end
  end

  defp read_place(_place, _requested), do: :error

  # An unlabelled place is one the person may not see: nothing of it is kept.
  defp read_place_fields(uuid, %{label: label} = place) when is_binary(label) do
    {:ok,
     %{
       file_uuid: uuid,
       label: label,
       detail: text(Map.get(place, :detail)),
       href: safe_href(Map.get(place, :href))
     }}
  end

  defp read_place_fields(uuid, _place),
    do: {:ok, %{file_uuid: uuid, label: nil, detail: nil, href: nil}}

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(_value), do: nil

  # The link is the host's, opened in a new tab: a path of this site or an
  # http(s) address, never a `javascript:` or `data:` URL.
  defp safe_href(href) when is_binary(href) do
    cond do
      Routes.local_path?(href) -> href
      Regex.match?(~r{\Ahttps?://[^\s]+\z}i, href) -> href
      true -> nil
    end
  end

  defp safe_href(_href), do: nil
end
