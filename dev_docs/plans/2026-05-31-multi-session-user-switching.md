# Multi-Session User Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an Owner/Admin be logged into several real user accounts at once and switch the active account from the header dropdown, to test the app under different roles.

**Architecture:** Genuine multi-account (each account added with email+password). The Plug session holds an ordered stack of raw session tokens (`:pk_session_accounts`); the active token stays in `:user_token` so all existing auth resolution is untouched. Switching copies the chosen token into `:user_token`. All mutations are HTTP controller actions (LiveView cannot write cookies). The switcher is gated to an Owner/Admin root account plus a `multi_session_enabled` setting.

**Tech Stack:** Elixir, Phoenix, Phoenix LiveView, Ecto/PostgreSQL, daisyUI 5.

**Design spec:** `dev_docs/plans/multi-session-user-switching.md`

**Module placement note:** The spec named `PhoenixKit.Users.MultiSession`. Because every operation reads/writes the Plug session (`conn`), this plan places the module in the web layer as **`PhoenixKitWeb.Users.MultiSession`** (`lib/phoenix_kit_web/users/multi_session.ex`), mirroring where `log_in_user/3` / `log_out_user/1` already live (`lib/phoenix_kit_web/users/auth.ex`). Pure read helpers (`gate_allowed?/1`, `list_accounts/1`) take the string-keyed session map so they work from both the plug and the LiveView `on_mount` paths.

**Session shape (string keys — Plug normalizes all session keys to strings):**
- `"user_token"` — raw binary token of the **active** account (unchanged semantics).
- `"live_socket_id"` — `"phoenix_kit_sessions:#{Base.url_encode64(active_token)}"` (unchanged).
- `"pk_session_accounts"` — **new**: ordered list of raw tokens; `hd/1` is the **root** account. Absent ⇒ treat as `[active_token]`.

**`token_ref`:** the opaque, non-secret handle used in markup/URLs = the `UserToken.uuid` (DB primary key) of that stack token, obtained via `PhoenixKit.Users.Auth.get_session_token_record/1`. Raw tokens never appear in HTML or URLs.

---

## File Structure

- **Create** `lib/phoenix_kit_web/users/multi_session.ex` — the multi-account session context (read helpers + conn-mutating ops + audit logging).
- **Modify** `lib/phoenix_kit/settings/settings.ex` — add `"multi_session_enabled" => "true"` to `get_defaults/0`.
- **Modify** `lib/phoenix_kit_web/live/settings.html.heex` — add the toggle UI.
- **Modify** `lib/phoenix_kit_web/integration.ex` — add 3 routes in `generate_basic_scope/1` **and** `generate_localized_routes/2`.
- **Modify** `lib/phoenix_kit_web/users/session.ex` — add `add_account/2`, `set_active_account/2`, `remove_account/2`; extend `delete/2` for active-only vs all.
- **Modify** `lib/phoenix_kit_web/users/auth.ex` — in `fetch_phoenix_kit_current_scope/2` (plug) and the `:phoenix_kit_mount_current_scope` `on_mount`, assign `:phoenix_kit_session_accounts` + `:phoenix_kit_multi_session_allowed?`.
- **Modify** `lib/phoenix_kit_web/components/admin_nav.ex` — add the switcher section + add-account modal to `admin_user_dropdown/1`; add `accounts` / `multi_session_allowed?` attrs.
- **Modify** `lib/phoenix_kit_web/components/layout_wrapper.ex` — thread the two new assigns into `admin_user_dropdown`.
- **Create** `test/phoenix_kit_web/users/multi_session_test.exs` — unit tests for pure stack/ref logic.
- **Create** `test/integration/users/multi_session_test.exs` — DataCase/ConnCase end-to-end.
- **Create** `test/integration/phoenix_kit_web/users/session_multi_test.exs` — controller gate-denial + switch/remove/logout flows.

---

## Task 1: `multi_session_enabled` setting + toggle UI

**Files:**
- Modify: `lib/phoenix_kit/settings/settings.ex` (`get_defaults/0`, ~line 166)
- Modify: `lib/phoenix_kit_web/live/settings.html.heex` (after the `notifications_enabled` block, ~line 251)

- [ ] **Step 1: Add the default.** In `get_defaults/0` add the key next to `"notifications_enabled" => "true"`:

```elixir
"multi_session_enabled" => "true",
```

- [ ] **Step 2: Add the toggle UI.** In `settings.html.heex`, immediately after the closing `</div>` of the Notifications `form-control` block, insert:

