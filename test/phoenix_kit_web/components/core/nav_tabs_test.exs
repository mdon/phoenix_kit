defmodule PhoenixKitWeb.Components.Core.NavTabsTest do
  @moduledoc """
  `nav_tabs/1` is the ecosystem's tab component, and until now most tab strips
  in the module libraries reimplemented it instead of calling it — which is why
  a single daisyUI class rename (`tabs-boxed` -> `tabs-box` in v5) had to be
  applied at 21 hand-rolled sites across 8 repositories.

  Two things blocked adoption, and these tests pin both fixes:

  - a query-param tab strip needs `patch` (a `navigate` remounts the LiveView
    and drops socket state), and the component only ever emitted `navigate`;
  - the container's `bg-base-200 p-1` was baked in, and `class` can only ADD,
    so a strip nested in an already-framed container had no way to shed it.

  Plus the failure mode that makes silent breakage possible at all: the tab
  LINK KEYS live in a runtime map, so no `attr` declaration can validate them.
  A module passing `:patch` to an older core would land in the button branch
  with `on_change` nil and render a strip wired to `phx-click={nil}` — right
  down to the styling. Those cases raise now.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.NavTabs

  defp render_tabs(assigns) do
    assigns = Map.put_new(assigns, :active_tab, "a")
    render_component(&NavTabs.nav_tabs/1, assigns)
  end

  describe "link modes" do
    test ":patch renders a patch link, not a navigate one" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "followers", label: "Followers", patch: "/profile/connections?tab=followers"}
          ]
        })

      # data-phx-link=patch is what keeps the click inside the current
      # LiveView; navigate would remount it and lose the socket state.
      assert html =~ ~s(data-phx-link="patch")
      refute html =~ ~s(data-phx-link="redirect")
    end

    test ":navigate renders a navigation link" do
      html = render_tabs(%{tabs: [%{id: "a", label: "General", navigate: "/admin/settings"}]})

      assert html =~ ~s(data-phx-link="redirect")
      refute html =~ ~s(data-phx-link="patch")
    end

    test ":path still means navigate — the original spelling never breaks" do
      from_path = render_tabs(%{tabs: [%{id: "a", label: "General", path: "/admin/settings"}]})

      from_navigate =
        render_tabs(%{tabs: [%{id: "a", label: "General", navigate: "/admin/settings"}]})

      assert from_path == from_navigate
    end

    test "a query string survives the route helper intact" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "followers", label: "Followers", patch: "/profile/connections?tab=followers"}
          ]
        })

      # If the helper dropped or re-encoded the query, the tab would render
      # but the active state would never stick on reload.
      assert html =~ "?tab=followers"
    end

    test "a strip may mix link tabs and event tabs" do
      html =
        render_tabs(%{
          on_change: "switch",
          tabs: [
            %{id: "a", label: "Linked", navigate: "/admin/settings"},
            %{id: "b", label: "Evented"}
          ]
        })

      assert html =~ ~s(data-phx-link="redirect")
      assert html =~ ~s(phx-value-tab="b")
    end
  end

  describe "event payload" do
    test "event tabs dispatch phx-value-tab, never phx-value-value" do
      html = render_tabs(%{on_change: "switch_tab", tabs: [%{id: "oban", label: "Oban"}]})

      assert html =~ ~s(phx-value-tab="oban")

      # `value` is the hazardous key: LiveView's extractMeta overwrites
      # meta.value with the element's own .value DOM property, so a <button>
      # would deliver "". The component must never emit it.
      refute html =~ "phx-value-value"
    end
  end

  describe "variants" do
    test ":boxed is the default and keeps the filled strip" do
      html = render_tabs(%{on_change: "s", tabs: [%{id: "a", label: "A"}]})

      assert html =~ "bg-base-200"
      assert html =~ "tabs-box"
    end

    test ":plain drops the frame a caller could not otherwise remove" do
      html = render_tabs(%{variant: :plain, on_change: "s", tabs: [%{id: "a", label: "A"}]})

      refute html =~ "bg-base-200"

      # `tabs-box` must go too: it IS the daisyUI frame (background, padding,
      # radius, shadow), so dropping only the bg-base-200/p-1 overrides would
      # leave the box drawn and make :plain a lie.
      refute html =~ "tabs-box"

      # Still a tab strip, just unframed.
      assert html =~ "tabs"
    end

    test "class ADDS to the container rather than replacing it" do
      html =
        render_tabs(%{
          variant: :plain,
          class: "inline-flex",
          on_change: "s",
          tabs: [%{id: "a", label: "A"}]
        })

      # Appended to the variant's classes, not swapped for them.
      assert html =~ "inline-flex"
      assert html =~ "tabs"
    end
  end

  describe "malformed tabs" do
    test "a tab with no link key and no on_change warns but still renders" do
      # Deliberately NOT a raise. This is a library: a dead tab is bad, but
      # taking the whole LiveView down over a tab strip is worse, and we
      # cannot audit every consumer. It has to stay findable, though.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = render_tabs(%{tabs: [%{id: "a", label: "A"}]})
          assert html =~ "<button"
        end)

      assert log =~ "renders a button that does nothing"
    end

    test "setting more than one link key raises" do
      # No degraded render is defensible here — there is no way to choose —
      # and :navigate/:patch are new enough that no existing caller can trip it.
      for tab <- [
            %{id: "a", label: "A", navigate: "/x", patch: "/y"},
            %{id: "a", label: "A", navigate: "/x", path: "/y"},
            %{id: "a", label: "A", patch: "/x", path: "/y"}
          ] do
        assert_raise ArgumentError, ~r/more than one link key/, fn ->
          render_tabs(%{tabs: [tab]})
        end
      end
    end

    test "a nil link value counts as absent, not as a link to nowhere" do
      # Tab lists are routinely built with a conditional path; treating that
      # nil as a link hands Routes.path/1 a nil and raises mid-render.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          html = render_tabs(%{on_change: "s", tabs: [%{id: "a", label: "A", path: nil}]})

          assert html =~ ~s(phx-value-tab="a")
          refute html =~ "data-phx-link"
        end)

      # It fell back to the event tab cleanly, so nothing to warn about.
      refute log =~ "does nothing"
    end
  end

  describe "class helpers" do
    test "tablist_class/2 is what the component itself renders" do
      # Shared so tab-styled markup that is NOT a tab strip can reuse one
      # definition — the next daisyUI rename should be a change here, not a
      # sweep across every call site.
      assert NavTabs.tablist_class(:boxed) == ["tabs tabs-box bg-base-200 p-1", nil]
      assert NavTabs.tablist_class(:plain) == ["tabs", nil]
      assert NavTabs.tablist_class(:plain, "inline-flex") == ["tabs", "inline-flex"]
    end

    test "tab_class/2 marks the active tab" do
      assert NavTabs.tab_class(true) == ["tab gap-2", "tab-active", nil]
      assert NavTabs.tab_class(false) == ["tab gap-2", false, nil]
    end
  end

  describe "badges" do
    test "a nil badge renders nothing, not an empty badge" do
      # `badge: if(count > 0, do: count)` is the normal way to write a count
      # that only shows when non-zero; keying on key PRESENCE rendered that
      # as an empty pill.
      html = render_tabs(%{tabs: [%{id: "a", label: "Requests", navigate: "/x", badge: nil}]})

      assert html =~ "Requests"
      refute html =~ "badge"
    end

    test "a zero badge still renders — only nil is absent" do
      html = render_tabs(%{tabs: [%{id: "a", label: "Requests", navigate: "/x", badge: 0}]})

      assert html =~ "badge"
    end

    test "badge_class wins over the active-tab default" do
      # A pending-requests count stays badge-warning whether or not its tab
      # is the active one.
      html =
        render_tabs(%{
          active_tab: "a",
          tabs: [
            %{id: "a", label: "Requests", navigate: "/x", badge: 3, badge_class: "badge-warning"}
          ]
        })

      assert html =~ "badge-warning"
      refute html =~ "badge-primary"
    end

    test "without badge_class the active tab still gets the primary tone" do
      html =
        render_tabs(%{active_tab: "a", tabs: [%{id: "a", label: "A", navigate: "/x", badge: 3}]})

      assert html =~ "badge-primary"
    end
  end

  describe "icons and badges" do
    test "both render, in either mode" do
      html =
        render_tabs(%{
          tabs: [
            %{id: "a", label: "Followers", navigate: "/x", icon: "hero-user", badge: 12}
          ]
        })

      assert html =~ "hero-user"
      assert html =~ "badge"
      assert html =~ "12"
    end
  end
end
