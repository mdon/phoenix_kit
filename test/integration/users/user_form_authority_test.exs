defmodule PhoenixKit.Integration.Users.UserFormAuthorityTest do
  @moduledoc """
  The credential rank rule as the admin form actually enforces it.

  `security_authority_test.exs` pins the rule at the context functions. This
  file pins it at the form, because the form is where the params arrive — and
  the takeover these rules exist to stop was reachable through a param the
  context rules never see.
  """
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.RoleAssignment
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes

  defp unique_email, do: "form_#{System.unique_integer([:positive])}@example.com"

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

  setup do
    {:ok, seed} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, _} = Auth.admin_confirm_user(seed)
    :ok
  end

  describe "custom_fields cannot carry schema identity fields past the rank rule" do
    # `Auth.update_user_fields/2` resolves each key with `String.to_existing_atom/1`
    # and writes `:email` / `:username` straight into the schema when the name
    # matches. The form was handing it `params["custom_fields"]` verbatim, so the
    # `Map.drop` that protects the profile params never saw these — an actor who
    # may not manage the target's credentials could rewrite the address a reset
    # link is delivered to, which is the whole takeover in one request.
    # The event is pushed straight at the LiveView rather than through `form/3`.
    # That is not a shortcut, it is the threat model: `form/3` refuses params
    # with no matching rendered input, and the form renders no
    # `custom_fields[email]` box — but nothing stops a client from putting the
    # key on the wire, which is exactly how this reaches the context.
    test "an Admin cannot rewrite an Owner's email through custom_fields", %{conn: conn} do
      owner = owner_user()
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, Routes.path("/admin/users/edit/#{owner.uuid}"))

      render_submit(view, "save_user", %{
        "user" => %{
          "first_name" => "Harmless",
          "custom_fields" => %{"email" => "attacker@example.com"}
        }
      })

      assert Repo.get!(Auth.User, owner.uuid).email == owner.email
    end

    test "an Admin cannot rewrite an Owner's username through custom_fields", %{conn: conn} do
      owner = owner_user()
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, Routes.path("/admin/users/edit/#{owner.uuid}"))

      render_submit(view, "save_user", %{
        "user" => %{
          "first_name" => "Harmless",
          "custom_fields" => %{"username" => "attacker"}
        }
      })

      assert Repo.get!(Auth.User, owner.uuid).username == owner.username
    end

    test "a stale authority assign refuses cleanly instead of crashing", %{conn: conn} do
      # `can_manage_credentials` is computed once at mount. The context rule is
      # evaluated again at write time, so the two can disagree: mount while the
      # target is an ordinary user, promote them, then save with a password.
      #
      # Before this was handled, the context's `{:error, :insufficient_permissions}`
      # fell into the clause that expects a changeset, `merge_password_errors/2`
      # called `.errors` on the atom and the LiveView died — after the profile
      # write had already committed, leaving a partial update behind.
      target = plain_user()
      conn = log_in_user(conn, admin_user())

      {:ok, view, _html} = live(conn, Routes.path("/admin/users/edit/#{target.uuid}"))

      owner_role = Roles.get_role_by_name("Owner")

      {:ok, _} =
        %RoleAssignment{}
        |> RoleAssignment.changeset(%{user_uuid: target.uuid, role_uuid: owner_role.uuid})
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_uuid, :role_uuid])

      before = Repo.get!(Auth.User, target.uuid)

      # A crash inside `handle_event/3` surfaces here as a raise from
      # `render_submit/3`, so the call itself is the liveness assertion — and a
      # clean refusal (or a redirect after saving the non-credential fields) is
      # not a failure. What must hold either way is that neither credential of an
      # account this actor no longer outranks was rewritten.
      #
      # `email` is in the payload on purpose. It is what makes this test
      # discriminating: the password is protected by the context regardless, but
      # the address is dropped only by the form — and only if the form asks the
      # rank question against the target as it is now rather than as it was at
      # mount. Revert the reload and this assertion goes red.
      try do
        render_submit(view, "save_user", %{
          "user" => %{
            "first_name" => "Renamed",
            "email" => "attacker@example.com",
            "password" => "AttackerPassword123!"
          }
        })
      catch
        :exit, {{:shutdown, {:redirect, _, _}}, _} -> :ok
      end

      after_submit = Repo.get!(Auth.User, target.uuid)
      assert after_submit.hashed_password == before.hashed_password
      assert after_submit.email == before.email
    end

    test "an Admin may still set these fields on a user they do outrank", %{conn: conn} do
      target = plain_user()
      conn = log_in_user(conn, admin_user())
      new_email = unique_email()

      {:ok, view, _html} = live(conn, Routes.path("/admin/users/edit/#{target.uuid}"))

      render_submit(view, "save_user", %{"user" => %{"email" => new_email}})

      assert Repo.get!(Auth.User, target.uuid).email == new_email
    end
  end
end
