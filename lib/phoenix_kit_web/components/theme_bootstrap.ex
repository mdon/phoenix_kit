defmodule PhoenixKitWeb.Components.ThemeBootstrap do
  @moduledoc """
  The pre-paint theme script — renders in `<head>`, before the stylesheets.

  Every page class had its own first-paint story and most of them flashed:
  the dashboard's `<html>` carried no `data-theme` and applied the saved one
  from a script at the end of `<body>`; the standalone admin hardcoded
  `data-theme="light"` and fixed it up on DOMContentLoaded; the kit's own
  root layout hardcoded light and ran no theme JS at all. A dark-mode user
  got a white flash on the first two and permanent light on the third.

  This component is the one shared answer: a synchronous script that reads
  the saved choice, resolves `"system"` from `ThemeConfig.system_pair/0` —
  the CONFIGURED pair, not hardcoded `phoenix-*` names — and stamps
  `data-theme` plus `color-scheme` on `<html>` before the first paint. It
  also subscribes to the `storage` event, so a theme picked in one tab
  follows into the others.

  Host root layouts can render it too (`PhoenixKitWeb.Components.ThemeBootstrap`
  is public API); a host with its own equivalent script loses nothing by
  keeping it.
  """

  use Phoenix.Component

  alias PhoenixKit.ThemeConfig

  @doc """
  The blocking head script. Render before the CSS `<link>` tags.
  """
  def theme_bootstrap(assigns) do
    {light, dark} = ThemeConfig.system_pair()

    assigns =
      assigns
      |> assign(:light, light)
      |> assign(:dark, dark)
      |> assign(
        :base_map_json,
        # :html_safe escapes < and > so no config-derived name can close
        # this <script> tag. Names are validated upstream too; this is the
        # sink-side half of that defense.
        Jason.encode!(ThemeConfig.base_map(), escape: :html_safe)
      )

    ~H"""
    <script>
      (function () {
        var KEY = 'phx:theme';
        var LIGHT = '<%= @light %>';
        var DARK = '<%= @dark %>';
        var BASES = <%= Phoenix.HTML.raw(@base_map_json) %>;

        function resolve(theme) {
          if (!theme || theme === 'system') {
            return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
              ? DARK
              : LIGHT;
          }
          return theme;
        }

        function apply(theme) {
          var resolved = resolve(theme);
          var el = document.documentElement;
          el.setAttribute('data-theme', resolved);
          el.style.colorScheme = BASES[resolved] || 'light';
        }

        var saved = null;
        try {
          saved = localStorage.getItem(KEY);
        } catch (e) {
          /* storage blocked: fall through to system */
        }

        apply(saved);

        // A theme picked in another tab follows into this one.
        window.addEventListener('storage', function (e) {
          if (e.key === KEY) apply(e.newValue);
        });
      })();
    </script>
    """
  end
end
