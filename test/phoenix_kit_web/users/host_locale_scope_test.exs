defmodule PhoenixKitWeb.Users.HostLocaleScopeTest do
  # Flips global config and the process-global Gettext locale.
  use ExUnit.Case, async: false

  alias PhoenixKitWeb.Components.LayoutWrapper
  alias PhoenixKitWeb.Users.Auth

  setup do
    previous = Application.get_env(:phoenix_kit, :host_live_view_locale)
    previous_scope = Application.get_env(:phoenix_kit, :host_anonymous_scope)
    global = Gettext.get_locale()
    kit = Gettext.get_locale(PhoenixKitWeb.Gettext)

    on_exit(fn ->
      restore(:host_live_view_locale, previous)
      restore(:host_anonymous_scope, previous_scope)
      Gettext.put_locale(global)
      Gettext.put_locale(PhoenixKitWeb.Gettext, kit)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:phoenix_kit, key)
  defp restore(key, value), do: Application.put_env(:phoenix_kit, key, value)

  describe "host_live_view_locale" do
    test "by default every view gets the process-global locale set, as before" do
      Gettext.put_locale("en")
      Auth.put_gettext_locale("et", MyAppWeb.PageLive)
      assert Gettext.get_locale() == "et"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "et"
    end

    test ":leave keeps the global locale for a host view, sets only the kit's backend" do
      Application.put_env(:phoenix_kit, :host_live_view_locale, :leave)
      Gettext.put_locale("en")

      Auth.put_gettext_locale("et", MyAppWeb.PageLive)
      assert Gettext.get_locale() == "en"
      assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "et"
    end

    test ":leave still sets the global locale for the kit's and modules' views" do
      Application.put_env(:phoenix_kit, :host_live_view_locale, :leave)

      for view <- [PhoenixKitWeb.Live.Dashboard, PhoenixKitProjects.Web.ProjectsLive] do
        Gettext.put_locale("en")
        Auth.put_gettext_locale("et", view)
        assert Gettext.get_locale() == "et", inspect(view)
      end
    end
  end

  describe "host_anonymous_scope" do
    test "unset leaves current_scope absent, as before" do
      refute Map.has_key?(LayoutWrapper.prepare_parent_layout_assigns(%{}), :current_scope)
    end

    test "a configured function gives the host layout its anonymous scope when nobody is signed in" do
      Application.put_env(:phoenix_kit, :host_anonymous_scope, fn ->
        %{user: nil, anonymous: true}
      end)

      assigns = LayoutWrapper.prepare_parent_layout_assigns(%{})
      assert assigns.current_scope == %{user: nil, anonymous: true}
    end

    test "an assign already present is not replaced" do
      Application.put_env(:phoenix_kit, :host_anonymous_scope, fn -> :anonymous end)

      assert LayoutWrapper.prepare_parent_layout_assigns(%{current_scope: :mine}).current_scope ==
               :mine
    end

    test "the host's function is not called when a scope is already present" do
      test_pid = self()

      Application.put_env(:phoenix_kit, :host_anonymous_scope, fn ->
        send(test_pid, :host_function_called)
        :anonymous
      end)

      LayoutWrapper.prepare_parent_layout_assigns(%{current_scope: :mine})
      refute_received :host_function_called
    end

    test "a host function that raises leaves the scope absent instead of crashing the layout" do
      Application.put_env(:phoenix_kit, :host_anonymous_scope, fn -> raise "host bug" end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          refute Map.has_key?(LayoutWrapper.prepare_parent_layout_assigns(%{}), :current_scope)
        end)

      assert log =~ "host_anonymous_scope failed"
      assert log =~ "host bug"
    end

    test "a misspelt module/function leaves the scope absent" do
      Application.put_env(:phoenix_kit, :host_anonymous_scope, {No.Such.Module, :anonymous, []})

      capture = fn ->
        refute Map.has_key?(LayoutWrapper.prepare_parent_layout_assigns(%{}), :current_scope)
      end

      assert ExUnit.CaptureLog.capture_log(capture) =~ "host_anonymous_scope failed"
    end
  end
end
