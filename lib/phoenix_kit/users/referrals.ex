defmodule PhoenixKit.Users.Referrals do
  @moduledoc """
  Core-side runtime bridge to the optional `phoenix_kit_referrals` package.

  The referral-codes feature lives in the standalone `phoenix_kit_referrals`
  module. Core has **no compile-time dependency** on it — this facade resolves
  the installed module at runtime by its `PhoenixKit.Module` key (`"referrals"`)
  via `PhoenixKit.ModuleRegistry` and dispatches through it.

  When the package isn't installed (or doesn't export a given function) every
  call degrades safely: the system reads as disabled, lookups return `nil`, and
  `use_code/2` is a no-op. That lets the registration / OAuth / magic-link flows
  treat referrals as optional — with the module absent, the referral field never
  appears and nothing is recorded.

  The function surface here mirrors exactly what the signup flows call, so those
  call sites only had to swap their alias to this module.
  """

  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Users.RateLimiter

  @key "referrals"

  # Shape core reads from `get_config/0` when no module is installed.
  @disabled_config %{enabled: false, required: false}

  # One message for every rejection. Distinct strings ("Invalid" vs "expired" vs
  # "usage limit") told an attacker whether a guessed code EXISTS, turning the
  # form into an enumeration oracle: existence and format confirmed for free.
  # Operators still get the real reason via `Logger.debug`.
  @rejection_message "That code can't be used"

  @doc """
  Referral-codes configuration map. Disabled defaults when the module is absent.
  """
  def get_config do
    case dispatch(:get_config, []) do
      {:ok, config} -> config
      :error -> @disabled_config
    end
  end

  @doc "Whether a referrals module is installed and enabled."
  def enabled? do
    get_config()[:enabled] == true
  end

  @doc "Look up a referral code struct by its string, or `nil`."
  def get_code_by_string(code_string) do
    case dispatch(:get_code_by_string, [code_string]) do
      {:ok, code} -> code
      :error -> nil
    end
  end

  @doc "Whether the given code is expired (`false` when the module is absent)."
  def expired?(code) do
    case dispatch(:expired?, [code]) do
      {:ok, result} -> result
      :error -> false
    end
  end

  @doc "Whether the given code hit its usage limit (`false` when absent)."
  def usage_limit_reached?(code) do
    case dispatch(:usage_limit_reached?, [code]) do
      {:ok, result} -> result
      :error -> false
    end
  end

  @doc """
  Record a use of `code_string` by `user_uuid`.

  No-op returning `{:error, :referrals_not_installed}` when the module is absent.
  """
  def use_code(code_string, user_uuid) do
    case dispatch(:use_code, [code_string, user_uuid]) do
      {:ok, result} -> result
      :error -> {:error, :referrals_not_installed}
    end
  end

  @doc """
  Validates a referral code for a signup attempt.

  Shared by every signup surface so the rules cannot drift apart — the password
  and magic-link forms previously carried byte-identical private copies.

  ## Options

  - `:enabled?` / `:required?` — from `get_config/0` (required)
  - `:context` — `:change` while the user types, `:submit` on the final attempt
  - `:ip_address` — used to rate-limit code checking; omit and no limit applies

  ## Why `:context` matters

  On `:change`, a **blank** required code is not an error. Validation runs on
  every keystroke anywhere in the form, so treating blank-and-required as invalid
  made "Referral code is required" appear while the user was still typing their
  email — before they had reached the field. A code that has actually been
  *typed* is still checked on change, because that field has been touched.
  `:submit` enforces presence.

  ## Why rejections are indistinguishable

  Every failure returns the same message. Separate strings for
  missing / inactive / expired / limit-reached confirmed which guesses named a
  real code. The specific reason is logged at debug level for operators.

  Returns `{:ok, code_or_nil}` or `{:error, message}`.
  """
  def validate_for_signup(code, opts) do
    enabled? = Keyword.fetch!(opts, :enabled?)
    required? = Keyword.fetch!(opts, :required?)
    context = Keyword.get(opts, :context, :submit)
    trimmed = code |> to_string() |> String.trim()

    cond do
      not enabled? ->
        {:ok, nil}

      trimmed == "" and required? and context == :submit ->
        {:error, "Referral code is required"}

      trimmed == "" ->
        # Blank and either optional, or still being filled in.
        {:ok, nil}

      true ->
        validate_typed_code(trimmed, Keyword.get(opts, :ip_address))
    end
  end

  defp validate_typed_code(code_string, ip_address) do
    case rate_limit_check(ip_address) do
      :ok -> check_code(code_string)
      {:error, :rate_limit_exceeded} -> {:error, "Too many attempts. Please try again shortly."}
    end
  end

  defp rate_limit_check(ip) when is_binary(ip),
    do: RateLimiter.check_referral_validation_rate_limit(ip)

  defp rate_limit_check(_), do: :ok

  defp check_code(code_string) do
    case get_code_by_string(code_string) do
      nil ->
        reject(code_string, "no such code")

      code ->
        cond do
          not code.status -> reject(code_string, "code is inactive")
          expired?(code) -> reject(code_string, "code has expired")
          usage_limit_reached?(code) -> reject(code_string, "code hit its usage limit")
          true -> {:ok, code}
        end
    end
  end

  defp reject(code_string, reason) do
    require Logger
    Logger.debug("[Referrals] rejected #{inspect(code_string)}: #{reason}")
    {:error, @rejection_message}
  end

  # Resolve the installed referrals module by key and call it. Returns
  # `{:ok, result}` or `:error` when nothing handles it. `apply/3` keeps the
  # target out of compile-time xref, so core needs no dependency on the package.
  defp dispatch(fun, args) do
    with mod when not is_nil(mod) <- ModuleRegistry.get_by_key(@key),
         true <- function_exported?(mod, fun, length(args)) do
      {:ok, apply(mod, fun, args)}
    else
      _ -> :error
    end
  end
end