```heex
<%!-- Multiple Sessions (account switcher) --%>
<div class="form-control w-full">
  <label class="label">
    <span class="label-text text-base font-medium">
      {gettext("Multiple Sessions")}
    </span>
    <span class="label-text-alt text-sm text-base-content/60">
      {gettext("Owner/Admin account switcher for testing under different roles")}
    </span>
  </label>
  <div class="flex items-center gap-3">
    <input type="hidden" name="settings[multi_session_enabled]" value="false" />
    <input
      name="settings[multi_session_enabled]"
      type="checkbox"
      value="true"
      checked={@settings["multi_session_enabled"] == "true"}
      class="checkbox checkbox-primary"
    />
    <span class="label-text">
      {gettext("Enable the multi-account switcher in the header")}
    </span>
  </div>
  <div class="label">
    <span class="label-text-alt text-xs text-base-content/50">
      {gettext(
        "When on, an Owner/Admin can add other accounts (with their password) and switch between them from the user menu."
      )}
    </span>
  </div>
</div>
```

- [ ] **Step 3: Verify compile + render.**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. (`save_settings` already persists every `settings[...]` key — no handler change.)

- [ ] **Step 4: Commit.**

```bash
git add lib/phoenix_kit/settings/settings.ex lib/phoenix_kit_web/live/settings.html.heex
git commit -m "Add multi_session_enabled setting and admin toggle"
```

---

## Task 2: `MultiSession` read helpers (`gate_allowed?/1`, `list_accounts/1`)

**Files:**
- Create: `lib/phoenix_kit_web/users/multi_session.ex`
- Test: `test/phoenix_kit_web/users/multi_session_test.exs`

- [ ] **Step 1: Write the failing unit test** for the pure stack/ref helpers (no DB). Create `test/phoenix_kit_web/users/multi_session_test.exs`:

```elixir
defmodule PhoenixKitWeb.Users.MultiSessionTest do
  use ExUnit.Case, async: true

  alias PhoenixKitWeb.Users.MultiSession

  describe "stack_tokens/1" do
    test "returns the explicit stack when present" do
      session = %{"user_token" => "a", "pk_session_accounts" => ["a", "b"]}
      assert MultiSession.stack_tokens(session) == ["a", "b"]
    end

    test "falls back to [active_token] when stack absent" do
      session = %{"user_token" => "a"}
      assert MultiSession.stack_tokens(session) == ["a"]
    end

    test "returns [] when no active token" do
      assert MultiSession.stack_tokens(%{}) == []
    end
  end

  describe "max_accounts/0" do
    test "is 5" do
      assert MultiSession.max_accounts() == 5
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `mix test test/phoenix_kit_web/users/multi_session_test.exs`
Expected: FAIL — `module PhoenixKitWeb.Users.MultiSession is not available`.

- [ ] **Step 3: Create the module with read helpers.** Create `lib/phoenix_kit_web/users/multi_session.ex`:

```elixir
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

  import Plug.Conn

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope

  @stack_key :pk_session_accounts
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
```

- [ ] **Step 4: Run the unit test to verify it passes.**

Run: `mix test test/phoenix_kit_web/users/multi_session_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit.**

```bash
git add lib/phoenix_kit_web/users/multi_session.ex test/phoenix_kit_web/users/multi_session_test.exs
git commit -m "Add MultiSession read helpers (stack, gate, list_accounts)"
```

---

## Task 3: `MultiSession` conn-mutating ops (add / switch / remove / logout)

**Files:**
- Modify: `lib/phoenix_kit_web/users/multi_session.ex`
- Test: `test/integration/users/multi_session_test.exs`

- [ ] **Step 1: Write the failing integration test.** Create `test/integration/users/multi_session_test.exs`:

