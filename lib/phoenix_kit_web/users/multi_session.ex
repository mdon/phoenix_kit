defmodule PhoenixKitWeb.Users.MultiSession do
  @moduledoc """
  Multi-account session switching for Owner/Admin testing.

  The Plug session holds an ordered stack of raw session tokens under
  `:pk_session_accounts`. `hd/1` of the stack is the ROOT account (the original
  login). The currently active token stays in `:user_token`, so all existing auth
  resolution (`fetch_phoenix_kit_current_*`, `on_mount`) is untouched.

  Read helpers (`gate_allowed?/1`, `list_accounts/1`) take the string-keyed session
  map (works from both the plug and the LiveView on_mount). Conn-mutating ops
  (`add_account/3`, `switch_to/2`, `remove_account/2`, logout helpers) take and
  return a `Plug.Conn`.
  """

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @max_accounts 5

  @doc "Maximum number of accounts allowed in one stack."
  def max_accounts, do: @max_accounts

  @doc """
  The list of raw session tokens in the stack. Falls back to the single active
  token when no explicit stack is stored, and `[]` when there is no active token.
  """
  def stack_tokens(session) when is_map(session) do
    case session["pk_session_accounts"] do
      [_ | _] = stack -> stack
      _ -> session["user_token"] |> List.wrap()
    end
  end

  @doc """
  True when the ROOT account is an Owner/Admin AND the `multi_session_enabled`
  setting is on. Evaluated against the root so the switcher stays visible even
  when a low-privilege account is active.
  """
  def gate_allowed?(session) when is_map(session) do
    Settings.get_boolean_setting("multi_session_enabled", true) and root_owner_or_admin?(session)
  end

  defp root_owner_or_admin?(session) do
    with [root_token | _] <- stack_tokens(session),
         %Auth.User{} = user <- Auth.get_user_by_session_token(root_token) do
      scope = Scope.for_user(user)
      Scope.owner?(scope) or Scope.admin?(scope)
    else
      _ -> false
    end
  end

  @doc """
  Resolves each stack token to a render struct:
  `%{ref, user, email, role, active?, root?}`. Tokens that no longer resolve to a
  user (expired/deleted) are dropped.
  """
  def list_accounts(session) when is_map(session) do
    active = session["user_token"]
    tokens = stack_tokens(session)

    tokens
    |> Enum.with_index()
    |> Enum.flat_map(fn {token, index} ->
      case {Auth.get_user_by_session_token(token), Auth.get_session_token_record(token)} do
        {%Auth.User{} = user, %{uuid: ref}} ->
          [
            %{
              ref: ref,
              user: user,
              email: user.email,
              role: role_label(user),
              active?: token == active,
              root?: index == 0
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp role_label(user) do
    scope = Scope.for_user(user)

    cond do
      Scope.owner?(scope) -> "Owner"
      Scope.admin?(scope) -> "Admin"
      true -> "User"
    end
  end
end
