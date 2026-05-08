defmodule PhoenixKit.Dashboard.GroupTest do
  @moduledoc """
  Unit tests for PhoenixKit.Dashboard.Group localized_label/1 and the
  gettext_backend / gettext_domain fields round-tripping through Group.new/1.
  """

  use ExUnit.Case, async: false

  alias PhoenixKit.Dashboard.Group

  @backend PhoenixKitWeb.Gettext
  @known_msgid "Dashboard"
  @known_ru_translation "Панель управления"
  @unknown_msgid "This string has no translation"

  setup do
    original_locale = Gettext.get_locale(@backend)

    on_exit(fn ->
      Gettext.put_locale(@backend, original_locale)
    end)

    :ok
  end

  describe "localized_label/1" do
    test "returns raw label when gettext_backend is nil (default)" do
      group = Group.new(id: :main, label: "Main")
      assert Group.localized_label(group) == "Main"
    end

    test "critical regression: returns nil when label is nil (unlabeled group)" do
      group = %Group{id: :x, label: nil}
      assert Group.localized_label(group) == nil
    end

    test "returns nil when label is nil even with a gettext_backend set" do
      group = %Group{id: :x, label: nil, gettext_backend: @backend, gettext_domain: "default"}
      assert Group.localized_label(group) == nil
    end

    test "returns translated string when backend and locale are set" do
      Gettext.put_locale(@backend, "ru")

      group =
        Group.new(
          id: :dashboard,
          label: @known_msgid,
          gettext_backend: @backend
        )

      assert Group.localized_label(group) == @known_ru_translation
    end

    test "falls back to msgid when no translation exists for the requested locale" do
      Gettext.put_locale(@backend, "ru")

      group =
        Group.new(
          id: :unknown,
          label: @unknown_msgid,
          gettext_backend: @backend
        )

      assert Group.localized_label(group) == @unknown_msgid
    end

    test "renders raw label for a struct constructed without explicitly setting gettext fields" do
      # Simulates pre-1.8 callers — defstruct supplies nil/`"default"` defaults,
      # so the result must equal the raw label.
      group = %Group{id: :legacy, label: "Legacy"}
      assert Group.localized_label(group) == "Legacy"
    end

    test "tolerates an old-shape struct missing :gettext_backend / :gettext_domain keys" do
      # Hot-reload + ETS scenario — see the matching test in tab_test.exs
      # for the full rationale. A %Group{} cached under phoenix_kit ~> 1.7.x
      # does not carry the new keys; localized_label/1 must gracefully fall
      # back to the raw label rather than raise FunctionClauseError.
      stale =
        %Group{id: :legacy, label: "Legacy"}
        |> Map.delete(:gettext_backend)
        |> Map.delete(:gettext_domain)

      refute Map.has_key?(stale, :gettext_backend)
      refute Map.has_key?(stale, :gettext_domain)
      assert Group.localized_label(stale) == "Legacy"
    end
  end

  describe "Group.new/1 round-trips gettext fields" do
    test "round-trips gettext_backend and gettext_domain from map" do
      group =
        Group.new(%{
          id: :test,
          label: "Test",
          gettext_backend: @backend,
          gettext_domain: "navigation"
        })

      assert group.gettext_backend == @backend
      assert group.gettext_domain == "navigation"
    end

    test "round-trips gettext_backend and gettext_domain from keyword list" do
      group =
        Group.new(
          id: :test,
          label: "Test",
          gettext_backend: @backend,
          gettext_domain: "navigation"
        )

      assert group.gettext_backend == @backend
      assert group.gettext_domain == "navigation"
    end

    test "gettext_backend defaults to nil (map form)" do
      group = Group.new(%{id: :test, label: "Test"})
      assert group.gettext_backend == nil
    end

    test "gettext_backend defaults to nil (keyword form)" do
      group = Group.new(id: :test, label: "Test")
      assert group.gettext_backend == nil
    end

    test "gettext_domain defaults to 'default' (map form)" do
      group = Group.new(%{id: :test, label: "Test"})
      assert group.gettext_domain == "default"
    end

    test "gettext_domain defaults to 'default' (keyword form)" do
      group = Group.new(id: :test, label: "Test")
      assert group.gettext_domain == "default"
    end
  end
end