```elixir
defmodule PhoenixKit.Integration.Users.MultiSessionTest do
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "ms_#{System.unique_integer([:positive])}@example.com"

  defp owner_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    {:ok, _} = Roles.assign_role(user, "Owner")
    PhoenixKit.Test.Repo.get!(Auth.User, user.uuid)
  end

  defp plain_user do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    PhoenixKit.Test.Repo.get!(Auth.User, user.uuid)
  end

  # Build a conn whose root (active) account is `user`, logged in like log_in_user.
  defp conn_for(user) do
    token = Auth.generate_user_session_token(user)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  describe "add_account/3" do
    test "appends a real account and makes it active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      session = Plug.Conn.get_session(conn)
      assert length(session["pk_session_accounts"]) == 2
      # active token now resolves to the added user
      assert Auth.get_user_by_session_token(session["user_token"]).uuid == other.uuid
      # root unchanged
      [root_token | _] = session["pk_session_accounts"]
      assert Auth.get_user_by_session_token(root_token).uuid == owner.uuid
    end

    test "rejects invalid credentials, stack unchanged" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)

      assert {:error, :invalid_credentials} =
               MultiSession.add_account(conn, other.email, "wrong-password")

      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "rejects when the stack is full" do
      owner = owner_user()
      conn = conn_for(owner)

      conn =
        Enum.reduce(1..(MultiSession.max_accounts() - 1), conn, fn _, acc ->
          u = plain_user()
          {:ok, acc} = MultiSession.add_account(acc, u.email, "ValidPassword123!")
          acc
        end)

      full = plain_user()
      assert {:error, :stack_full} = MultiSession.add_account(conn, full.email, "ValidPassword123!")
    end
  end

  describe "switch_to/2" do
    test "activates a token already in the stack by ref" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:ok, conn, user} = MultiSession.switch_to(conn, root.ref)
      assert user.uuid == owner.uuid
      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "rejects a ref not in the stack" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:error, :not_in_stack} = MultiSession.switch_to(conn, Ecto.UUID.generate())
    end
  end

  describe "remove_account/2" do
    test "deletes a non-root token from DB and stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")

      accounts = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      added = Enum.find(accounts, &(not &1.root?))
      added_token = Enum.at(Plug.Conn.get_session(conn)["pk_session_accounts"], 1)

      assert {:ok, conn} = MultiSession.remove_account(conn, added.ref)
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
      assert is_nil(Auth.get_user_by_session_token(added_token))
      # active fell back to root
      assert Auth.get_user_by_session_token(Plug.Conn.get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "refuses to remove the root account" do
      owner = owner_user()
      conn = conn_for(owner)
      [root | _] = MultiSession.list_accounts(Plug.Conn.get_session(conn))
      assert {:error, :cannot_remove_root} = MultiSession.remove_account(conn, root.ref)
    end
  end

  describe "log_out_active/1 and delete_all_stack_tokens/1" do
    test "log_out_active switches to root when a non-root account is active" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      added_token = Plug.Conn.get_session(conn)["user_token"]

      assert {:switched, conn, user} = MultiSession.log_out_active(conn)
      assert user.uuid == owner.uuid
      assert is_nil(Auth.get_user_by_session_token(added_token))
      assert length(Plug.Conn.get_session(conn)["pk_session_accounts"]) == 1
    end

    test "log_out_active returns :full when the root account is active" do
      owner = owner_user()
      conn = conn_for(owner)
      assert {:full, _conn} = MultiSession.log_out_active(conn)
    end

    test "delete_all_stack_tokens deletes every token in the stack" do
      owner = owner_user()
      other = plain_user()
      conn = conn_for(owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      tokens = Plug.Conn.get_session(conn)["pk_session_accounts"]

      _conn = MultiSession.delete_all_stack_tokens(conn)
      assert Enum.all?(tokens, &is_nil(Auth.get_user_by_session_token(&1)))
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `mix test test/integration/users/multi_session_test.exs`
Expected: FAIL — `function MultiSession.add_account/3 is undefined`.

- [ ] **Step 3: Add the mutating ops** to `lib/phoenix_kit_web/users/multi_session.ex` (append before the final `end`):

```elixir
  @doc """
  Validates credentials and appends a real session for that user to the stack,
  making it the active account. The new account may be any role; the gate is
  enforced by the caller (controller) against the root account.
  """
  def add_account(conn, email_or_username, password) do
    session = get_session(conn)
    stack = stack_tokens(session)

    cond do
      length(stack) >= @max_accounts ->
        {:error, :stack_full}

      true ->
        case Auth.get_user_by_email_or_username_and_password(email_or_username, password) do
          {:ok, %Auth.User{is_active: true} = user} ->
            token = Auth.generate_user_session_token(user)

            conn =
              conn
              |> put_session(@stack_key, stack ++ [token])
              |> put_active_token(token)

            log_event("session.account_added", root_user(session), user)
            {:ok, conn}

          {:ok, %Auth.User{}} ->
            {:error, :inactive}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc "Activates a token already present in the stack, identified by `ref`."
  def switch_to(conn, ref) do
    session = get_session(conn)
    stack = stack_tokens(session)

    case find_token_by_ref(stack, ref) do
      nil ->
        {:error, :not_in_stack}

      token ->
        user = Auth.get_user_by_session_token(token)
        conn = put_active_token(conn, token)
        log_event("session.switched", root_user(session), user)
        {:ok, conn, user}
    end
  end

  @doc "Removes a non-root token from the stack and deletes it from the DB."
  def remove_account(conn, ref) do
    session = get_session(conn)
    stack = stack_tokens(session)
    [root_token | _] = stack

    case find_token_by_ref(stack, ref) do
      nil ->
        {:error, :not_in_stack}

      ^root_token ->
        {:error, :cannot_remove_root}

      token ->
        Auth.delete_user_session_token(token)
        new_stack = List.delete(stack, token)
        conn = put_session(conn, @stack_key, new_stack)

        conn =
          if session["user_token"] == token,
            do: put_active_token(conn, root_token),
            else: conn

        {:ok, conn}
    end
  end

  @doc """
  Logs out the active account. When a non-root account is active, deletes it and
  switches back to root (`{:switched, conn, root_user}`). When the root account is
  active, signals a full logout (`{:full, conn}`) for the caller to run.
  """
  def log_out_active(conn) do
    session = get_session(conn)
    stack = stack_tokens(session)
    [root_token | _] = stack
    active = session["user_token"]

    if active == root_token or length(stack) <= 1 do
      {:full, conn}
    else
      Auth.delete_user_session_token(active)
      new_stack = List.delete(stack, active)
      root_user = Auth.get_user_by_session_token(root_token)

      conn =
        conn
        |> put_session(@stack_key, new_stack)
        |> put_active_token(root_token)

      {:switched, conn, root_user}
    end
  end

  @doc "Deletes every stack token from the DB (used by 'Log out all')."
  def delete_all_stack_tokens(conn) do
    conn |> get_session() |> stack_tokens() |> Enum.each(&Auth.delete_user_session_token/1)
    conn
  end

  # --- internal ---

  defp put_active_token(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
  end

  defp find_token_by_ref(stack, ref) do
    Enum.find(stack, fn token ->
      match?(%{uuid: ^ref}, Auth.get_session_token_record(token))
    end)
  end

  defp root_user(session) do
    case stack_tokens(session) do
      [root_token | _] -> Auth.get_user_by_session_token(root_token)
      _ -> nil
    end
  end

  defp log_event(action, %Auth.User{} = actor, %Auth.User{} = target) do
    PhoenixKit.Activity.log(%{
      action: action,
      module: "users",
      mode: "auto",
      actor_uuid: actor.uuid,
      resource_type: "user",
      resource_uuid: target.uuid,
      target_uuid: target.uuid,
      metadata: %{"email" => target.email, "actor_role" => "admin"}
    })
  rescue
    _ -> :ok
  end

  defp log_event(_action, _actor, _target), do: :ok
```

> Note: `Activity.log/1` is called directly (matching every other call site in `auth.ex`); the `rescue` keeps a logging failure from breaking a switch. `get_user_by_email_or_username_and_password/2` returns `{:error, :invalid_credentials}` / `{:error, :rate_limit_exceeded}`, which propagate to the caller unchanged.

- [ ] **Step 4: Run the integration test to verify it passes.**

Run: `mix test test/integration/users/multi_session_test.exs`
Expected: PASS (all describe blocks). If PostgreSQL is unavailable the suite is auto-excluded — run `mix test.setup` once first.

- [ ] **Step 5: Commit.**

```bash
git add lib/phoenix_kit_web/users/multi_session.ex test/integration/users/multi_session_test.exs
git commit -m "Add MultiSession add/switch/remove/logout ops with audit logging"
```

---

## Task 4: Routes

**Files:**
- Modify: `lib/phoenix_kit_web/integration.ex` (`generate_basic_scope/1` ~line 235; `generate_localized_routes/2` ~line 1067)

- [ ] **Step 1: Add routes to `generate_basic_scope/1`.** Directly after `get "/users/log-out", Users.Session, :get_logout` (line 235), add:

```elixir
post "/users/session/accounts", Users.Session, :add_account
put "/users/session/active", Users.Session, :set_active_account
delete "/users/session/accounts/:ref", Users.Session, :remove_account
```

- [ ] **Step 2: Add the same routes to `generate_localized_routes/2`.** Directly after `get "/users/log-out", Users.Session, :get_logout` (line 1067), add the identical three lines. (Both scopes are required — locale-prefixed form submissions hit the localized scope.)

> The logout query-param (`?all=1`) needs **no** route change — Phoenix passes query params to the existing `delete "/users/log-out"` action transparently.

- [ ] **Step 3: Verify routes compile and resolve.**

Run: `mix compile --warnings-as-errors`
Expected: compiles clean. (Controller actions are added in Task 5; until then routes reference yet-undefined actions but routing macros don't validate action existence at compile time — if your Phoenix version warns, do Task 5 before re-running.)

- [ ] **Step 4: Commit.**

```bash
git add lib/phoenix_kit_web/integration.ex
git commit -m "Add multi-session controller routes (basic + localized scopes)"
```

---

## Task 5: Session controller actions

**Files:**
- Modify: `lib/phoenix_kit_web/users/session.ex`
- Test: `test/integration/phoenix_kit_web/users/session_multi_test.exs`

- [ ] **Step 1: Write the failing controller test.** Create `test/integration/phoenix_kit_web/users/session_multi_test.exs`:

```elixir
defmodule PhoenixKitWeb.Users.SessionMultiTest do
  use PhoenixKitWeb.ConnCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.MultiSession

  defp unique_email, do: "smc_#{System.unique_integer([:positive])}@example.com"

  defp make(role) do
    {:ok, user} = Auth.register_user(%{email: unique_email(), password: "ValidPassword123!"})
    {:ok, user} = Auth.admin_confirm_user(user)
    if role, do: {:ok, _} = Roles.assign_role(user, role)
    PhoenixKit.Test.Repo.get!(Auth.User, user.uuid)
  end

  defp login(conn, user) do
    token = Auth.generate_user_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Phoenix.Controller.fetch_flash()
    |> Plug.Conn.put_session(:user_token, token)
    |> Plug.Conn.put_session(:live_socket_id, "phoenix_kit_sessions:#{Base.url_encode64(token)}")
    |> Plug.Conn.put_session(:pk_session_accounts, [token])
  end

  describe "add_account gate" do
    test "owner can add an account", %{conn: conn} do
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"},
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
      assert length(get_session(conn)["pk_session_accounts"]) == 2
    end

    test "plain user is forbidden", %{conn: conn} do
      user = make(nil)
      other = make(nil)
      conn = login(conn, user)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"}
        })

      assert conn.status == 403 or redirected_to(conn) =~ "/"
      assert length(get_session(conn)["pk_session_accounts"]) == 1
    end

    test "forbidden when setting is off", %{conn: conn} do
      Settings.update_boolean_setting("multi_session_enabled", false)
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)

      conn =
        post(conn, Routes.path("/users/session/accounts"), %{
          "user" => %{"email_or_username" => other.email, "password" => "ValidPassword123!"}
        })

      assert conn.status == 403 or redirected_to(conn) =~ "/"
      assert length(get_session(conn)["pk_session_accounts"]) == 1
    end
  end

  describe "switch / remove / logout" do
    setup %{conn: conn} do
      owner = make("Owner")
      other = make(nil)
      conn = login(conn, owner)
      {:ok, conn} = MultiSession.add_account(conn, other.email, "ValidPassword123!")
      %{conn: Phoenix.Controller.fetch_flash(conn), owner: owner, other: other}
    end

    test "set_active_account switches by ref", %{conn: conn, owner: owner} do
      [root | _] = MultiSession.list_accounts(get_session(conn))

      conn =
        put(conn, Routes.path("/users/session/active"), %{
          "ref" => root.ref,
          "return_to" => "/admin/dashboard"
        })

      assert redirected_to(conn) == "/admin/dashboard"
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "logout active falls back to root", %{conn: conn, owner: owner} do
      conn = delete(conn, Routes.path("/users/log-out"))
      assert redirected_to(conn) == "/"
      assert get_session(conn)["user_token"]
      assert Auth.get_user_by_session_token(get_session(conn)["user_token"]).uuid == owner.uuid
    end

    test "logout all clears the session", %{conn: conn} do
      tokens = get_session(conn)["pk_session_accounts"]
      conn = delete(conn, Routes.path("/users/log-out") <> "?all=1")
      assert redirected_to(conn) == "/"
      refute get_session(conn)["user_token"]
      assert Enum.all?(tokens, &is_nil(Auth.get_user_by_session_token(&1)))
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `mix test test/integration/phoenix_kit_web/users/session_multi_test.exs`
Expected: FAIL — actions `add_account` / `set_active_account` undefined (or route not found).

