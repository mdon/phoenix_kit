defmodule PhoenixKit.WebsiteAccess do
  @moduledoc """
  Website access: one settings page, a list of independently switchable
  features.

  The boss first asked for website *modes* — maintenance, a dev mode, a
  third nobody remembers — then wanted to mix and match what the modes do,
  which makes modes the wrong unit. So each feature is a checkbox with an
  explanation and, where it needs one, its own area of options.

  The features, each in its own context:

    * `Gate` — the password gate, a hard block before anyone sees anything
    * `Redirect` — send public visitors to the production site
    * site closed — `PhoenixKit.Modules.Maintenance`, part of core
    * hide from search engines — the crawlers module's `noindex`, shared
    * `AllowedAddresses` — addresses that pass the gate and the redirect

  Every setting goes through `PhoenixKit.Settings`, so V184's history
  records who switched what and when (`opts` carry `actor_uuid:` and
  `source:`). `Environment.read/0` describes how the install is running —
  it drives the admin header's automatic "[dev]" tag, never a setting.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Environment, Gate, Redirect}

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
  redirect a URL), `needs` says what is missing.
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
        :maintenance,
        gettext("Site closed"),
        gettext(
          "Everyone but admins and owners sees a closed page — a heading, a message, a countdown when there is an end time — instead of the site. By hand, or in a scheduled window."
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

  def set(:maintenance, on?, opts), do: Maintenance.set_active(on?, opts)

  def set(:no_index, on?, opts), do: Crawlers.update_no_index(on?, opts)
  def set(_feature, _on?, _opts), do: {:error, :not_switchable}

  @doc "How this install is running — see `Environment`."
  defdelegate environment, to: Environment, as: :read
end
