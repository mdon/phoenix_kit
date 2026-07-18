defmodule PhoenixKit.Email.SendProfiles do
  @moduledoc """
  Context for newsletter send profiles ("Send Settings").

  CRUD plus service-wide default management for `PhoenixKit.Email.SendProfile`.
  """

  import Ecto.Query

  alias PhoenixKit.Email.SendProfile

  def list_send_profiles do
    SendProfile
    |> order_by([sp], asc: sp.name)
    |> repo().all()
  end

  def get_send_profile!(uuid), do: repo().get!(SendProfile, uuid)

  def get_send_profile(uuid), do: repo().get(SendProfile, uuid)

  def create_send_profile(attrs) do
    %SendProfile{}
    |> SendProfile.changeset(attrs)
    |> repo().insert()
  end

  def update_send_profile(%SendProfile{} = send_profile, attrs) do
    send_profile
    |> SendProfile.changeset(attrs)
    |> repo().update()
  end

  def delete_send_profile(%SendProfile{} = send_profile), do: repo().delete(send_profile)

  @doc """
  Returns the service-wide default send profile, or `nil` if none is set.
  """
  def get_default_send_profile do
    # `enabled` is an operator kill-switch — a disabled profile must never be
    # resolved for sending, not even when it is the default.
    SendProfile
    |> where([sp], sp.is_default == true and sp.enabled == true)
    |> repo().one()
  end

  @doc """
  Makes `send_profile` the service-wide default, clearing any previous
  default in the same transaction. Bypasses the regular changeset
  (raw `is_default` flips only) since no other field changes — the
  partial unique index on `is_default` backstops concurrent races.
  """
  def set_default_send_profile(%SendProfile{uuid: uuid}) do
    repo().transaction(fn ->
      SendProfile
      |> where([sp], sp.is_default == true and sp.uuid != ^uuid)
      |> repo().update_all(set: [is_default: false])

      SendProfile
      |> where([sp], sp.uuid == ^uuid)
      |> repo().update_all(set: [is_default: true])

      get_send_profile!(uuid)
    end)
  rescue
    # Two concurrent "make default" clicks race on the partial unique index:
    # each transaction's clear-step can't see the other's uncommitted set-step,
    # so the loser's set-step trips the index and `update_all` RAISES — it
    # bypasses changesets, so nothing translates the constraint into an error
    # tuple. Normalize it: the LiveView's generic {:error, _} clause then shows
    # "could not set default" instead of the whole view crashing. Anything
    # other than exactly this constraint re-raises untouched.
    e in Postgrex.Error ->
      if e.postgres[:code] == :unique_violation and
           e.postgres[:constraint] == "idx_email_send_profiles_default" do
        {:error, :concurrent_default_change}
      else
        reraise e, __STACKTRACE__
      end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
