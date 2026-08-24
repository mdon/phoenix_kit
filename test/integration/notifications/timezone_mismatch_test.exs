defmodule PhoenixKit.Integration.Notifications.TimezoneMismatchTest do
  @moduledoc """
  Proves the whole chain: a browser reporting a zone the account does not use
  ends as a notification the person can actually see.

  The chain has several places to fail silently — the self-action skip in
  `maybe_create_from_activity/1`, the per-type mute preference, the
  once-per-zone guard — so this exercises it end to end rather than asserting
  that `observe/2` returned `:ok`.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Notifications
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.TimeZoneAlert
  alias PhoenixKit.Utils.Routes

  defp create_user(timezone) do
    {:ok, user} =
      Auth.register_user(%{
        email: "tz_alert_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, user} = Auth.update_user_profile(user, %{"user_timezone" => timezone})
    user
  end

  defp notifications(user) do
    {rows, _} = Notifications.list_for_user(user.uuid)
    rows
  end

  describe "a genuine mismatch" do
    test "notifies the user, naming where they appear to be" do
      user = create_user("Europe/Warsaw")

      :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")

      assert [notification] = notifications(user)
      assert notification.activity.action == "user.timezone_mismatch"
      assert notification.activity.metadata["detected_timezone"] == "Asia/Tokyo"
      assert notification.activity.metadata["saved_timezone"] == "Europe/Warsaw"
    end

    test "the rendered text tells them what is wrong, not just that something is" do
      user = create_user("Europe/Warsaw")
      :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")

      [notification] = notifications(user)
      view = Notifications.Render.render(notification, "en")

      assert view.text =~ "Asia/Tokyo"
      assert view.icon == "hero-globe-alt"
      # Lands on the page where it can be fixed.
      assert view.link == Routes.user_settings_path(locale: "en")
    end

    test "an account still on a legacy offset is told, even when it is right today" do
      # "+2" happens to match Warsaw in August, but it cannot follow the next
      # daylight-saving change — which is the whole reason to replace it.
      user = create_user("2")

      :ok = TimeZoneAlert.observe(user, "Europe/Warsaw")

      assert [notification] = notifications(user)
      assert notification.activity.action == "user.timezone_mismatch"
    end
  end

  describe "when it must stay quiet" do
    test "zones that never disagree are not a mismatch" do
      user = create_user("Europe/Helsinki")

      :ok = TimeZoneAlert.observe(user, "Europe/Tallinn")

      assert notifications(user) == []
    end

    test "the same trip does not notify twice" do
      user = create_user("Europe/Warsaw")

      :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")
      reloaded = Auth.get_user(user.uuid)
      :ok = TimeZoneAlert.observe(reloaded, "Asia/Tokyo")
      :ok = TimeZoneAlert.observe(Auth.get_user(user.uuid), "Asia/Tokyo")

      assert length(notifications(user)) == 1
    end

    test "moving on to a third zone notifies again" do
      user = create_user("Europe/Warsaw")

      :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")
      :ok = TimeZoneAlert.observe(Auth.get_user(user.uuid), "America/New_York")

      assert length(notifications(user)) == 2
    end

    test "an account with no timezone of its own is left alone" do
      user = create_user(nil)

      :ok = TimeZoneAlert.observe(user, "Asia/Tokyo")

      assert notifications(user) == []
    end

    test "an unrecognised zone string is ignored rather than notified about" do
      user = create_user("Europe/Warsaw")

      :ok = TimeZoneAlert.observe(user, "Mars/Olympus_Mons")
      :ok = TimeZoneAlert.observe(user, "")

      assert notifications(user) == []
    end
  end
end
