defmodule PhoenixKit.Integration.Users.SecurityAuthorityTest do
  @moduledoc """
  Covers the three account-takeover paths closed together:

  * credential management (set password / mail a reset / change the address it
    goes to) is decided by role and rank, not by the `users` permission;
  * deactivating a user revokes their sessions instead of merely denying them;
  * the multi-session root account is resolved through the active-user filter,
    so a token that outlives a deactivation cannot be used to impersonate.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "sec_#{System.unique_integer([:positive])}@example.com"

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    Repo.get!(Auth.User, user.uuid)
  end

  # `Roles.assign_role/3` refuses the Owner role by design, so insert it.
  defp owner_user do
    user = plain_user()
    owner_role = Roles.get_role_by_name("Owner")

    {:ok, _} =
      %RoleAssignment{}
      |> RoleAssignment.changeset(%{user_uuid: user.uuid, role_uuid: owner_role.uuid})
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_uuid, :role_uuid])

    Repo.get!(Auth.User, user.uuid)
  end

  defp admin_user do
    user = plain_user()
    Roles.assign_role(user, "Admin")
    Repo.get!(Auth.User, user.uuid)
  end

  # The first account in a fresh sandbox is auto-promoted to Owner; seed a
  # throwaway one so every user below gets the role the test asked for.
  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  describe "can_manage_user_credentials?/2" do
    test "an Owner may manage anyone" do
      owner = owner_user()

      assert Auth.can_manage_user_credentials?(plain_user(), owner)
      assert Auth.can_manage_user_credentials?(admin_user(), owner)
      assert Auth.can_manage_user_credentials?(owner, owner)
    end

    test "an Admin may manage an ordinary user" do
      assert Auth.can_manage_user_credentials?(plain_user(), admin_user())
    end

    test "an Admin may NOT manage an Owner — the takeover this closes" do
      refute Auth.can_manage_user_credentials?(owner_user(), admin_user())
    end

    test "an Admin may NOT manage another Admin" do
      refute Auth.can_manage_user_credentials?(admin_user(), admin_user())
    end

    test "holding a permission is not holding a rank: a non-staff user may manage nobody" do
      # The `users` permission is what admits a visitor to /admin/users. It must
      # not decide whether they may take over an account there.
      staffless = plain_user()

      refute Auth.can_manage_user_credentials?(plain_user(), staffless)
      refute Auth.can_manage_user_credentials?(admin_user(), staffless)
      refute Auth.can_manage_user_credentials?(owner_user(), staffless)
    end

    test "everyone may manage their own account" do
      user = plain_user()

      assert Auth.can_manage_user_credentials?(user, user)
    end

    test "a missing actor is refused rather than defaulting open" do
      refute Auth.can_manage_user_credentials?(plain_user(), nil)
      refute Auth.can_manage_user_credentials?(nil, owner_user())
    end
  end

  describe "deactivation revokes sessions" do
    test "the session token stops resolving the moment the account is deactivated" do
      user = plain_user()
      token = Auth.generate_user_session_token(user)

      assert %Auth.User{uuid: uuid} = Auth.get_user_by_session_token(token)
      assert uuid == user.uuid

      {:ok, _deactivated} = Auth.update_user_status(user, %{"is_active" => false})

      refute Auth.get_user_by_session_token(token)
      assert Auth.get_all_user_session_tokens(user) == []
    end

    test "re-activating does not resurrect the revoked token" do
      user = plain_user()
      token = Auth.generate_user_session_token(user)

      {:ok, deactivated} = Auth.update_user_status(user, %{"is_active" => false})
      {:ok, _reactivated} = Auth.update_user_status(deactivated, %{"is_active" => true})

      refute Auth.get_user_by_session_token(token)
    end

    test "activation leaves existing sessions alone" do
      user = plain_user()
      token = Auth.generate_user_session_token(user)

      {:ok, _} = Auth.update_user_status(user, %{"is_active" => true})

      assert %Auth.User{} = Auth.get_user_by_session_token(token)
    end
  end

  describe "multi-session root resolution filters inactive accounts" do
    test "a token that outlives a deactivation cannot impersonate" do
      admin = admin_user()
      token = Auth.generate_user_session_token(admin)

      session = %{"pk_session_accounts" => [token], "user_token" => token}
      assert MultiSession.may_impersonate?(session)

      # Deactivate WITHOUT going through update_user_status/2, which now revokes
      # tokens — this is the defence-in-depth half: a token minted before that
      # fix, or an is_active flip made directly against the database, must still
      # be refused by the root resolution itself.
      admin
      |> Auth.User.status_changeset(%{"is_active" => false})
      |> Repo.update!()

      refute MultiSession.may_impersonate?(session)
      refute MultiSession.gate_allowed?(session)
    end
  end
end
