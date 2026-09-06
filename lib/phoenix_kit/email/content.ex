defmodule PhoenixKit.Email.Content do
  @moduledoc """
  Resolves the content of one outbound message: subject, text, and optional HTML.

  Every auth email in core goes through here, so the layering below is decided
  once rather than per message.

  ## Layers, most specific first

  1. **A database template** from the emails package, when one is active under
     this name. Transitional — the template table is being retired (see
     `dev_docs/plans/2026-09-06-filesystem-templates.md`), but it is the only
     customization mechanism installs have today, and it must keep winning until
     the export task has shipped and operators have moved their edits to files.
     Removing it before then would silently revert every customized message.
  2. **A host override file**, resolved by `PhoenixKit.Templates` across the
     recipient's locale, its base language, and a locale-less fallback.
  3. **Core's own default**, a Gettext call evaluated in the recipient's locale.

  Layers 2 and 3 combine per part, so a host that overrides only the body keeps
  core's translated subject.

  ## What a host override looks like on disk

  The template **name is a directory**; the files inside it are named for the
  part they supply, optionally carrying a locale. To rewrite the body of the
  new-login alert, a host adds:

      <host>/priv/phoenix_kit_templates/
      └── new_login_alert/            <- the template name (a directory)
          ├── text.txt                <- <part>.<ext>
          └── text.de.txt             <- <part>.<locale>.<ext>

  `subject` and `text` are `.txt`, `html` is `.html`. That host now has its own
  body in German and a locale-less fallback for everyone else, while the
  subject still comes from core's Gettext default in all seven languages —
  parts resolve independently.

  Roots come from `override_paths/0`. Full rules, including precedence and the
  path-safety constraints on `name`, live in `PhoenixKit.Templates`.

  ## Why the default is a function

  `defaults` is a zero-arity function, not a map, because it is evaluated
  *inside* the recipient's locale — and because layer 1 short-circuits it
  entirely. Passing a map would translate content that a database template is
  about to discard.
  """

  alias PhoenixKit.Config
  alias PhoenixKit.Email.Provider
  alias PhoenixKit.Templates
  alias PhoenixKit.Utils.RecipientLocale

  @typedoc """
  Resolved content plus the database template it came from, if any.

  `db_template` is `nil` on the file/default path and is handed back so the
  caller can record usage against the row it used.
  """
  @type resolved :: %{
          subject: String.t() | nil,
          text: String.t() | nil,
          html: String.t() | nil,
          db_template: map() | nil
        }

  @doc """
  Resolves `name` for `recipient`.

  `recipient` is anything `PhoenixKit.Utils.RecipientLocale` understands — a
  user struct, or a bare email string where no account exists yet. `variables`
  are substituted into whichever layer wins.

  `:locale` overrides the locale resolved from `recipient` — for a caller whose
  recipient is a bare address that carries no preference, such as
  `PhoenixKit.Mailer.send_from_template/4`. `:paths` overrides the override
  roots, which is how a test points at a fixture directory; it defaults to
  `override_paths/0`.
  """
  @spec resolve(String.t(), term(), map(), (-> Templates.defaults()), keyword()) :: resolved()
  def resolve(name, recipient, variables, defaults, opts \\ [])
      when is_binary(name) and is_function(defaults, 0) do
    locale = Keyword.get(opts, :locale) || RecipientLocale.for_rendering(recipient)
    paths = Keyword.get(opts, :paths) || override_paths()

    case Provider.current().get_active_template_by_name(name) do
      nil ->
        rendered =
          Templates.render(name, RecipientLocale.in_locale(locale, defaults), variables,
            locale: locale,
            paths: paths
          )

        Map.put(rendered, :db_template, nil)

      template ->
        rendered = Provider.current().render_template(template, variables, locale)

        %{
          subject: rendered.subject,
          text: rendered.text,
          html: rendered.html_body,
          db_template: template
        }
    end
  end

  @doc """
  Roots searched for host override files, most specific first.

  `config :phoenix_kit, template_paths: [...]` wins; otherwise the host
  application's own `priv/phoenix_kit_templates`. An empty list means core's
  defaults are used verbatim, which is the correct answer for a host that has
  never written an override — and for a mix task running before the host
  application is loaded.
  """
  @spec override_paths() :: [Path.t()]
  def override_paths do
    case Config.get(:template_paths) do
      {:ok, paths} when is_list(paths) -> paths
      _ -> parent_app_paths()
    end
  end

  defp parent_app_paths do
    case Config.get_parent_app() do
      app when is_atom(app) and not is_nil(app) -> app_template_dir(app)
      _ -> []
    end
  end

  # `Application.app_dir/1` raises for an application that is not loaded, which
  # is the normal state inside `mix phoenix_kit.install` — no overrides is the
  # right answer there, not a crash on the way to sending nothing.
  defp app_template_dir(app) do
    [Path.join(Application.app_dir(app), "priv/phoenix_kit_templates")]
  rescue
    ArgumentError -> []
  end
end
