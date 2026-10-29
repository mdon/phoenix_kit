defmodule PhoenixKitWeb.Components.PersonalKeyDisplay do
  @moduledoc """
  How a personal API key's state and expiry are shown, for "My API keys" and for
  Settings -> API alike.

  `statuses/1` is computed once for a list (the owner's right is read once per owner,
  not once per key) and the page reads the result from a map; the template never asks
  `PhoenixKit.API.Keys`. `expiry_date/2` shows the UTC day the person chose in the form,
  not that moment moved into their time zone (east of UTC it would read one day later).
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.API.Keys
  alias PhoenixKit.API.Keys.Key
  alias PhoenixKit.Utils.Date, as: UtilsDate

  @soon_days 7

  @type status ::
          :revoked
          | :expired
          | :owner_inactive
          | :no_permission
          | :rotating
          | :expiring_soon
          | :active

  @doc """
  The status of every personal key of the list, by uuid. Keys that are not personal are
  left out.
  """
  @spec statuses([Key.t()]) :: %{String.t() => status()}
  def statuses(keys) do
    personal = Enum.filter(keys, & &1.personal)
    now = DateTime.utc_now()
    owners = owner_states(personal)

    Map.new(personal, fn key ->
      {key.uuid, status(key, Map.get(owners, key.user_uuid, :ok), now)}
    end)
  end

  # One `Keys.active_owner/1` per owner that has a live key; the others need none.
  defp owner_states(keys) do
    keys
    |> Enum.filter(&(Keys.dead_reason(&1) == nil))
    |> Enum.uniq_by(& &1.user_uuid)
    |> Map.new(fn key ->
      case Keys.active_owner(key) do
        {:ok, _owner} -> {key.user_uuid, :ok}
        {:error, reason} -> {key.user_uuid, reason}
      end
    end)
  end

  defp status(key, owner, now) do
    cond do
      Keys.dead_reason(key) == :revoked -> :revoked
      Keys.dead_reason(key) == :expired -> :expired
      owner == :owner_inactive -> :owner_inactive
      owner == :personal_keys_not_allowed -> :no_permission
      key.revoked_at != nil -> :rotating
      soon?(key.expires_at, now) -> :expiring_soon
      true -> :active
    end
  end

  defp soon?(%DateTime{} = expires_at, now),
    do: DateTime.diff(expires_at, now, :second) <= @soon_days * 86_400

  defp soon?(_none, _now), do: false

  @doc "Whether the key still works (not revoked and not expired)."
  @spec live?(status()) :: boolean()
  def live?(status), do: status not in [:revoked, :expired]

  @doc "The `<.status_badge status=…>` name."
  @spec badge_name(status()) :: String.t()
  def badge_name(:active), do: "active"
  def badge_name(:expiring_soon), do: "ending"
  def badge_name(:rotating), do: "ending"
  def badge_name(:expired), do: "expired"
  def badge_name(:revoked), do: "revoked"
  def badge_name(:no_permission), do: "suspended"
  def badge_name(:owner_inactive), do: "suspended"

  @doc "The `<.status_badge label=…>` text."
  @spec label(status()) :: String.t()
  def label(:active), do: gettext("Active")
  def label(:expiring_soon), do: gettext("Expires soon")
  def label(:rotating), do: gettext("Being replaced")
  def label(:expired), do: gettext("Expired")
  def label(:revoked), do: gettext("Revoked")
  def label(:no_permission), do: gettext("No permission")
  def label(:owner_inactive), do: gettext("Owner inactive")

  @doc "A moment (a grace period's end) in the user's date format, time format and time zone."
  @spec moment(DateTime.t(), term()) :: String.t()
  def moment(%DateTime{} = at, user) do
    UtilsDate.format_date_with_user_timezone(at, user) <>
      " " <> UtilsDate.format_time_with_user_timezone(at, user)
  end

  @doc """
  The expiry as the UTC day it names, in the user's date format and without a time zone
  shift.
  """
  @spec expiry_date(DateTime.t(), term()) :: String.t()
  def expiry_date(%DateTime{} = expires_at, user),
    do: expires_at |> DateTime.to_date() |> UtilsDate.format_date_with_user_timezone(user)
end