- [ ] **Step 3: Add the controller actions.** In `lib/phoenix_kit_web/users/session.ex`, add `alias PhoenixKitWeb.Users.MultiSession` to the module aliases (after `alias PhoenixKitWeb.Users.Auth, as: UserAuth`), then add these actions (place after `get_logout/2`) and **replace** the existing `delete/2`:

```elixir
def add_account(conn, %{"user" => %{"password" => password} = user_params} = params) do
  email_or_username = user_params["email_or_username"] || user_params["email"]

  with_gate(conn, params, fn conn ->
    case MultiSession.add_account(conn, email_or_username, password) do
      {:ok, conn} ->
        conn |> put_flash(:info, "Account added.") |> redirect_back(params)

      {:error, :stack_full} ->
        conn
        |> put_flash(:error, "Maximum number of accounts reached.")
        |> redirect_back(params)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Invalid email/username or password.")
        |> redirect_back(params)
    end
  end)
end

def set_active_account(conn, %{"ref" => ref} = params) do
  with_gate(conn, params, fn conn ->
    case MultiSession.switch_to(conn, ref) do
      {:ok, conn, user} ->
        conn |> put_flash(:info, "Switched to #{user.email}.") |> redirect_back(params)

      {:error, _reason} ->
        conn |> put_flash(:error, "Could not switch account.") |> redirect_back(params)
    end
  end)
end

def remove_account(conn, %{"ref" => ref} = params) do
  with_gate(conn, params, fn conn ->
    case MultiSession.remove_account(conn, ref) do
      {:ok, conn} ->
        conn |> put_flash(:info, "Account removed.") |> redirect_back(params)

      {:error, :cannot_remove_root} ->
        conn
        |> put_flash(:error, "Cannot remove your primary account.")
        |> redirect_back(params)

      {:error, _reason} ->
        conn |> put_flash(:error, "Could not remove account.") |> redirect_back(params)
    end
  end)
end

# Logout: "all" drains the whole stack; otherwise log out the active account only
# (falling back to root) unless root is active, in which case full logout runs.
def delete(conn, %{"all" => _} = _params) do
  conn
  |> MultiSession.delete_all_stack_tokens()
  |> put_flash(:info, "Logged out of all accounts.")
  |> UserAuth.log_out_user()
end

def delete(conn, _params) do
  case MultiSession.log_out_active(conn) do
    {:switched, conn, user} ->
      conn
      |> put_flash(:info, "Logged out. Now signed in as #{user.email}.")
      |> redirect(to: Routes.path("/"))

    {:full, conn} ->
      conn
      |> put_flash(:info, "Logged out successfully.")
      |> UserAuth.log_out_user()
  end
end

# --- multi-session helpers ---

defp with_gate(conn, _params, fun) do
  if MultiSession.gate_allowed?(get_session(conn)) do
    fun.(conn)
  else
    conn
    |> put_status(:forbidden)
    |> put_flash(:error, "Multi-account switching is not available.")
    |> redirect(to: Routes.path("/"))
  end
end

defp redirect_back(conn, params) do
  return_to = params["return_to"]

  if is_binary(return_to) and String.starts_with?(return_to, "/") and
       not String.starts_with?(return_to, "//") do
    redirect(conn, to: return_to)
  else
    redirect(conn, to: Routes.path("/"))
  end
end
```

