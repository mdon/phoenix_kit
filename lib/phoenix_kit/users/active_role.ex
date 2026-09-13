defmodule PhoenixKit.Users.ActiveRole do
  @moduledoc """
  The role a user is currently *acting as*.

  By default a user's access is the union of every role they hold. With the
  role switcher on (`role_switcher_enabled`), a user holding two or more
  **switchable** roles acts as exactly one of them at a time, and their scope —
  roles and permissions alike — is narrowed to that role plus every
  **always-on** role they hold. An Admin who switches to "Seller" has no admin
  access at all until they switch back.

  ## Switchable and always-on roles

    * Owner and Admin are always switchable — otherwise narrowing could never
      take admin access away.
    * User is always on: it applies whichever role is active.
    * Custom roles are switchable unless listed in
      `role_switcher_always_on_roles` (comma-separated role uuids).

  ## Where the active role lives

  In the user's `custom_fields` under `"active_role_uuid"`, and it is applied
  inside `PhoenixKit.Users.Auth.Scope.for_user/1`. Never hold it anywhere else:
  the scope is rebuilt from scratch with `for_user/1` in many places (plugs,
  every LiveView mount, the role-change refresh, controllers, sibling
  packages), and each of those would silently widen a role kept outside it
  back to the full union.

  The stored value is never trusted on its own. `resolve/3` only ever returns a
  role the user holds and that is switchable right now, so the narrowed scope
  can never exceed the user's real grants. Nothing here writes on read.

  The functions taking a `t:config/0` are pure, so the rules are unit-testable
  without a database.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Role
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Users.ScopeNotifier

  @custom_field_key "active_role_uuid"

  @type role :: %{uuid: String.t(), name: String.t()}

  @type config :: %{
          enabled?: boolean(),
          sign_in_role: :staff_first | :last_used,
          always_on: [String.t()]
        }

  @doc "The `custom_fields` key the active role's uuid is stored under."
  @spec custom_field_key() :: String.t()
  def custom_field_key, do: @custom_field_key

  @doc """
  The switcher configuration, read from settings.

  Only the enabled flag is read while the feature is off.
  """
  @spec config() :: config()
  def config do
    if Settings.get_boolean_setting("role_switcher_enabled", false) do
      %{
        enabled?: true,
        sign_in_role:
          parse_sign_in_role(Settings.get_setting_cached("role_switcher_sign_in_role")),
        always_on: parse_always_on(Settings.get_setting_cached("role_switcher_always_on_roles"))
      }
    else
      disabled_config()
    end
  end

  @doc false
  @spec disabled_config() :: config()
  def disabled_config, do: %{enabled?: false, sign_in_role: :staff_first, always_on: []}

  @doc """
  Parses the `role_switcher_sign_in_role` setting. Anything unrecognised is
  `:staff_first`, the default.
  """
  @spec parse_sign_in_role(term()) :: :staff_first | :last_used
  def parse_sign_in_role("last_used"), do: :last_used
  def parse_sign_in_role(_), do: :staff_first

  @doc """
  Parses the `role_switcher_always_on_roles` setting: comma-separated role
  uuids, returned without duplicates. Anything that is not a string is `[]`.
  """
  @spec parse_always_on(term()) :: [String.t()]
  def parse_always_on(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_always_on(_), do: []

  @doc """
  Whether `role` is a mode the user can act as, rather than always on.
  """
  @spec switchable?(role(), config()) :: boolean()
  def switchable?(%{name: name, uuid: uuid}, config) do
    system = Role.system_roles()

    cond do
      name in [system.owner, system.admin] -> true
      name == system.user -> false
      true -> uuid not in config.always_on
    end
  end

  @doc """
  The held roles that are switchable, in the order given.
  """
  @spec switchable_roles([role()], config()) :: [role()]
  def switchable_roles(held, config), do: Enum.filter(held, &switchable?(&1, config))

  @doc """
  The role a user holding `held` acts as, given the uuid stored on their
  record. `nil` means no narrowing: the feature is off, or the user holds
  fewer than two switchable roles.

  A stored uuid naming a role that is not held, or not switchable, is ignored
  and the default applies: Owner, then Admin, then the first switchable role
  by name.
  """
  @spec resolve([role()], String.t() | nil, config()) :: role() | nil
  def resolve(held, stored_uuid, %{enabled?: true} = config) when is_list(held) do
    case switchable_roles(held, config) do
      [_, _ | _] = candidates ->
        Enum.find(candidates, &(&1.uuid == stored_uuid)) || default_role(candidates)

      _ ->
        nil
    end
  end

  def resolve(_held, _stored_uuid, _config), do: nil

  @doc """
  The role a user should act as right after signing in.

  Under `:staff_first` (the default) an Owner or Admin starts as their highest
  staff role whatever they used last; everyone else continues as the role they
  last used. Under `:last_used` everyone continues as the role they last used.
  """
  @spec sign_in_role([role()], String.t() | nil, config()) :: role() | nil
  def sign_in_role(held, stored_uuid, %{sign_in_role: :staff_first} = config) do
    system = Role.system_roles()

    case resolve(held, nil, config) do
      %{name: name} = staff when name in [system.owner, system.admin] -> staff
      _ -> resolve(held, stored_uuid, config)
    end
  end

  def sign_in_role(held, stored_uuid, config), do: resolve(held, stored_uuid, config)

  @doc """
  The roles in effect while acting as `active`: the active role plus every
  always-on role held. With no active role, every held role.
  """
  @spec effective_roles([role()], role() | nil, config()) :: [role()]
  def effective_roles(held, nil, _config), do: held

  def effective_roles(held, %{uuid: active_uuid}, config) do
    Enum.filter(held, &(&1.uuid == active_uuid or not switchable?(&1, config)))
  end

  @doc """
  The role uuid stored on the user's record, or `nil`.
  """
  @spec stored_role_uuid(User.t()) :: String.t() | nil
  def stored_role_uuid(%User{custom_fields: %{@custom_field_key => uuid}}) when is_binary(uuid),
    do: uuid

  def stored_role_uuid(%User{}), do: nil

  @doc false
  # Called by `Scope.for_user/1`. Returns the active role (or `nil`) and the
  # roles in effect. A single held role can never yield two switchable
  # candidates, so the common case skips the settings reads entirely.
  @spec narrow(User.t(), [role()]) :: {role() | nil, [role()]}
  def narrow(%User{}, held) when length(held) < 2, do: {nil, held}

  def narrow(%User{} = user, held) do
    config = config()
    active = resolve(held, stored_role_uuid(user), config)
    {active, effective_roles(held, active, config)}
  end

  @doc """
  Makes `role_uuid` the role `user` acts as.

  Refused unless the switcher is on and the role is one of the user's
  switchable roles — and there are at least two of those, or there is nothing
  to switch between. Switching to the role already in effect writes nothing.

  On a change the choice is stored on the user, logged as
  `session.role_switched`, and broadcast through `ScopeNotifier`, so every open
  LiveView of this user — on every device — rebuilds its scope and leaves pages
  the new role cannot reach.

  The caller decides whether the session may switch at all (e.g. not while
  impersonating); this function only knows the user.
  """
  @spec switch(User.t(), String.t()) ::
          {:ok, User.t(), role()} | {:error, :disabled | :not_switchable | term()}
  def switch(%User{} = user, role_uuid) when is_binary(role_uuid) do
    config = config()
    held = Roles.get_user_role_records(user)
    candidates = switchable_roles(held, config)
    target = Enum.find(candidates, &(&1.uuid == role_uuid))
    current = resolve(held, stored_role_uuid(user), config)

    cond do
      not config.enabled? -> {:error, :disabled}
      is_nil(target) or length(candidates) < 2 -> {:error, :not_switchable}
      current && current.uuid == target.uuid -> {:ok, user, target}
      true -> store_switch(user, current, target)
    end
  end

  defp store_switch(user, current, target) do
    case store(user, target.uuid) do
      {:ok, user} ->
        log_switch(user, current, target)
        ScopeNotifier.broadcast_active_role_changed(user)
        {:ok, user, target}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Applies the sign-in rule (`sign_in_role/3`) to a user who is signing in and
  returns the user as stored afterwards.

  Called by `PhoenixKitWeb.Users.Auth.log_in_user/3` before the post-login
  destination is resolved, so the landing page matches the role the session
  starts in. Never raises: signing in must not fail over this, and a user left
  with their previous stored role is still narrowed by `resolve/3` on every
  read.
  """
  @spec apply_sign_in_role(User.t()) :: User.t()
  def apply_sign_in_role(%User{} = user) do
    config = config()

    if config.enabled? do
      stored = stored_role_uuid(user)

      case sign_in_role(Roles.get_user_role_records(user), stored, config) do
        nil ->
          user

        %{uuid: ^stored} ->
          user

        role ->
          case store(user, role.uuid) do
            {:ok, updated} ->
              ScopeNotifier.broadcast_active_role_changed(updated)
              updated

            {:error, _} ->
              user
          end
      end
    else
      user
    end
  rescue
    error ->
      Logger.warning("ActiveRole.apply_sign_in_role failed: #{inspect(error)}")
      user
  end

  defp store(user, role_uuid) do
    Auth.merge_user_custom_fields(user, %{@custom_field_key => role_uuid},
      ensure_definitions: false
    )
  end

  # The user is both actor and target, so `Activity.log/1` fans out no
  # notification.
  defp log_switch(user, from, to) do
    PhoenixKit.Activity.log(%{
      action: "session.role_switched",
      module: "users",
      mode: "auto",
      actor_uuid: user.uuid,
      resource_type: "user",
      resource_uuid: user.uuid,
      target_uuid: user.uuid,
      metadata: %{"from" => from && from.name, "to" => to.name}
    })
  rescue
    _ -> :ok
  end

  defp default_role(candidates) do
    system = Role.system_roles()

    Enum.find(candidates, &(&1.name == system.owner)) ||
      Enum.find(candidates, &(&1.name == system.admin)) ||
      Enum.min_by(candidates, & &1.name)
  end
end
