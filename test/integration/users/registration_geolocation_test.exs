defmodule PhoenixKit.Integration.Users.RegistrationGeolocationTest do
  @moduledoc """
  `IpAddress.extract_from_socket/1` and `extract_from_conn/1` return the
  literal string `"unknown"` — never `nil` — when a socket/conn cannot tell
  the visitor's address (missing `:peer_data`, no forwarded headers behind a
  proxy). `register_user_with_geolocation/2` used to guard on `is_binary/1`
  alone, so that literal string satisfied the guard, got written to
  `registration_ip` as if it were a real address, and rendered verbatim in
  the admin UI instead of "No data". Every self-registered user on a host
  that never wired up `:peer_data` got `registration_ip == "unknown"`.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Users.Auth

  defp unique_email, do: "reggeo_#{System.unique_integer([:positive])}@example.com"

  test "an \"unknown\" IP is not stored as a registration_ip" do
    assert {:ok, user} =
             Auth.register_user_with_geolocation(
               %{email: unique_email(), password: "ValidPassword123!"},
               "unknown"
             )

    assert user.registration_ip == nil
    assert user.registration_country == nil
  end

  test "a real IP is still stored and looked up" do
    assert {:ok, user} =
             Auth.register_user_with_geolocation(
               %{email: unique_email(), password: "ValidPassword123!"},
               "127.0.0.1"
             )

    assert user.registration_ip == "127.0.0.1"
  end

  describe "registration_country (a 2-char, ISO 3166-1 alpha-2 column)" do
    test "a full country name from the geolocation API does not crash the insert" do
      # This is exactly what a real, successful `Geolocation.lookup_location/1`
      # result looks like: `location["country"]` is the full name, not a
      # 2-letter code. Writing that name straight into `registration_country`
      # (a `character varying(2)` column) used to raise an unhandled
      # `string_data_right_truncation` from Postgres and crash the caller —
      # the registration LiveView, mid-signup — instead of returning
      # `{:error, changeset}`. Regressed for real once IP extraction started
      # resolving a visitor's actual public IP (see the "unknown" IP fixes
      # above) — before that, geolocation never actually succeeded in
      # production, so this write path was never exercised.
      # A changeset validation error, not a crash — the fix is that the
      # changeset now rejects this itself (matching the column's real
      # width) instead of forwarding it to Postgres, which used to raise
      # `string_data_right_truncation` and take the whole request down.
      assert {:error, changeset} =
               Auth.register_user(%{
                 email: unique_email(),
                 password: "ValidPassword123!",
                 registration_country: "United States"
               })

      assert {"should be at most %{count} character(s)", opts} =
               changeset.errors[:registration_country]

      assert opts[:count] == 2
    end

    test "a genuine ISO alpha-2 code is stored as-is" do
      assert {:ok, user} =
               Auth.register_user(%{
                 email: unique_email(),
                 password: "ValidPassword123!",
                 registration_country: "US"
               })

      assert user.registration_country == "US"
    end
  end
end