> The existing `get_logout/2` keeps calling `UserAuth.log_out_user()` (full logout) — leave it unchanged; the dropdown only uses the DELETE forms.

- [ ] **Step 4: Run the controller test to verify it passes.**

Run: `mix test test/integration/phoenix_kit_web/users/session_multi_test.exs`
Expected: PASS. (The 403 assertion is written `or`-style because `with_gate` redirects after `put_status(:forbidden)`; redirect wins the status — both forms are accepted.)

- [ ] **Step 5: Commit.**

```bash
git add lib/phoenix_kit_web/users/session.ex test/integration/phoenix_kit_web/users/session_multi_test.exs
git commit -m "Add multi-session controller actions and active/all logout split"
```

---

## Task 6: Assign accounts + gate on the plug and on_mount paths

**Files:**
- Modify: `lib/phoenix_kit_web/users/auth.ex` (`fetch_phoenix_kit_current_scope/2` ~line 286; `mount_phoenix_kit_current_scope/2` used by `:phoenix_kit_mount_current_scope`)

- [ ] **Step 1: Assign in the plug.** In `fetch_phoenix_kit_current_scope/2`, after it assigns `:phoenix_kit_current_scope`, also assign the account list + gate from the conn session:

```elixir
conn
|> assign(:phoenix_kit_session_accounts, PhoenixKitWeb.Users.MultiSession.list_accounts(get_session(conn)))
|> assign(:phoenix_kit_multi_session_allowed?, PhoenixKitWeb.Users.MultiSession.gate_allowed?(get_session(conn)))
```

