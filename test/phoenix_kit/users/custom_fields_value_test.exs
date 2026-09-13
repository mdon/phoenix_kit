defmodule PhoenixKit.Users.CustomFieldsValueTest do
  @moduledoc """
  The value-shape helpers `custom_fields` needs because the column is
  free-form JSONB while every field `type` describes a scalar.

  No database: these are the three predicates the crash in issue #780 turned
  out to hinge on, and they must hold on the DB-less half of the suite too.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.CustomFields

  describe "internal_key?/1" do
    test "the keys PhoenixKit writes as per-user state are internal" do
      for key <- ~w(
            activity_view_mode
            etcher_colors
            etcher_line_params
            media_expanded_folders
            media_sidebar_collapsed
            media_view_mode
            media_viewer_info_collapsed
            notification_preferences
            preferred_locale
            referral_satisfied_at
            referral_satisfied_via
            timezone_alert_zone
            users_view_mode
          ) do
        assert CustomFields.internal_key?(key), "expected #{key} to be internal"
      end
    end

    test "every notification channel's config key is internal, whatever the channel" do
      assert CustomFields.internal_key?("notification_channel:telegram")
      assert CustomFields.internal_key?("notification_channel:email")
      assert CustomFields.internal_key?("notification_channel:anything_a_module_adds")
    end

    test "an admin-defined profile field is not" do
      refute CustomFields.internal_key?("phone")
      refute CustomFields.internal_key?("department")

      # Prefix matching is on the key's start, not anywhere in it.
      refute CustomFields.internal_key?("my_notification_channel:telegram")
    end

    test "a non-string key answers false rather than raising" do
      refute CustomFields.internal_key?(nil)
      refute CustomFields.internal_key?(:preferred_locale)
    end
  end

  describe "structured_value?/1" do
    test "a map or a list is structured" do
      assert CustomFields.structured_value?(%{"width" => 13, "dash" => "solid"})
      assert CustomFields.structured_value?(%{})
      assert CustomFields.structured_value?(["#fca5a5", "#fdba74"])
      assert CustomFields.structured_value?([])
    end

    test "everything a field type can represent is not" do
      refute CustomFields.structured_value?("solid")
      refute CustomFields.structured_value?(13)
      refute CustomFields.structured_value?(1.5)
      refute CustomFields.structured_value?(true)
      refute CustomFields.structured_value?(nil)
    end
  end

  describe "printable/1" do
    test "a map renders as JSON instead of raising" do
      # `to_string/1` on this value is the Protocol.UndefinedError that took the
      # admin user pages down with a 500.
      assert CustomFields.printable(%{"dash" => "solid"}) == ~s({"dash":"solid"})
    end

    test "a list is joined, not concatenated into one run" do
      assert CustomFields.printable(["#fca5a5", "#fdba74"]) == "#fca5a5, #fdba74"
    end

    test "nested structure survives" do
      assert CustomFields.printable([%{"a" => 1}]) == ~s({"a":1})
    end

    test "scalars pass through" do
      assert CustomFields.printable("text") == "text"
      assert CustomFields.printable(13) == "13"
      assert CustomFields.printable(true) == "true"
      assert CustomFields.printable(nil) == ""
    end
  end
end
