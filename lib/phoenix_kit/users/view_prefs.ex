defmodule PhoenixKit.Users.ViewPrefs do
  @moduledoc """
  A user's preferences for a view — which columns a table shows and in
  what order, and whatever else the view's owner keeps (a sort, filters) —
  one JSON object per `(user, key)`.

  `key` names the view and is namespaced by its owner: `"users"`,
  `"website_access.attempts"`, `"catalogue.detail_items"`,
  `"crm.role.<uuid>"`. Each top-level field of the object is written whole:
  `put/3` patches the fields it is given with `prefs || changes` inside the
  upsert, so two tabs changing different fields both keep their change,
  and nothing is rebuilt from a copy of the user a page happens to hold.
  `delete_fields/3` takes a field back out — which is what "reset" means:
  the view goes back to following its default.

  `PhoenixKitWeb.TableColumns` is the table-columns layer on top; core
  gives meaning only to the `"columns"` field.

  A user is a `%{uuid: _}` or a uuid; `nil` (nobody signed in) reads as no
  preferences and writes `{:error, :no_user}`. Nothing here raises: a read
  that fails is no preferences, a write that fails answers `{:error, _}`.
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Users.ViewPref

  @max_key 255
  # Per write. A view keeps a handful of small fields; this keeps a bug or a
  # crafted payload from growing a row without bound.
  @max_bytes 16_384

  @type user :: %{required(:uuid) => String.t()} | String.t() | nil

  defp repo, do: PhoenixKit.RepoHelper.repo()

  @doc "The user's preferences for view `key` — `%{}` when they have none."
  @spec get(user(), String.t()) :: map()
  def get(user, key) do
    with uuid when is_binary(uuid) <- user_uuid(user),
         {:ok, key} <- check_key(key) do
      repo().one(
        from(p in ViewPref, where: p.user_uuid == ^uuid and p.key == ^key, select: p.prefs)
      ) ||
        %{}
    else
      _ -> %{}
    end
  rescue
    error -> read_failed(error)
  catch
    :exit, reason -> read_failed({:exit, reason})
  end

  @doc """
  Sets the given top-level `fields` of the user's preferences for `key`,
  leaving the others as stored. Answers the preferences as they now are.
  """
  @spec put(user(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put(user, key, fields) when is_map(fields) do
    with {:ok, uuid} <- fetch_uuid(user),
         {:ok, key} <- check_key(key),
         {:ok, fields} <- check_fields(fields) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {1, [%{prefs: prefs}]} =
        repo().insert_all(
          ViewPref,
          [%{user_uuid: uuid, key: key, prefs: fields, inserted_at: now, updated_at: now}],
          on_conflict:
            from(p in ViewPref,
              update: [set: [prefs: fragment("? || EXCLUDED.prefs", p.prefs), updated_at: ^now]]
            ),
          conflict_target: [:user_uuid, :key],
          returning: [:prefs]
        )

      {:ok, prefs}
    end
  rescue
    error -> write_failed(error)
  catch
    :exit, reason -> write_failed({:exit, reason})
  end

  @doc """
  Takes `fields` out of the user's preferences for `key`, so the view
  follows its default for them again. Answers the preferences as they now
  are (`%{}` when the user had none).
  """
  @spec delete_fields(user(), String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def delete_fields(user, key, fields) when is_list(fields) do
    with {:ok, uuid} <- fetch_uuid(user),
         {:ok, key} <- check_key(key) do
      fields = Enum.filter(fields, &is_binary/1)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(p in ViewPref,
        where: p.user_uuid == ^uuid and p.key == ^key,
        update: [set: [prefs: fragment("? - ?::text[]", p.prefs, ^fields), updated_at: ^now]],
        select: p.prefs
      )
      |> repo().update_all([])
      |> case do
        {_, [prefs]} -> {:ok, prefs}
        {_, []} -> {:ok, %{}}
      end
    end
  rescue
    error -> write_failed(error)
  catch
    :exit, reason -> write_failed({:exit, reason})
  end

  @doc "Deletes every user's preferences for `key` — for a view that no longer exists."
  @spec delete_key(String.t()) :: :ok
  def delete_key(key) do
    with {:ok, key} <- check_key(key) do
      repo().delete_all(from(p in ViewPref, where: p.key == ^key))
    end

    :ok
  end

  defp user_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp user_uuid(uuid) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp fetch_uuid(user) do
    case user |> user_uuid() |> cast_uuid() do
      nil -> {:error, :no_user}
      uuid -> {:ok, uuid}
    end
  end

  defp cast_uuid(<<_::binary-size(36)>> = value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_uuid(_), do: nil

  defp check_key(key) when is_binary(key) and byte_size(key) in 1..@max_key, do: {:ok, key}
  defp check_key(_), do: {:error, :invalid_key}

  defp check_fields(fields) do
    cond do
      not Enum.all?(Map.keys(fields), &is_binary/1) -> {:error, :invalid_fields}
      byte_size(Jason.encode!(fields)) > @max_bytes -> {:error, :too_large}
      true -> {:ok, fields}
    end
  rescue
    _ in [Jason.EncodeError, Protocol.UndefinedError] -> {:error, :invalid_fields}
  end

  # An unknown user is the one database error a caller can cause; anything
  # else (a lost connection, a pool exit) is answered, never raised — a
  # preference that did not save must not take the page down.
  defp write_failed(%Postgrex.Error{postgres: %{code: :foreign_key_violation}}),
    do: {:error, :no_user}

  defp write_failed(%Postgrex.Error{postgres: %{code: code}} = error) do
    Logger.warning("[ViewPrefs] write failed: #{inspect(code)}")
    {:error, error}
  end

  defp write_failed({:exit, _reason} = error) do
    Logger.warning("[ViewPrefs] write failed: exit")
    {:error, error}
  end

  defp write_failed(%{__struct__: mod} = error) do
    Logger.warning("[ViewPrefs] write failed: #{inspect(mod)}")
    {:error, error}
  end

  # A read that fails is no preferences; the log names the failure's kind.
  defp read_failed({:exit, _reason}) do
    Logger.warning("[ViewPrefs] read failed: exit")
    %{}
  end

  defp read_failed(%{__struct__: mod}) do
    Logger.warning("[ViewPrefs] read failed: #{inspect(mod)}")
    %{}
  end
end