(Add these two `assign/3` calls onto the existing pipe that returns the conn — do not introduce a second return value.)

- [ ] **Step 2: Assign in the on_mount.** In the function backing `:phoenix_kit_mount_current_scope` (`mount_phoenix_kit_current_scope/2`), after `:phoenix_kit_current_scope` is assigned, add (using the `session` map argument, which is string-keyed):

```elixir
socket
|> Phoenix.Component.assign(:phoenix_kit_session_accounts, PhoenixKitWeb.Users.MultiSession.list_accounts(session))
|> Phoenix.Component.assign(:phoenix_kit_multi_session_allowed?, PhoenixKitWeb.Users.MultiSession.gate_allowed?(session))
```

> Use `assign` (not `assign_new`) so the list refreshes after a switch/add navigation. The N≤5 token lookups run only here, once per mount, only for sessions that reach this scope.

- [ ] **Step 3: Verify compile.**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git add lib/phoenix_kit_web/users/auth.ex
git commit -m "Assign session accounts + multi-session gate in plug and on_mount"
```

---

## Task 7: Header dropdown switcher UI + add-account modal

**Files:**
- Modify: `lib/phoenix_kit_web/components/admin_nav.ex` (`admin_user_dropdown/1`, attrs ~line 182, menu body ~line 201)
- Modify: `lib/phoenix_kit_web/components/layout_wrapper.ex` (call site of `admin_user_dropdown`, ~line 320)

- [ ] **Step 1: Add attrs.** In `admin_nav.ex`, alongside the existing `admin_user_dropdown/1` attrs (`scope`, `current_path`, `current_locale`), add:

```elixir
attr(:accounts, :list, default: [])
attr(:multi_session_allowed?, :boolean, default: false)
```

- [ ] **Step 2: Render the switcher section.** In the dropdown `<ul>`, immediately **before** the `<div class="divider my-0"></div>` that precedes the Log Out `<li>`, insert the switcher block. It uses pure HTML `<.form>` posts (no LiveView events) and a daisyUI checkbox-toggle modal (pure CSS — works inside this stateless component):

```heex
<%= if @multi_session_allowed? do %>
  <div class="divider my-0"></div>

  <li class="menu-title px-4 py-1">
    <span class="text-xs">{gettext("Accounts")}</span>
  </li>

  <%= for account <- @accounts do %>
    <li class="p-0">
      <%= if account.active? do %>
        <div class="flex items-center gap-3 px-4 py-2 rounded-lg bg-base-200">
          <span class="truncate">{account.email}</span>
          <span class="badge badge-xs badge-ghost">{account.role}</span>
          <PhoenixKitWeb.Components.Core.Icons.icon_check class="w-4 h-4 ml-auto" />
        </div>
      <% else %>
        <div class="flex items-center gap-2 px-1">
          <.form
            for={%{}}
            action={Routes.locale_aware_path(assigns, "/users/session/active")}
            method="put"
            class="flex-1"
          >
            <input type="hidden" name="ref" value={account.ref} />
            <input type="hidden" name="return_to" value={@current_path} />
            <button type="submit" class="flex w-full items-center gap-3 px-3 py-2 rounded-lg hover:bg-base-200">
              <span class="truncate">{account.email}</span>
              <span class="badge badge-xs badge-ghost ml-auto">{account.role}</span>
            </button>
          </.form>
          <%= unless account.root? do %>
            <.form
              for={%{}}
              action={Routes.locale_aware_path(assigns, "/users/session/accounts/#{account.ref}")}
              method="delete"
            >
              <input type="hidden" name="return_to" value={@current_path} />
              <button type="submit" class="btn btn-ghost btn-xs btn-square text-error" title={gettext("Remove")}>
                ✕
              </button>
            </.form>
          <% end %>
        </div>
      <% end %>
    </li>
  <% end %>

  <li class="p-0">
    <label for="pk-add-account-modal" class="flex items-center gap-3 px-4 py-2 rounded-lg hover:bg-base-200 cursor-pointer">
      <PhoenixKitWeb.Components.Core.Icons.icon_settings class="w-4 h-4" />
      <span>{gettext("Add account")}</span>
    </label>
  </li>
