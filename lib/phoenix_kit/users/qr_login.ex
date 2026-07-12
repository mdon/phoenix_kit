defmodule PhoenixKit.Users.QrLogin do
  @moduledoc """
  QR device-handoff login ("scan to sign in") for PhoenixKit.

  This is the PhoenixKit-side integration of the [`keyfob`](https://hex.pm/packages/keyfob)
  library. Keyfob owns the rendezvous — request lifecycle, expiry,
  single-use enforcement, the secret split, PubSub signaling. This module
  wires it into PhoenixKit: the internal PubSub, the `qr_login_enabled`
  setting, device-metadata extraction for the confirm screen, and activity
  logging on approval.

  ## The flow

  1. A signed-out browser opens `/users/qr-login`
     (`PhoenixKitWeb.Users.QrLogin`) and a QR encoding the phone-confirm URL
     is shown. The LiveView waits.
  2. The user's already-signed-in phone scans it, opens the confirm URL
     (`PhoenixKitWeb.Users.QrLoginConfirm`), reviews the requesting device,
     and taps Approve — which calls `approve/2` with the phone user's uuid.
  3. Approval mints a one-time login token delivered over PubSub only to
     the waiting browser, which navigates to the completion controller
     (`PhoenixKitWeb.Users.QrLoginComplete`).
  4. The controller calls `consume/1` (`{:ok, user_uuid}`, exactly once) and
     logs that user in with PhoenixKit's own session machinery.

  Approval always happens on the trusted (phone) device; the browser gets
  nothing until the phone approves. See `keyfob`'s docs for the threat
  model (QR-jacking, the secret split).

  All keyfob calls are routed through PhoenixKit's internal PubSub
  (`#{inspect(:phoenix_kit_internal_pubsub)}`) so the desktop LiveView and
  the phone confirm LiveView rendezvous on the same bus. The default
  `Keyfob.Store.ETS` (started in `PhoenixKit.Supervisor`) holds requests.
  """

  require Logger

  alias Phoenix.LiveView
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.IpAddress

  # PhoenixKit's internal PubSub, started by `PhoenixKit.PubSub.Manager`.
  @pubsub :phoenix_kit_internal_pubsub

  @doc """
  Whether QR device-handoff login is enabled (setting `qr_login_enabled`,
  default `false`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("qr_login_enabled", false)

  @doc "The PubSub name every keyfob call in this integration uses."
  @spec pubsub() :: atom()
  def pubsub, do: @pubsub

  @doc "Shared keyfob options — routes every call through PhoenixKit's internal PubSub."
  @spec keyfob_opts() :: keyword()
  def keyfob_opts, do: [pubsub: @pubsub]

  ## ── Thin keyfob wrappers (so call sites never repeat the opts) ─────────

  @doc "See `Keyfob.create_request/1`. Merges the shared PubSub option."
  def create_request(opts \\ []), do: Keyfob.create_request(Keyword.merge(keyfob_opts(), opts))

  @doc "See `Keyfob.peek/2`."
  def peek(token), do: Keyfob.peek(token, keyfob_opts())

  @doc "See `Keyfob.approve/3`. `user_ref` is the approving user's uuid."
  def approve(token, user_ref), do: Keyfob.approve(token, user_ref, keyfob_opts())

  @doc "See `Keyfob.deny/2`."
  def deny(token), do: Keyfob.deny(token, keyfob_opts())

  @doc "See `Keyfob.consume/2`. Returns `{:ok, user_uuid}` exactly once."
  def consume(token), do: Keyfob.consume(token, keyfob_opts())

  @doc "See `Keyfob.subscribe/2`."
  def subscribe(token), do: Keyfob.subscribe(token, keyfob_opts())

  @doc "See `Keyfob.unsubscribe/2`."
  def unsubscribe(token), do: Keyfob.unsubscribe(token, keyfob_opts())

  ## ── Device metadata for the confirm screen ────────────────────────────

  @doc """
  Extracts a device-description map from the requesting browser's connected
  socket, shown verbatim on the phone confirm screen so the human can
  recognise (or reject) the sign-in.

  Keys: `:browser`, `:os`, `:ip` — any of which may be absent when the
  underlying connect-info is unavailable.
  """
  @spec device_meta(LiveView.Socket.t()) :: map()
  def device_meta(socket) do
    ua = LiveView.get_connect_info(socket, :user_agent)
    ip = IpAddress.extract_from_socket(socket)

    %{}
    |> put_present(:browser, browser_from_ua(ua))
    |> put_present(:os, os_from_ua(ua))
    |> put_present(:ip, ip)
  end

  ## ── Activity logging ───────────────────────────────────────────────────

  @doc """
  Records a `user.qr_login_approved` activity for the approving user.

  Actor and target are the same user (they approved their own sign-in), so
  no notification is generated — this is an audit-trail entry only. Errors
  are swallowed: a logging failure must never block the sign-in.
  """
  @spec log_approval(map(), map()) :: :ok
  def log_approval(user, meta \\ %{}) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      try do
        PhoenixKit.Activity.log(%{
          action: "user.qr_login_approved",
          module: "users",
          mode: "manual",
          actor_uuid: user.uuid,
          target_uuid: user.uuid,
          resource_type: "user",
          resource_uuid: user.uuid,
          metadata: %{"actor_role" => "user", "device" => meta}
        })
      rescue
        error ->
          Logger.warning("[PhoenixKit.QrLogin] activity log failed: #{inspect(error)}")
      end
    end

    :ok
  end

  ## ── Internals ──────────────────────────────────────────────────────────

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # Deliberately small, allocation-light UA sniffing — enough to make the
  # confirm screen recognisable ("Chrome on macOS"), not a UA-parsing lib.
  defp browser_from_ua(nil), do: nil

  defp browser_from_ua(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Edg/") -> "Edge"
      String.contains?(ua, "OPR/") or String.contains?(ua, "Opera") -> "Opera"
      String.contains?(ua, "Firefox") -> "Firefox"
      String.contains?(ua, "Chrome") -> "Chrome"
      String.contains?(ua, "Safari") -> "Safari"
      true -> nil
    end
  end

  defp os_from_ua(nil), do: nil

  defp os_from_ua(ua) when is_binary(ua) do
    cond do
      String.contains?(ua, "Windows") -> "Windows"
      String.contains?(ua, "iPhone") or String.contains?(ua, "iPad") -> "iOS"
      String.contains?(ua, "Mac OS X") or String.contains?(ua, "Macintosh") -> "macOS"
      String.contains?(ua, "Android") -> "Android"
      String.contains?(ua, "Linux") -> "Linux"
      true -> nil
    end
  end
end
