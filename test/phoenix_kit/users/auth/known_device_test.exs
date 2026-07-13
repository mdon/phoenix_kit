defmodule PhoenixKit.Users.Auth.KnownDeviceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.KnownDevice

  @valid_attrs %{
    user_uuid: "0193a5e4-0000-7000-8000-000000000001",
    ip_address: "203.0.113.42",
    user_agent_hash: String.duplicate("a", 64),
    browser: "Chrome",
    os: "macOS",
    first_seen_at: ~U[2026-07-13 00:00:00Z],
    last_seen_at: ~U[2026-07-13 00:00:00Z]
  }

  describe "changeset/2" do
    test "valid with all required fields" do
      changeset = KnownDevice.changeset(%KnownDevice{}, @valid_attrs)
      assert changeset.valid?
    end

    test "valid without optional browser/os" do
      attrs = Map.drop(@valid_attrs, [:browser, :os])
      changeset = KnownDevice.changeset(%KnownDevice{}, attrs)
      assert changeset.valid?
    end

    for field <- [:user_uuid, :ip_address, :user_agent_hash, :first_seen_at, :last_seen_at] do
      test "invalid without required field #{field}" do
        attrs = Map.delete(@valid_attrs, unquote(field))
        changeset = KnownDevice.changeset(%KnownDevice{}, attrs)
        refute changeset.valid?
        assert unquote(field) in Keyword.keys(changeset.errors)
      end
    end
  end
end