<% end %>
```

- [ ] **Step 3: Render the add-account modal** as a sibling of the dropdown `<div class="dropdown dropdown-end">` (a `<dialog>`/modal must not be nested inside the menu). Place it just before the closing of the authenticated branch — after the dropdown `</div>` and before `<% else %>`:

```heex
<%= if @multi_session_allowed? do %>
  <input type="checkbox" id="pk-add-account-modal" class="modal-toggle" />
  <div class="modal" role="dialog">
    <div class="modal-box">
      <h3 class="text-lg font-bold mb-4">{gettext("Add account")}</h3>
      <.form
        for={%{}}
        action={Routes.locale_aware_path(assigns, "/users/session/accounts")}
        method="post"
        class="space-y-4"
      >
        <input type="hidden" name="return_to" value={@current_path} />
        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Email or username")}</span></label>
          <input name="user[email_or_username]" type="text" required class="input input-bordered w-full" />
        </div>
        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Password")}</span></label>
          <input name="user[password]" type="password" required class="input input-bordered w-full" />
        </div>
        <div class="modal-action">
          <label for="pk-add-account-modal" class="btn btn-outline">{gettext("Cancel")}</label>
          <button type="submit" class="btn btn-primary">{gettext("Add account")}</button>
        </div>
      </.form>
    </div>
    <label class="modal-backdrop" for="pk-add-account-modal">{gettext("Close")}</label>
  </div>
