defmodule PhoenixKit.HeaderWidget do
  @moduledoc """
  A sticky LiveView a module puts into the admin header, before the notifications bell
  (`c:PhoenixKit.Module.header_widgets/0`).

  A module returns tuples; core normalises them into this struct
  (`PhoenixKit.ModuleRegistry.all_header_widgets/0`) and the admin layout renders each one
  with `Phoenix.Component.live_render/3` (`sticky: true`, `id: id`).

  ## Fields

    * `:live_view` - the LiveView module to render.
    * `:id` - the DOM id of the nested LiveView (not one the admin layout uses itself, see
      `reserved_ids/0`). Stable: a sticky LiveView keeps its state
      (and its PubSub subscriptions) across admin navigation only while the id is the same.
      Two widgets with one id cannot both be rendered; the first one registered wins.
    * `:session_fun` - `(layout_assigns -> session)`, called on every render of the
      layout with the layout's assigns. They include `:socket` (the parent LiveView's
      socket), `:phoenix_kit_current_scope` and `:phoenix_kit_current_user` (the user of
      the scope, filled in when the caller passed only the scope), `:current_locale` and
      `:current_locale_base`. It returns the session of the nested LiveView: a map with
      **string** keys and values that survive being signed into the page, so ids and
      strings, not structs.
    * `:dock` - `true` when the widget uses the dock column (`#pk-dock`, see
      `PhoenixKitWeb.Components.AdminDock`). The column exists only while a rendered widget
      declares it.
    * `:module` - the module that declared the widget. Filled in by the registry.
    * `:session` - the result of `:session_fun`, filled in by
      `PhoenixKit.ModuleRegistry.header_widgets_for/1`.

  ## Authority

  The session is all the widget gets: a nested sticky LiveView is mounted without the
  `live_session`'s `on_mount` hooks and without `current_scope`, and for every signed-in user
  of an admin-layout page. The widget has to check the permission itself from the session
  (see `c:PhoenixKit.Module.header_widgets/0`).
  """

  @type session_fun :: (map() -> map())

  @typedoc "What `c:PhoenixKit.Module.header_widgets/0` returns, one element per widget."
  @type entry ::
          {live_view :: module(), id :: String.t(), session_fun()}
          | {live_view :: module(), id :: String.t(), session_fun(), opts :: [dock: boolean()]}

  @type t :: %__MODULE__{
          module: module() | nil,
          live_view: module(),
          id: String.t(),
          session_fun: session_fun(),
          dock: boolean(),
          session: map() | nil
        }

  # DOM ids the admin layout already uses; a widget with one of them would clash with it.
  @reserved_ids ["pk-notifications-bell", "pk-dock", "admin-drawer"]

  @enforce_keys [:live_view, :id, :session_fun]
  defstruct [:module, :live_view, :id, :session_fun, :session, dock: false]

  @doc "The DOM ids of the admin layout that a widget may not use."
  @spec reserved_ids() :: [String.t()]
  def reserved_ids, do: @reserved_ids

  @doc """
  Normalise one entry of `c:PhoenixKit.Module.header_widgets/0`.

  `{live_view, id, session_fun}` or `{live_view, id, session_fun, opts}` with
  `opts = [dock: boolean]`. Returns `{:error, reason}` (a string) for anything else.
  """
  @spec new(term()) :: {:ok, t()} | {:error, String.t()}
  def new({live_view, id, session_fun}), do: new({live_view, id, session_fun, []})

  def new({live_view, id, session_fun, opts}) do
    with :ok <- check_live_view(live_view),
         :ok <- check_id(id),
         :ok <- check_session_fun(session_fun),
         {:ok, dock} <- check_opts(opts) do
      {:ok, %__MODULE__{live_view: live_view, id: id, session_fun: session_fun, dock: dock}}
    end
  end

  def new(_entry) do
    {:error, "expected {live_view, id, session_fun} or {live_view, id, session_fun, opts}"}
  end

  @doc """
  Run the widget's session function against the layout's assigns.

  Returns `{:ok, widget}` with `:session` filled in, or `{:error, reason}` when the
  function raises or returns something `live_render/3` cannot take (not a map, or a key that
  is not a string).
  """
  @spec resolve_session(t(), map()) :: {:ok, t()} | {:error, String.t()}
  def resolve_session(%__MODULE__{session_fun: fun} = widget, assigns) do
    case fun.(assigns) do
      session when is_map(session) and not is_struct(session) ->
        if Enum.all?(session, fn {key, _} -> is_binary(key) end) do
          {:ok, %{widget | session: session}}
        else
          {:error, "the session has a key that is not a string"}
        end

      other ->
        {:error, "the session is not a map: #{inspect(other, limit: 5, printable_limit: 80)}"}
    end
  rescue
    error -> {:error, "the session function raised: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "the session function failed: #{inspect({kind, reason})}"}
  end

  defp check_live_view(live_view) when is_atom(live_view) and not is_nil(live_view) do
    if Code.ensure_loaded?(live_view) and function_exported?(live_view, :__live__, 0) do
      :ok
    else
      {:error, "#{inspect(live_view)} is not a LiveView module"}
    end
  end

  defp check_live_view(live_view), do: {:error, "#{inspect(live_view)} is not a LiveView module"}

  defp check_id(id) when id in @reserved_ids,
    do: {:error, "the id #{inspect(id)} is reserved by the admin layout"}

  defp check_id(id) when is_binary(id) and id != "", do: :ok
  defp check_id(id), do: {:error, "the id must be a non-empty string, got #{inspect(id)}"}

  defp check_session_fun(fun) when is_function(fun, 1), do: :ok
  defp check_session_fun(_fun), do: {:error, "the session function must take one argument"}

  defp check_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:dock] == [] do
      case Keyword.get(opts, :dock, false) do
        dock when is_boolean(dock) -> {:ok, dock}
        other -> {:error, ":dock must be a boolean, got #{inspect(other)}"}
      end
    else
      {:error, "the only option is :dock"}
    end
  end

  defp check_opts(_opts), do: {:error, "the options must be a keyword list"}
end
