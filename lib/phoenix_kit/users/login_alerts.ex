defmodule PhoenixKit.Users.LoginAlerts do
  @moduledoc """
  New-login security alerts ("we noticed a new login to your account").

  On every login (`PhoenixKitWeb.Users.Auth.log_in_user/3`), the request's
  `(ip_address, user_agent_hash)` pair is checked against
  `PhoenixKit.Users.Auth.KnownDevice` rows for that user. An unrecognized
  pair is a new device: it's persisted and a `user.new_login_detected`
  activity entry is logged either way — but the email
  (`PhoenixKit.Users.Auth.UserNotifier.deliver_new_login_alert/2`, gated
  behind `new_login_alert_enabled`) and the in-app notification are skipped
  when this is the very first `KnownDevice` row the account has ever had.

  That first-device skip exists because registration ends by logging the new
  user in through this exact path (`log_in_user/3`), and an account with no
  device history yet cannot help but treat its own signup as "a new device" —
  without it, every signup on an installation with alerts on immediately
  received a "we noticed a new login" security email about the login it just
  performed to finish registering. The device is still recorded (so the
  *second* login, from anywhere else, correctly reads as new), and the
  activity entry still logs for the audit trail — only the two
  reader-facing alarms are suppressed.

  A recognized pair just bumps `last_seen_at` — no alert, no email.

  Sends synchronously (matching every other PhoenixKit auth email —
  confirmation, password reset, magic link — none of which are queued
  through Oban): a "new device" login is inherently rare per user (every
  subsequent login from the same device is silent), so the odd extra
  round-trip on a first-time login doesn't justify background-job
  infrastructure this feature would otherwise be the only user of. A
  send failure is logged and swallowed — it must never block sign-in.
  """

  import Ecto.Query

  require Logger

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Notifications
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.KnownDevice
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Utils.Geolocation
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.SessionFingerprint
  alias PhoenixKit.Utils.UserAgent

  @doc """
  Whether new-login alerts are enabled (setting `new_login_alert_enabled`,
  default `false`).
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get_boolean_setting("new_login_alert_enabled", false)

  @doc """
  Records a login from `conn` for `user`, alerting on a new device.

  No-ops entirely (no DB write, no email) when the feature is disabled.
  Never raises — a failure here must never block sign-in.
  """
  @spec check(map(), Plug.Conn.t()) :: :ok
  def check(user, conn) do
    if enabled?(), do: do_check(user, conn)
    :ok
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] check failed: #{inspect(error)}")
      :ok
  end

  defp do_check(user, conn) do
    fingerprint = SessionFingerprint.create_fingerprint(conn)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    repo = RepoHelper.repo()

    case repo.get_by(KnownDevice,
           user_uuid: user.uuid,
           ip_address: fingerprint.ip_address,
           user_agent_hash: fingerprint.user_agent_hash
         ) do
      nil ->
        # Checked BEFORE inserting the row below — once it's inserted this
        # account always has at least one device on file, and every future
        # first-time check would wrongly read as "first device ever" too.
        first_device? = not repo.exists?(from(d in KnownDevice, where: d.user_uuid == ^user.uuid))
        record_new_device(user, conn, fingerprint, now, first_device?)

      %KnownDevice{} = device ->
        device |> KnownDevice.changeset(%{last_seen_at: now}) |> repo.update()
        :ok
    end
  end

  defp record_new_device(user, conn, fingerprint, now, first_device?) do
    repo = RepoHelper.repo()
    ua = user_agent_header(conn)

    attrs = %{
      user_uuid: user.uuid,
      ip_address: fingerprint.ip_address,
      user_agent_hash: fingerprint.user_agent_hash,
      browser: UserAgent.browser(ua),
      os: UserAgent.os(ua),
      # Resolved once here and persisted (V147) so the Active Sessions list
      # can show it later without re-hitting the geo API per page render.
      location: location_for(fingerprint.ip_address),
      first_seen_at: now,
      last_seen_at: now
    }

    %KnownDevice{}
    |> KnownDevice.changeset(attrs)
    |> repo.insert(
      on_conflict: [set: [last_seen_at: now]],
      conflict_target: [:user_uuid, :ip_address, :user_agent_hash]
    )

    log_new_login(user, attrs, first_device?)

    # The account's first-ever login (registration's own auto-login) is not a
    # security event to alarm the reader with — skip only the two
    # reader-facing alarms; the device row and activity entry above still
    # record it, so the actual second device correctly reads as new.
    unless first_device? do
      notify_in_app(user, attrs)
      UserNotifier.deliver_new_login_alert(user, attrs)
    end

    :ok
  end

  # In-app notification for the new sign-in. The `user.new_login_detected`
  # activity is self-actor (actor == target), so the activity→notification
  # hook correctly skips it — this is the sanctioned standalone path for an
  # app-driven self-notice, filtered through the recipient's "security"
  # type preference (fail-open). Links to the Active Sessions section.
  defp notify_in_app(user, attrs) do
    if Code.ensure_loaded?(Notifications) do
      Notifications.create(%{
        recipient_uuid: user.uuid,
        type: "security",
        icon: "hero-shield-exclamation",
        link: Routes.user_settings_path(),
        text: new_login_text(attrs)
      })
    end
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] in-app notify failed: #{inspect(error)}")
      :ok
  end

  defp new_login_text(attrs) do
    details =
      [attrs.browser, attrs.os, attrs.location]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join(", ")

    case details do
      "" -> gettext("New sign-in to your account.")
      _ -> gettext("New sign-in to your account from %{details}.", details: details)
    end
  end

  defp log_new_login(user, attrs, first_device?) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: "user.new_login_detected",
        module: "users",
        mode: "auto",
        actor_uuid: user.uuid,
        target_uuid: user.uuid,
        resource_type: "user",
        resource_uuid: user.uuid,
        metadata: %{
          "actor_role" => "user",
          "ip_address" => attrs.ip_address,
          "browser" => attrs.browser,
          "os" => attrs.os,
          "first_device" => first_device?
        }
      })
    end
  rescue
    error ->
      Logger.warning("[PhoenixKit.LoginAlerts] activity log failed: #{inspect(error)}")
  end

  defp user_agent_header(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      [] -> nil
    end
  end

  @doc """
  Best-effort "City, Country" string for `ip_address`, or `nil`.

  Never raises; a lookup failure (disabled, rate-limited, invalid IP)
  just means the alert email omits the location line.
  """
  @spec location_for(String.t()) :: String.t() | nil
  def location_for(ip_address) do
    case Geolocation.lookup_location(ip_address) do
      {:ok, %{"city" => city, "country" => country}}
      when is_binary(city) and city != "" and is_binary(country) and country != "" ->
        "#{city}, #{country}"

      {:ok, %{"country" => country}} when is_binary(country) and country != "" ->
        country

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
