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
end
