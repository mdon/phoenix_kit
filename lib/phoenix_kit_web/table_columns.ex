defmodule PhoenixKitWeb.TableColumns do
  @moduledoc """
  Which columns a table shows, and in what order, for each user — stored as
  the `"columns"` field of the user's `PhoenixKit.Users.ViewPrefs` for the
  table's key, edited through core's live `column_settings_modal/1`.

  A table describes itself with a spec:

      %{
        key: "catalogue.detail_items",           # the ViewPrefs key
        columns: [%{id: "sku", label: fn -> gettext("SKU") end}, …],
        defaults: ["sku", "price"],              # optional; all columns when absent
        site_default: &MyApp.site_columns/0,     # optional; -> [id] | nil
        min: 0                                   # optional; fewest a user may keep
      }

  `columns` is exactly what the modal can show or hide. A column that is
  always on (a Name, an Actions cell) is not in it: the table draws it
  around the resolved list.

  ## The rules

    * A user who has not chosen sees the site's default when there is one
      (`site_default`), else `defaults`. Reset takes the user's choice back
      out, so they follow that default again — it does not save a copy of it.
    * An empty list is a choice: every optional column hidden.
    * Ids no longer in `columns` (a custom field deleted, an extension
      switched off) are skipped when reading and never rewritten by a read;
      when none of a non-empty choice is left, the default shows until the
      user changes something.
    * A change saves the list the user now sees — ids already skipped are
      not carried along.

  ## In a LiveView

      def handle_event(event, params, socket)
          when event in ~w(add_column remove_column reorder_columns reset_columns) do
        {:noreply, TableColumns.handle_event(event, params, socket, spec(), :columns)}
      end

  `handle_event/5` updates the assign and saves for the signed-in user
  (`PhoenixKitWeb.Actor`); with nobody signed in the change lasts for the
  page. A modal with several tables (`sections`) sends a `"section"` param
  — pick the spec by it and pass that.
  """

  require Logger

  alias PhoenixKit.Users.ViewPrefs
  alias PhoenixKitWeb.Actor

  @field "columns"
  @events ~w(add_column remove_column reorder_columns reset_columns)

  @type column :: %{required(:id) => String.t(), required(:label) => String.t() | (-> String.t())}
  @type spec :: %{
          required(:key) => String.t(),
          required(:columns) => [column()],
          optional(:defaults) => [String.t()],
          optional(:site_default) => (-> [String.t()] | nil),
          optional(:min) => non_neg_integer()
        }

  @doc "The events `handle_event/5` answers."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The columns `user` sees for the table `spec` describes."
  @spec load(ViewPrefs.user(), spec()) :: [String.t()]
  def load(user, spec) do
    user
    |> ViewPrefs.get(spec.key)
    |> Map.get(@field)
    |> resolve(spec)
  end

  @doc """
  The columns a stored choice shows (see the rules in the moduledoc):
  `nil` for no choice, else the stored list.
  """
  @spec resolve(term(), spec()) :: [String.t()]
  def resolve(stored, spec) when is_list(stored) do
    case known(stored, spec) do
      [] when stored != [] -> default(spec)
      shown -> shown
    end
  end

  def resolve(_stored, spec), do: default(spec)

  @doc """
  What a user who has not chosen sees: the site's default when it names
  any column still offered, else the spec's `defaults` (all columns when
  there are none).
  """
  @spec default(spec()) :: [String.t()]
  def default(spec) do
    site =
      case Map.get(spec, :site_default) do
        fun when is_function(fun, 0) -> fun.()
        _ -> nil
      end

    case is_list(site) && known(site, spec) do
      [_ | _] = shown -> shown
      _ -> known(Map.get(spec, :defaults) || ids(spec), spec)
    end
  end

  @doc "`current` with `id` added at the end — when it is offered and not shown yet."
  @spec add([String.t()], term(), spec()) :: [String.t()]
  def add(current, id, spec) do
    if is_binary(id) and id in ids(spec) and id not in current, do: current ++ [id], else: current
  end

  @doc "`current` without `id` — unless that would leave fewer than the spec's `:min`."
  @spec remove([String.t()], term(), spec()) :: [String.t()]
  def remove(current, id, spec) do
    if id in current and length(current) > Map.get(spec, :min, 0),
      do: List.delete(current, id),
      else: current
  end

  @doc """
  `current` in the order `ordered` gives. Ids `ordered` names that are not
  shown are ignored; shown ones it leaves out keep their place at the end,
  so a partial or crafted payload can reorder but never drop or add.
  """
  @spec reorder([String.t()], term(), spec()) :: [String.t()]
  def reorder(current, ordered, _spec) when is_list(ordered) do
    moved = ordered |> Enum.filter(&(&1 in current)) |> Enum.uniq()
    moved ++ (current -- moved)
  end

  def reorder(current, _ordered, _spec), do: current

  @doc """
  Applies one of the modal's events (`events/0`) to the list in assign
  `name`, saves it for the signed-in user, and answers the socket.
  Anything else — an unknown event, a malformed param — leaves it alone.
  """
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t(), spec(), atom()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("reset_columns", _params, socket, spec, name) do
    case ViewPrefs.delete_fields(Actor.uuid(socket), spec.key, [@field]) do
      {:ok, _prefs} -> :ok
      {:error, :no_user} -> :ok
      {:error, reason} -> log_failure(spec, reason)
    end

    Phoenix.Component.assign(socket, name, default(spec))
  end

  def handle_event(event, params, socket, spec, name) when event in @events do
    current = Map.get(socket.assigns, name) || []

    case apply_event(event, params, current, spec) do
      ^current -> socket
      changed -> save(socket, spec, name, changed)
    end
  end

  def handle_event(_event, _params, socket, _spec, _name), do: socket

  defp apply_event("add_column", %{"column_id" => id}, current, spec), do: add(current, id, spec)

  defp apply_event("remove_column", %{"column_id" => id}, current, spec),
    do: remove(current, id, spec)

  defp apply_event("reorder_columns", %{"ordered_ids" => ids}, current, spec),
    do: reorder(current, ids, spec)

  defp apply_event(_event, _params, current, _spec), do: current

  defp save(socket, spec, name, columns) do
    case ViewPrefs.put(Actor.uuid(socket), spec.key, %{@field => columns}) do
      {:ok, _prefs} -> :ok
      {:error, :no_user} -> :ok
      {:error, reason} -> log_failure(spec, reason)
    end

    Phoenix.Component.assign(socket, name, columns)
  end

  # The reason's shape only: a database error can carry the query's values.
  defp log_failure(spec, reason) do
    Logger.warning("[TableColumns] could not save the columns of #{spec.key}: #{shape(reason)}")
  end

  defp shape(%{__struct__: mod}), do: inspect(mod)
  defp shape(reason) when is_atom(reason), do: inspect(reason)
  defp shape(_reason), do: "an error"

  defp ids(spec), do: Enum.map(spec.columns, & &1.id)

  defp known(list, spec) do
    offered = MapSet.new(ids(spec))
    list |> Enum.filter(&(is_binary(&1) and MapSet.member?(offered, &1))) |> Enum.uniq()
  end
end
