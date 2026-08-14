defmodule PhoenixKitWeb.Components.ThemeControllerScript do
  @moduledoc """
  The one theme-controller script — the behavior behind every element the
  `PhoenixKitWeb.Components.Core.ThemeController` picker renders.

  Before this module the same behavior existed three times: a hand-written
  script in the dashboard layout, a near-copy inside the admin layout
  wrapper, and the deleted static `phoenix_kit_themes.js`. They drifted —
  the dashboard copy carried its own hardcoded base map that missed newer
  themes and could never know host-defined ones, and both resolved
  `"system"` to hardcoded `phoenix-*` names, wrong for any host whose
  configured pair uses other names (see `PhoenixKit.ThemeConfig.system_pair/0`).

  Everything data-shaped is generated from `PhoenixKit.ThemeConfig` at
  render time, so host `:theme_definitions` flow through with zero JS
  changes. The script is idempotent per page (`window.__pkThemeController`
  guard) and every DOM hook is optional — a page with no dropdown panels,
  no label element, or no toggle simply skips those branches.

  Renders at the end of `<body>`; the pre-paint half of the story is
  `PhoenixKitWeb.Components.ThemeBootstrap` in `<head>`.
  """

  use Phoenix.Component

  alias PhoenixKit.ThemeConfig

  @doc """
  The shared theme controller. Render once, at the end of `<body>`.
  """
  def theme_controller_script(assigns) do
    {light, dark} = ThemeConfig.system_pair()

    assigns =
      assigns
      |> assign(:light, light)
      |> assign(:dark, dark)
      |> assign(:base_map_json, Jason.encode!(ThemeConfig.base_map()))
      |> assign(:labels_json, Jason.encode!(ThemeConfig.translated_label_map()))

    ~H"""
    <script>
      (function () {
        // One instance per page, whichever layout renders first.
        if (window.__pkThemeController) return;
        window.__pkThemeController = true;

        const STORAGE_KEY = 'phx:theme';
        const themeBaseMap = <%= Phoenix.HTML.raw(@base_map_json) %>;
        const themeLabels = <%= Phoenix.HTML.raw(@labels_json) %>;
        // The CONFIGURED light/dark pair "system" resolves to.
        const systemPair = { light: '<%= @light %>', dark: '<%= @dark %>' };
        const media = window.matchMedia?.('(prefers-color-scheme: dark)') || null;

        let dispatching = false;
        let dropdowns = [];

        function resolve(theme) {
          if (theme !== 'system') return theme;
          return media && media.matches ? systemPair.dark : systemPair.light;
        }

        function toTitle(value) {
          return value
            .split('-')
            .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
            .join(' ');
        }

        // Stamp the theme on the document and mirror it into every picker —
        // labels, dropdown option indicators, and the pair toggle. Does NOT
        // persist or dispatch; that is setTheme's half.
        function apply(theme) {
          const resolved = resolve(theme);

          [document.documentElement, document.body].forEach((el) => {
            if (!el) return;
            el.setAttribute('data-theme', resolved);
            el.style.colorScheme = themeBaseMap[resolved] || 'light';
          });

          document.querySelectorAll('[data-theme-current-label]').forEach((el) => {
            el.textContent = themeLabels[theme] || toTitle(theme);
          });

          document.querySelectorAll('[data-theme-target]').forEach((btn) => {
            const targets = (btn.dataset.themeTarget || '')
              .split(',')
              .map((s) => s.trim())
              .filter(Boolean);
            const isActive = targets.includes(theme) || targets.includes(resolved);

            if (btn.dataset.themeRole === 'toggle') {
              // The persistent pair toggle: aria-pressed = dark half on,
              // icons swap, and data-theme-next always points at the OTHER
              // theme so the click handler needs no state of its own.
              const isDark = resolved === btn.dataset.themeDark;
              btn.setAttribute('aria-pressed', String(isDark));
              btn.dataset.themeNext = isDark ? btn.dataset.themeLight : btn.dataset.themeDark;
              btn.querySelectorAll('[data-toggle-icon]').forEach((icon) => {
                icon.classList.toggle('hidden', (icon.dataset.toggleIcon === 'dark') !== isDark);
              });
            } else if (btn.dataset.themeRole === 'dropdown-option') {
              btn.classList.toggle('bg-base-200', isActive);
              btn.classList.toggle('ring-2', isActive);
              btn.classList.toggle('ring-primary/70', isActive);
              btn.setAttribute('aria-selected', String(isActive));
              btn.querySelectorAll('[data-theme-active-indicator]').forEach((icon) => {
                icon.classList.toggle('opacity-100', isActive);
                icon.classList.toggle('scale-100', isActive);
                icon.classList.toggle('scale-75', !isActive);
              });
            }
          });
        }

        function setTheme(theme) {
          apply(theme);

          if (theme === 'system') {
            localStorage.removeItem(STORAGE_KEY);
          } else {
            localStorage.setItem(STORAGE_KEY, theme);
          }

          dropdowns.forEach((entry) => setDropdownState(entry, false));

          // Notify window-level listeners — host root layouts included.
          // Guarded, because this script also LISTENS for phx:set-theme on
          // window: dispatchEvent is synchronous, so the flag is set for
          // exactly the duration of our own event and the listener ignores
          // it, while external events still come through.
          if (!dispatching) {
            dispatching = true;
            try {
              window.dispatchEvent(new CustomEvent('phx:set-theme', { detail: { theme } }));
            } catch (error) {
              console.warn('PhoenixKit theme controller: unable to dispatch phx:set-theme', error);
            } finally {
              dispatching = false;
            }
          }
        }

        function setDropdownState(entry, isOpen) {
          if (!entry?.button || !entry?.panel) return;

          entry.button.setAttribute('aria-expanded', String(!!isOpen));
          entry.panel.setAttribute('aria-hidden', String(!isOpen));
          entry.panel.classList.toggle('pointer-events-auto', !!isOpen);
          entry.panel.classList.toggle('pointer-events-none', !isOpen);
          entry.panel.classList.toggle('opacity-100', !!isOpen);
          entry.panel.classList.toggle('opacity-0', !isOpen);
          entry.panel.classList.toggle('-translate-y-2', !isOpen);
          entry.panel.classList.toggle('translate-y-0', !!isOpen);
        }

        function registerDropdowns() {
          dropdowns = Array.from(document.querySelectorAll('[data-theme-dropdown]')).map(
            (container) => ({
              container,
              button: container.querySelector('[data-theme-toggle]'),
              panel: container.querySelector('[data-theme-dropdown-panel]')
            })
          );

          dropdowns.forEach((entry) => {
            setDropdownState(entry, false);
            if (!entry.button || !entry.panel) return;

            entry.button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              const expanded = entry.button.getAttribute('aria-expanded') === 'true';
              setDropdownState(entry, !expanded);
            });

            entry.panel.addEventListener('click', (event) => event.stopPropagation());
          });
        }

        function init() {
          registerDropdowns();

          // apply, not setTheme: initialization reflects the saved choice
          // into the UI but should neither rewrite storage nor announce a
          // change nobody made.
          apply(localStorage.getItem(STORAGE_KEY) || 'system');

          // The pair toggle dispatches whatever its data-theme-next holds —
          // no per-button phx-click, no state of its own. The same document
          // click closes any dropdown the click landed outside of.
          document.addEventListener('click', (e) => {
            const toggle = e.target.closest?.('[data-theme-role="toggle"]');
            if (toggle?.dataset.themeNext) setTheme(toggle.dataset.themeNext);

            if (!dropdowns.some((entry) => entry.container?.contains(e.target))) {
              dropdowns.forEach((entry) => setDropdownState(entry, false));
            }
          });

          // Follow the OS while in system mode.
          media?.addEventListener('change', () => {
            if ((localStorage.getItem(STORAGE_KEY) || 'system') === 'system') apply('system');
          });

          // A theme picked in another tab: ThemeBootstrap already restamps
          // the attribute pre-paint on fresh loads; this keeps LIVE pages'
          // pickers in sync too. apply, not setTheme — the other tab
          // already persisted.
          window.addEventListener('storage', (e) => {
            if (e.key === STORAGE_KEY) apply(e.newValue || 'system');
          });

          // Theme changes announced by LiveView (JS.dispatch / push_event)
          // or host code. Skip our own dispatches — see the guard above.
          window.addEventListener('phx:set-theme', (e) => {
            const theme = e?.detail?.theme ?? e?.target?.dataset?.phxTheme;
            if (theme && !dispatching) setTheme(theme);
          });

          // Legacy event name — nothing in the kit emits it anymore, kept
          // only so hosts that adopted it keep working.
          document.addEventListener('phx:set-admin-theme', (e) => {
            if (e?.detail?.theme) setTheme(e.detail.theme);
          });
        }

        if (document.readyState === 'loading') {
          document.addEventListener('DOMContentLoaded', init);
        } else {
          init();
        }
      })();
    </script>
    """
  end
end
