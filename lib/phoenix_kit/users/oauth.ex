defmodule PhoenixKit.Users.OAuth do
  @moduledoc """
  OAuth authentication context for PhoenixKit.

  Handles OAuth authentication flows for external providers like Google, Apple, GitHub.
  """

  import Ecto.Query, warn: false
  alias PhoenixKit.RepoHelper, as: Repo

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.OAuthProvider

  @doc """
  Handles OAuth callback from Ueberauth.
  """
  def handle_oauth_callback(%Ueberauth.Auth{} = auth, opts \\ []) do
    oauth_data = extract_oauth_data(auth)
    track_geolocation = Keyword.get(opts, :track_geolocation, false)
    ip_address = Keyword.get(opts, :ip_address)
    referral_code = Keyword.get(opts, :referral_code)

    Repo.transaction(fn ->
      with {:ok, user, _status} <- find_or_create_user(oauth_data, track_geolocation, ip_address),
           {:ok, _provider} <- link_oauth_provider(user, oauth_data),
           :ok <- maybe_process_referral_code(user, referral_code) do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Finds an existing user by email or creates a new one from OAuth data.
  """
  def find_or_create_user(oauth_data, track_geolocation \\ false, ip_address \\ nil) do
    case Auth.get_user_by_email(oauth_data.email) do
      %User{} = user ->
        {:ok, user, :found}

      nil ->
        case register_oauth_user(oauth_data, track_geolocation, ip_address) do
          {:ok, user} -> {:ok, user, :created}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Links an OAuth provider to a user account.
  """
  def link_oauth_provider(%User{} = user, oauth_data) when is_map(oauth_data) do
    attrs = %{
      user_id: user.id,
      provider: oauth_data.provider,
      provider_uid: oauth_data.provider_uid,
      provider_email: oauth_data.email,
      access_token: oauth_data[:access_token],
      refresh_token: oauth_data[:refresh_token],
      token_expires_at: oauth_data[:token_expires_at],
      raw_data: build_raw_data(oauth_data)
    }

    %OAuthProvider{}
    |> OAuthProvider.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :user_id, :provider, :inserted_at]},
      conflict_target: [:user_id, :provider]
    )
  end

  @doc """
  Gets all OAuth providers for a user.
  """
  def get_user_oauth_providers(user_id) when is_integer(user_id) do
    from(p in OAuthProvider,
      where: p.user_id == ^user_id,
      order_by: [desc: p.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Unlinks an OAuth provider from a user.
  """
  def unlink_oauth_provider(user_id, provider) when is_integer(user_id) and is_binary(provider) do
    case from(p in OAuthProvider, where: p.user_id == ^user_id and p.provider == ^provider)
         |> Repo.one() do
      nil -> {:error, :not_found}
      provider_record -> Repo.delete(provider_record)
    end
  end

  # Private functions

  defp extract_oauth_data(%Ueberauth.Auth{} = auth) do
    %{
      provider: to_string(auth.provider),
      provider_uid: auth.uid,
      email: auth.info.email,
      first_name: auth.info.first_name,
      last_name: auth.info.last_name,
      image: auth.info.image,
      access_token: get_in(auth.credentials, [:token]),
      refresh_token: get_in(auth.credentials, [:refresh_token]),
      token_expires_at: get_token_expires_at(auth.credentials),
      raw_info: auth.extra.raw_info
    }
  end

  defp get_token_expires_at(%{expires_at: expires_at}) when is_integer(expires_at) do
    DateTime.from_unix!(expires_at)
  end

  defp get_token_expires_at(%{expires: true, expires_at: expires_at})
       when is_integer(expires_at) do
    DateTime.from_unix!(expires_at)
  end

  defp get_token_expires_at(_), do: nil

  defp register_oauth_user(oauth_data, track_geolocation, ip_address) do
    attrs = %{
      email: oauth_data.email,
      password: generate_random_password(),
      first_name: oauth_data.first_name,
      last_name: oauth_data.last_name,
      confirmed_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    if track_geolocation && ip_address do
      Auth.register_user_with_geolocation(attrs, ip_address)
    else
      Auth.register_user(attrs)
    end
  end

  defp generate_random_password do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 32)
  end

  defp build_raw_data(oauth_data) do
    %{
      image: oauth_data[:image],
      raw_info: oauth_data[:raw_info] || %{}
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp maybe_process_referral_code(_user, nil), do: :ok

  defp maybe_process_referral_code(user, referral_code) when is_binary(referral_code) do
    if Code.ensure_loaded?(PhoenixKit.ReferralCodes) do
      case PhoenixKit.ReferralCodes.get_code_by_string(referral_code) do
        nil -> :ok
        code -> PhoenixKit.ReferralCodes.use_code(code.code, user.id)
      end
    end

    :ok
  end
end
