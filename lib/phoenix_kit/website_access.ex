defmodule PhoenixKit.WebsiteAccess do
  @moduledoc """
  Website access: one settings page, a list of independently switchable
  features, and presets that switch a bundle of them on.

  The boss first asked for website *modes* — maintenance, a dev mode, a
  third nobody remembers — then wanted to mix and match what the modes do,
  which makes modes the wrong unit. So each feature is a checkbox with an
  explanation and, where it needs one, its own area of options; the old
  modes are `presets/0` — a button that sets settings, nothing else, and
  everything stays adjustable after.

  The features, each in its own context:

    * `Gate` — the password gate, a hard block before anyone sees anything
    * `Redirect` — send public visitors to the production site
    * `Notice` — a banner on every page
    * site closed — `PhoenixKit.Modules.Maintenance`, part of core; the
      "Maintenance" and "Under construction" presets switch it on
    * hide from search engines — the crawlers module's `noindex`, shared
    * `AllowedAddresses` — addresses that pass the gate and the redirect

  Every setting goes through `PhoenixKit.Settings`, so V184's history
  records who switched what and when (`opts` carry `actor_uuid:` and
  `source:`). `Environment.read/0` describes how the install is running, to
  suggest a preset — never to switch one on.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Environment, Gate, Notice, Redirect}

  @type feature :: %{
          key: atom(),
          label: String.t(),
          explanation: String.t(),
          on?: boolean(),
          switched_on?: boolean(),
          ready?: boolean(),
          needs: String.t() | nil
        }

  @doc """
  The features, in page order, each with its current state: `on?` is
  "actually enforced right now", `switched_on?` the checkbox, `ready?`
  whether the checkbox would take effect (a gate needs a password, a
  redirect a URL, a notice a text), `needs` says what is missing.
  """
  @spec features() :: [feature()]
  def features do
    [
      feature(
        :gate,
        gettext("Password gate"),
        gettext(
          "A hard block before anyone sees anything: a blank page with only a password prompt. The password is needed to see the site at all and to reach your own login. Every try is kept — with what was typed — so a bot at the door can be told from a client mistyping."
        ),
        Gate.enabled?(),
        Gate.switched_on?(),
        Gate.password_set?(),
        gettext("a password")
      ),
      feature(
        :redirect,
        gettext("Redirect to production"),
        gettext(
          "Visitors asking for a public URL are sent to the same path on the production site. Logged-in users and admin paths are never redirected. Everyone, or only search-engine crawlers."
        ),
        Redirect.enabled?(),
        Redirect.switched_on?(),
        Redirect.target_url() != nil,
        gettext("the production URL")
      ),
      feature(
        :notice,
        gettext("Visitor notice"),
        gettext(
          "A bar along the bottom of every page — an icon, a line of text, an optional link: \"this is the development site, the live one is at …\". Everyone sees it, admins included, so you see what visitors see."
        ),
        Notice.enabled?(),
        Notice.switched_on?(),
        Notice.text() != "",
        gettext("a text")
      ),
      feature(
        :maintenance,
        gettext("Site closed"),
        gettext(
          "Everyone but admins and owners sees a closed page — a heading, a message, a countdown when there is an end time — instead of the site. By hand, or in a scheduled window. The Maintenance and Under construction presets switch it on with matching texts."
        ),
        Maintenance.active?(),
        Maintenance.active?(),
        true,
        nil
      ),
      feature(
        :no_index,
        gettext("Hide from search engines"),
        gettext(
          "Every page tells crawlers not to index it, in the page and in a response header. This is the same switch as on the Crawlers page — changing it here changes it there."
        ),
        Crawlers.no_index_enabled?(),
        Crawlers.no_index_enabled?(),
        true,
        nil
      ),
      feature(
        :allowed_addresses,
        gettext("Allowed addresses"),
        gettext(
          "Addresses that walk past the password gate and the redirect without a password — the office, a home connection. One per line."
        ),
        AllowedAddresses.list() != [],
        AllowedAddresses.list() != [],
        true,
        nil
      )
    ]
  end

  defp feature(key, label, explanation, on?, switched_on?, ready?, needs) do
    %{
      key: key,
      label: label,
      explanation: explanation,
      on?: on?,
      switched_on?: switched_on?,
      ready?: ready?,
      needs: if(ready?, do: nil, else: needs)
    }
  end

  @doc "Switches one feature's checkbox. `opts` carry the history's actor/source."
  @spec set(atom(), boolean(), keyword()) :: {:ok, term()} | {:error, term()}
  def set(:gate, on?, opts), do: Gate.set_enabled(on?, opts)

  def set(:redirect, on?, opts),
    do: Settings.update_boolean_setting(Redirect.enabled_key(), on?, opts)

  def set(:notice, on?, opts),
    do: Settings.update_boolean_setting(Notice.enabled_key(), on?, opts)

  def set(:maintenance, on?, opts), do: Maintenance.set_active(on?, opts)

  def set(:no_index, on?, opts), do: Crawlers.update_no_index(on?, opts)
  def set(_feature, _on?, _opts), do: {:error, :not_switchable}

  # ── Presets ────────────────────────────────────────────────────────

  @doc """
  The presets: a name, what it is for, and what it switches. Applying one
  only sets settings; every feature stays adjustable after.
  """
  @spec presets() :: [%{key: String.t(), label: String.t(), description: String.t()}]
  def presets do
    [
      %{
        key: "maintenance",
        label: gettext("Maintenance"),
        description:
          gettext(
            "The site is closed for now: visitors see the closed page with a maintenance heading and message (and the countdown once an end time is set). Nothing else changes — a live site stays indexed."
          )
      },
      %{
        key: "under_construction",
        label: gettext("Under construction"),
        description:
          gettext(
            "Maintenance on with an under-construction message (and the countdown once a schedule is set); the notice shows the construction icon. Search engines are told to wait."
          )
      },
      %{
        key: "dev_site",
        label: gettext("Development site"),
        description:
          gettext(
            "The password gate on and search engines told to stay away. No visitor notice — the admin header's automatic \"[dev]\" tag already says this is a dev site to anyone logged in."
          )
      },
      %{
        key: "live",
        label: gettext("Live"),
        description: gettext("Everything off: the site is open, indexed and undisturbed.")
      }
    ]
  end

  @spec apply_preset(String.t(), keyword()) :: :ok | {:error, term()}
  def apply_preset("maintenance", opts) do
    with {:ok, _} <- Maintenance.set_active(true, opts),
         {:ok, _} <- Maintenance.update_header(closed_heading(:maintenance), opts),
         {:ok, _} <- Maintenance.update_subtext(closed_message(:maintenance), opts) do
      :ok
    end
  end

  def apply_preset("under_construction", opts) do
    with {:ok, _} <- Maintenance.set_active(true, opts),
         {:ok, _} <- Maintenance.update_header(closed_heading(:construction), opts),
         {:ok, _} <- Maintenance.update_subtext(closed_message(:construction), opts),
         {:ok, _} <- Crawlers.update_no_index(true, opts),
         {:ok, _} <- Settings.update_setting(Notice.icon_key(), "construction", opts),
         {:ok, _} <-
           Settings.update_setting(
             Notice.text_key(),
             default_if_blank(Notice.text(), gettext("This site is under construction.")),
             opts
           ),
         {:ok, _} <- Settings.update_boolean_setting(Notice.enabled_key(), true, opts) do
      :ok
    end
  end

  # No visitor notice here — the admin header's automatic "[dev]" tag
  # (Environment.read/0's looks_like_dev?) already tells an admin apart from
  # production without a switch to remember, and a bottom bar for every
  # visitor was never the point of this preset.
  def apply_preset("dev_site", opts) do
    with {:ok, _} <- Gate.set_enabled(true, opts),
         {:ok, _} <- Crawlers.update_no_index(true, opts) do
      :ok
    end
  end

  def apply_preset("live", opts) do
    with {:ok, _} <- Gate.set_enabled(false, opts),
         {:ok, _} <- Settings.update_boolean_setting(Redirect.enabled_key(), false, opts),
         {:ok, _} <- Settings.update_boolean_setting(Notice.enabled_key(), false, opts),
         {:ok, _} <- Maintenance.set_active(false, opts),
         {:ok, _} <- Crawlers.update_no_index(false, opts) do
      :ok
    end
  end

  def apply_preset(_other, _opts), do: {:error, :unknown_preset}

  defp default_if_blank(value, default) when value in [nil, ""], do: default
  defp default_if_blank(value, _default), do: value

  # The closed page's texts for a preset. A heading or message the admin wrote
  # themselves is kept; one that is blank or one of the STOCK texts (either
  # preset's, or the context's own default) is replaced, so applying
  # "Maintenance" after "Under construction" does change the page.
  defp closed_heading(kind) do
    current = Maintenance.get_header()
    if current in stock_headings(), do: stock_heading(kind), else: current
  end

  defp closed_message(kind) do
    current = Maintenance.get_subtext()
    if current in stock_messages(), do: stock_message(kind), else: current
  end

  defp stock_heading(:maintenance), do: gettext("Maintenance")
  defp stock_heading(:construction), do: gettext("Under construction")

  defp stock_message(:maintenance),
    do: gettext("We are doing some work on the site. Please check back in a little while.")

  defp stock_message(:construction),
    do: gettext("We are building something new here. Please check back soon.")

  defp stock_headings,
    do: [
      "",
      nil,
      Maintenance.default_header(),
      stock_heading(:maintenance),
      stock_heading(:construction)
    ]

  defp stock_messages,
    do: [
      "",
      nil,
      Maintenance.default_subtext(),
      stock_message(:maintenance),
      stock_message(:construction)
    ]

  @doc "How this install is running — see `Environment`."
  defdelegate environment, to: Environment, as: :read
end
