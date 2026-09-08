defmodule PhoenixKit.TestSupport.PostgresPreflight do
  @moduledoc """
  One bounded, classified PostgreSQL connection attempt, for use from a
  `test_helper.exs`.

  ## Why this exists

  Every package in this ecosystem defaults its test role to `postgres`
  (`System.get_env("PGUSER", "postgres")`). That default is right for CI and
  for Debian, and wrong for a Homebrew install, where `initdb` names the
  superuser after the OS user and no `postgres` role exists.

  The problem is not the default — it is what a wrong one looks like. These
  suites run through the Ecto SQL sandbox, so a rejected login does not
  surface as "authentication failed". `DBConnection` queues the checkout and
  retries with backoff, and the run dies minutes later on a **pool checkout
  timeout** that reads exactly like a flaky test. That disguise is the defect
  this module removes, and the only one it claims to.

  ## What a pass does and does not prove

  A pass means the endpoint was reachable, TLS and protocol negotiation
  succeeded, the credentials were accepted, and the target database could be
  selected. It is a **connection** preflight, not a "database is ready" check.
  It says nothing about whether the pool can open all its connections, whether
  migrations have run, whether the caller has table privileges, or whether
  sandbox ownership is configured correctly. Those already fail loudly and are
  deliberately out of scope — do not grow this into a second copy of the repo
  startup path.

  ## Usage

  `check/1` never converts a connection problem into a raise, because most
  suites here degrade to unit-only rather than fail when there is no database:

      case PhoenixKit.TestSupport.PostgresPreflight.check(MyApp.Test.Repo) do
        :ok ->
          start_repo_and_migrate()

        {:error, _reason, message} ->
          IO.puts(:stderr, message)
          ExUnit.configure(exclude: [:integration])
      end

  `check!/1` is for a suite that has no meaningful unit-only mode.

  > #### Not application code {: .warning}
  >
  > This ships in `lib/` because sibling packages depend on `phoenix_kit`
  > through Hex, where a `test/support` directory is unreachable. It follows
  > the precedent of `Ecto.Adapters.SQL.Sandbox`. Never call it from
  > application code.
  """

  # Only real connection settings reach Postgrex. Passing a repo's config
  # wholesale would carry `:pool` (the sandbox), ownership and queue timeouts
  # with it — which rebuilds the very pool whose checkout timeout is the
  # failure being diagnosed.
  @connection_keys [
    :hostname,
    :port,
    :database,
    :username,
    :password,
    :ssl,
    :ssl_opts,
    :socket,
    :socket_dir,
    :socket_options,
    :parameters,
    :endpoints,
    :types
  ]

  # Not caller-overridable.
  @forced [connect_timeout: 2_000, types: Postgrex.DefaultTypes]

  @type reason ::
          :auth_rejected
          | :database_not_found
          | :insufficient_privilege
          | :too_many_connections
          | :server_unavailable
          | :unreachable
          | :unknown

  @doc """
  Attempts one connection. Returns `:ok`, or `{:error, reason, message}` with
  a message safe to print — it names the effective host, port, database and
  username, and never the password.

  Accepts a repo module or a keyword list of repo config.
  """
  @spec check(module() | keyword()) :: :ok | {:error, reason(), String.t()}
  def check(repo_or_config) do
    opts = connection_opts(repo_or_config)

    case start_probe(opts) do
      :ok ->
        :ok

      # The probe itself could not run. Say nothing and let the suite proceed
      # exactly as it did before this module existed: a diagnostic that cannot
      # diagnose must never be the reason a test run stops.
      :probe_unavailable ->
        :ok

      {:error, error} ->
        {reason, detail} = classify(error)
        {:error, reason, message(opts, reason, detail)}
    end
  end

  @doc """
  `check/1`, but raises `RuntimeError` on failure. For a suite with no
  unit-only mode.
  """
  @spec check!(module() | keyword()) :: :ok
  def check!(repo_or_config) do
    case check(repo_or_config) do
      :ok -> :ok
      {:error, _reason, message} -> raise message
    end
  end

  # `Postgrex.Protocol.connect/1` rather than `Postgrex.start_link/1`, and the
  # reason is the whole point of this module.
  #
  # `start_link/1` returns `{:ok, pid}` even when the credentials are wrong —
  # `sync_connect: true` does not change that here — and the authentication
  # failure then happens inside the connection process. Measured against a
  # live server: a bad role, a missing database and a closed port ALL return
  # `{:ok, pid}`, and asking that connection for `SELECT 1` gets the generic
  # "connection not available ... dropped from queue after 4000ms", which is
  # precisely the misleading message this module exists to replace.
  # `Ecto.Adapters.Postgres.storage_status/1` is no better: a bad role gives
  # `{:error, {:error, %RuntimeError{message: "killed"}}}`.
  #
  # `Protocol.connect/1` is synchronous and returns the real classified error
  # (`28000` naming the missing role, `3D000` naming the database,
  # `:econnrefused`). It is undocumented, so every call is guarded and any
  # surprise degrades to "no opinion" rather than to a broken test run.
  defp start_probe(opts) do
    if protocol_probe_available?() do
      # No catch-all clause: dialyzer proves the two below cover the return
      # type, and a shape change in this undocumented function would raise a
      # CaseClauseError, which the rescue turns into :probe_unavailable — the
      # same outcome a catch-all would give.
      case Postgrex.Protocol.connect(opts) do
        {:ok, state} -> disconnect(state)
        {:error, error} -> {:error, error}
      end
    else
      :probe_unavailable
    end
  rescue
    # A shape change in the internal API, bad SSL options, malformed config.
    _ -> :probe_unavailable
  catch
    :exit, _ -> :probe_unavailable
  end

  defp protocol_probe_available? do
    Code.ensure_loaded?(Postgrex.Protocol) and
      function_exported?(Postgrex.Protocol, :connect, 1)
  end

  # `disconnect/2` takes an EXCEPTION, not `:normal` — it is the DBConnection
  # callback shape, where the first argument is the error that caused the
  # disconnect. Passing an atom happens to close the socket anyway, but it does
  # not type-check, so a real exception is used.
  defp disconnect(state) do
    if function_exported?(Postgrex.Protocol, :disconnect, 2) do
      Postgrex.Protocol.disconnect(
        DBConnection.ConnectionError.exception("preflight complete"),
        state
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  defp connection_opts(repo) when is_atom(repo), do: repo |> repo_config() |> connection_opts()

  defp connection_opts(config) when is_list(config) do
    config
    |> Keyword.take(@connection_keys)
    |> Keyword.merge(@forced)
  end

  defp repo_config(repo) do
    if Code.ensure_loaded?(repo) and function_exported?(repo, :config, 0) do
      repo.config()
    else
      []
    end
  end

  # Codes are read for their semantics, never mapped to a guess. In
  # particular: a nonexistent role and a wrong password are NOT reliably
  # distinguishable — depending on the pg_hba method, a missing role is
  # answered with the same 28P01 as a bad password — so both are reported as
  # "credentials rejected" and the server's own wording is passed through
  # when it happens to say more.
  defp classify(%Postgrex.Error{postgres: %{} = pg}) do
    code = Map.get(pg, :pg_code) || Map.get(pg, :code)
    detail = Map.get(pg, :message)

    reason =
      case to_string(code) do
        c
        when c in ["28P01", "28000", "invalid_password", "invalid_authorization_specification"] ->
          :auth_rejected

        c when c in ["3D000", "invalid_catalog_name"] ->
          :database_not_found

        c when c in ["42501", "insufficient_privilege"] ->
          :insufficient_privilege

        c when c in ["53300", "too_many_connections"] ->
          :too_many_connections

        c when c in ["57P03", "cannot_connect_now"] ->
          :server_unavailable

        "08" <> _ ->
          :unreachable

        _ ->
          :unknown
      end

    {reason, detail}
  end

  # Every DBConnection-level failure here is "nothing answered on that
  # endpoint" — econnrefused, nxdomain, ehostunreach, enoent on a socket path,
  # a connect timeout. The distinction between them is in the message, which
  # is passed through, and does not change the advice.
  defp classify(%DBConnection.ConnectionError{} = error) do
    {:unreachable, Exception.message(error)}
  end

  defp classify(error) when is_exception(error), do: {:unknown, Exception.message(error)}
  defp classify(other), do: {:unknown, inspect(other, limit: 5)}

  defp message(opts, reason, detail) do
    """
    #{header(reason)}

      host:     #{Keyword.get(opts, :hostname, "(socket)")}:#{Keyword.get(opts, :port, 5432)}
      database: #{Keyword.get(opts, :database, "(unset)")}
      username: #{Keyword.get(opts, :username, "(unset)")}

    #{advice(reason)}#{server_said(detail)}
    """
  end

  defp header(:auth_rejected), do: "PostgreSQL refused the credentials."
  defp header(:database_not_found), do: "The PostgreSQL database does not exist."
  defp header(:insufficient_privilege), do: "PostgreSQL refused access to that database."
  defp header(:too_many_connections), do: "PostgreSQL has no free connection slots."
  defp header(:server_unavailable), do: "PostgreSQL is not accepting connections yet."
  defp header(:unreachable), do: "No PostgreSQL server answered."
  defp header(:unknown), do: "Could not connect to PostgreSQL."

  defp advice(:auth_rejected) do
    """
    Set PGUSER / PGPASSWORD to a role this server accepts, or add a matching
    pg_hba.conf rule. A Homebrew install has no `postgres` role by default —
    its superuser is named after your OS user.
    """
  end

  defp advice(:database_not_found), do: "Run `mix test.setup` (or `createdb`) to create it.\n"
  defp advice(:insufficient_privilege), do: "Grant the role CONNECT on that database.\n"
  defp advice(:too_many_connections), do: "Lower PGPOOL, or raise the server's max_connections.\n"

  defp advice(:server_unavailable),
    do: "The server is starting up or recovering; retry shortly.\n"

  defp advice(:unreachable) do
    "Check PGHOST / PGPORT and that the server is running.\n"
  end

  defp advice(:unknown), do: ""

  defp server_said(nil), do: ""
  defp server_said(""), do: ""
  defp server_said(detail), do: "\nPostgreSQL said: #{detail}\n"
end