<% end %>
```

> The daisyUI checkbox-toggle modal opens/closes purely via the `<label for="pk-add-account-modal">` controls — no LiveView state, which is required because `admin_user_dropdown/1` is a stateless function component rendered by the layout on every admin page. `<.form method="post"/"put"/"delete">` auto-injects the CSRF token and (for put/delete) the `_method` hidden field. Submitting reloads the page through the controller, so flash set by the action is shown by the layout's `<.flash_group>`.

- [ ] **Step 4: Thread the assigns at the call site.** In `layout_wrapper.ex`, update the `<.admin_user_dropdown ...>` call to pass the two new assigns:

```heex
<.admin_user_dropdown
  scope={@phoenix_kit_current_scope}
  current_path={@current_path}
  current_locale={@current_locale}
  accounts={assigns[:phoenix_kit_session_accounts] || []}
  multi_session_allowed?={assigns[:phoenix_kit_multi_session_allowed?] || false}
/>
```

Confirm `layout_wrapper.ex` forwards `phoenix_kit_session_accounts` / `phoenix_kit_multi_session_allowed?` into its template assigns the same way it forwards `phoenix_kit_current_scope` (around the assign-collection at lines 244-245). Add them to that map if the template can't see them.

- [ ] **Step 5: Compile and smoke-test rendering.**

Run: `mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 6: Commit.**

```bash
git add lib/phoenix_kit_web/components/admin_nav.ex lib/phoenix_kit_web/components/layout_wrapper.ex
git commit -m "Add account switcher + add-account modal to header dropdown"
```

---

## Task 8: Full-suite verification, CHANGELOG, quality gate

**Files:**
- Modify: `CHANGELOG.md`, `mix.exs` (`@version` bump per project convention)

- [ ] **Step 1: Run the whole suite.**

Run: `mix test`
Expected: all pass (integration tests require PostgreSQL; run `mix test.setup` first if needed).

- [ ] **Step 2: Run the quality gate.**

Run: `mix format && mix precommit`
Expected: format clean, compile clean (warnings-as-errors), `credo --strict` clean.

- [ ] **Step 3: Bump version + CHANGELOG.** Get current version with:

```bash
mix run --eval "IO.puts Mix.Project.config[:version]"
```

Bump the patch in `mix.exs` `@version` and add a CHANGELOG entry under the new heading, matching existing style:

```markdown
### Added
- Multi-session account switcher: Owner/Admin can add other accounts (with password)
  and switch between them from the header user menu, gated by the new
  `multi_session_enabled` setting (default on). Stack of session tokens lives in one
  cookie; active token stays in `:user_token`. Switches/adds are audited via
  `session.switched` / `session.account_added` activity events.
```

- [ ] **Step 4: Commit.**

```bash
git add CHANGELOG.md mix.exs
git commit -m "Update CHANGELOG and version for multi-session switcher"
```

---

## Self-Review Notes (coverage against spec)

- **Real multi-account / token stack** → Tasks 2-3 (`pk_session_accounts`, `put_active_token`).
- **Controller-only mutation** → Tasks 4-5 (routes + actions; `<.form>` posts in Task 7).
- **Gate (root Owner/Admin + setting)** → `gate_allowed?/1` (Task 2), enforced in `with_gate` (Task 5) and UI visibility (Tasks 6-7).
- **Switcher visible while non-root active** → gate evaluated against `hd(stack)` (root), not active.
- **Logout active + Log out all** → split `delete/2` (Task 5), two controls in dropdown (Task 7).
- **Audit** → `log_event/3` for `session.account_added` / `session.switched` (Task 3).
- **Kill switch + UI toggle** → Task 1.
- **Tests:** unit (Task 2), integration ops (Task 3), controller gate/flows (Task 5), full suite (Task 8).
- **`token_ref` opaque** → `UserToken.uuid`, raw token never in markup (`find_token_by_ref/2`, Task 3; hidden `ref` inputs, Task 7).
- **Out of scope (unbuilt):** impersonation, remember-me persistence of the stack, per-role configurability, cross-device sync.
