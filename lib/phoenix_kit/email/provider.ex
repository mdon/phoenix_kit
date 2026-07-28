defmodule PhoenixKit.Email.Provider do
  @moduledoc """
  Unified email provider behaviour.

  Covers interception (pre/post send hooks), DB templates, AWS config,
  and provider detection. The emails package implements this fully.
  The DefaultProvider is a no-op that passes emails through unchanged.
  """

  # Interception
  @callback intercept_before_send(Swoosh.Email.t(), keyword()) :: Swoosh.Email.t()
  @callback handle_after_send(Swoosh.Email.t(), {:ok, any()} | {:error, any()}) :: :ok

  @doc """
  Offers the provider the chance to take delivery over — i.e. queue the message
  instead of sending it on this process.

  Called by `PhoenixKit.Mailer` right after `intercept_before_send/2`, on both
  the integration and the static-mailer path, so a queue covers *every* outgoing
  message and not just the ones a caller routed through the package. Returning
  `{:queued, ref}` means "accepted, do not send now" and `ref` is echoed back to
  the caller as `{:ok, %{id: ref, queued: true}}`; `:continue` means send
  normally.

  Optional: it is skipped when the provider does not export it, so a package
  built against an older core still satisfies this behaviour.

  > #### The worker's re-send is intercepted again {: .warning}
  >
  > `skip_queue: true` skips only *this* callback, not `intercept_before_send/2`
  > — the interceptor still runs on the way back out, so a queued message passes
  > through it twice: once when it was accepted here, once when the worker
  > delivers it. A provider that creates a tracking row per interception has to
  > recognise its own message (its tracking header is already on the email by
  > then) or it will log the same send twice.
  """
  @callback maybe_enqueue(Swoosh.Email.t(), keyword()) :: :continue | {:queued, term()}

  @optional_callbacks maybe_enqueue: 2

  # Templates
  @callback get_active_template_by_name(String.t()) :: map() | nil
  @callback render_template(map(), map()) :: map()
  @callback render_template(map(), map(), String.t()) :: map()
  @callback track_usage(map()) :: :ok
  @callback get_source_module(map()) :: String.t() | nil

  # AWS config
  @callback get_aws_region() :: String.t()
  @callback get_aws_access_key() :: String.t()
  @callback get_aws_secret_key() :: String.t()
  @callback aws_configured?() :: boolean()

  # Provider detection
  @callback adapter_to_provider_name(atom(), String.t()) :: String.t()

  # Test email (only supported by emails package)
  @callback send_test_tracking_email(String.t(), String.t() | nil) ::
              {:ok, Swoosh.Email.t()} | {:error, any()}

  @doc "Returns the configured email provider module, defaulting to DefaultProvider."
  @spec current() :: module()
  def current do
    Application.get_env(:phoenix_kit, :email_provider, PhoenixKit.Email.DefaultProvider)
  end
end
