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
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
