defmodule PhoenixKit.API.Access do
  @moduledoc """
  The rights of a person behind an admin page, read again from the database.

  A LiveView captures the person's `Scope` at mount; a role may change after that, and
  core's PubSub refresh of the page is asynchronous and can be missed. An event that
  changes something (a key, a setting, an approval) must not act with rights the person
  no longer has, so it calls `fresh_scope/1`: the user is loaded again and must still be
  active, and both the scope captured at mount (which may be narrowed to one active role)
  and a scope built now from **all** held roles (the way the API computes rights) must
  hold `api`. The fresh scope is the one to hand to `PhoenixKit.API.Keys`,
  `PhoenixKit.API.ServiceUsers` and `PhoenixKit.API.Approvals`, which check again on
  their own.
  """

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @doc "`{:ok, fresh_scope}` while the person may still manage the API, else `:error`."
  @spec fresh_scope(Scope.t() | nil) :: {:ok, Scope.t()} | :error
  def fresh_scope(current) do
    with true <- Scope.can?(current, "api"),
         uuid when is_binary(uuid) <- Scope.user_uuid(current),
         user when not is_nil(user) <- Auth.get_user(uuid),
         user when not is_nil(user) <- Auth.ensure_active_user(user),
         fresh = Scope.for_user(user, narrow: false),
         true <- Scope.can?(fresh, "api") do
      {:ok, fresh}
    else
      _ -> :error
    end
  end
end
