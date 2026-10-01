defmodule PhoenixKit.Email.Catalog do
  @moduledoc """
  The emails the system knows it sends, and a preview of each.

  Core's own emails come from `PhoenixKit.Email.CoreTemplates`; a module adds
  its own through `c:PhoenixKit.Module.email_templates/0`. The admin preview
  (`/admin/settings/email-sending/preview`) lists them and renders each one
  with `preview/3`.

  ## An entry

      %{
        name: "billing_invoice",               # the template name the send uses
        label: "Invoice",                      # shown in the list
        description: "Sent when …",            # optional
        defaults: &MyModule.invoice_defaults/0, # optional, the send's own defaults
        variables: fn -> %{"invoice_number" => "INV-0001"} end, # optional samples
        layout: "billing"                      # optional, the send's :layout option
      }

  `defaults` must be the very function the send passes to
  `PhoenixKit.Mailer.send_from_template/4` (or `Content.resolve/5`), or the
  preview shows copy the reader never gets. `variables` are sample values
  for every placeholder the email uses; a placeholder they leave unbound is
  listed by the preview, so a missing sample is visible rather than silent.
  Both may be a map or a zero-arity function; functions are evaluated in the
  previewed locale.

  An entry whose `name` is not a valid template name (`[a-z0-9][a-z0-9_-]*` —
  a leading `_` is reserved for layout parts) is dropped with a warning, and
  a name already listed (core's first, then modules in registry order) is
  ignored.
  """

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Templates
  alias PhoenixKit.Utils.RecipientLocale

  require Logger

  @name_pattern ~r/\A[a-z0-9][a-z0-9_\-]*\z/

  # Who a previewed message is "sent" to. The locale comes from the preview's
  # own option, so this only has to be something `Content` accepts.
  @preview_recipient "jane.doe@example.com"

  @typedoc "One email the system sends. See the moduledoc."
  @type entry :: %{
          required(:name) => String.t(),
          required(:label) => String.t(),
          optional(:description) => String.t() | nil,
          optional(:defaults) => (-> Templates.defaults()) | Templates.defaults(),
          optional(:variables) => (-> map()) | map(),
          optional(:layout) => boolean() | String.t(),
          optional(:module) => module() | nil
        }

  @typedoc """
  A rendered preview.

    * `content` — subject, text and HTML exactly as a send would build them
      (`t:PhoenixKit.Email.Content.resolved/0`).
    * `sources` — where each part came from (`t:PhoenixKit.Email.Content.sources/0`).
    * `variables` — the sample variables used.
    * `missing` — placeholders the samples leave unbound, by part (empty for a
      database template, which renders through its own provider).
  """
  @type preview :: %{
          content: Content.resolved(),
          sources: Content.sources(),
          variables: map(),
          missing: %{optional(atom()) => [String.t()]}
        }

  @doc """
  Every known email: core's, then each enabled module's.

  Labels are evaluated on the call, so call it in the locale they should
  read in.
  """
  @spec entries() :: [entry()]
  def entries do
    core = Enum.map(CoreTemplates.entries(), &Map.put(&1, :module, nil))

    (core ++ ModuleRegistry.all_email_templates())
    |> Enum.flat_map(&normalize/1)
    |> Enum.uniq_by(& &1.name)
  end

  @doc "The entry named `name`, or `nil`."
  @spec get(String.t()) :: entry() | nil
  def get(name) when is_binary(name), do: Enum.find(entries(), &(&1.name == name))
  def get(_name), do: nil

  @doc """
  Renders `entry` in `locale` with its sample variables, through the same
  resolution a send uses (`Content.resolve_with_sources/5`).

  Returns `{:ok, preview}`, or `{:error, message}` when the entry's own
  `defaults` or `variables` function raises — a module's broken entry must
  not take the preview page down.

  ## Options

    * `:paths` — override roots, as in `Content.resolve/5`.
  """
  @spec preview(entry(), String.t(), keyword()) :: {:ok, preview()} | {:error, String.t()}
  def preview(%{name: name} = entry, locale, opts \\ []) when is_binary(locale) do
    paths = Keyword.get(opts, :paths) || Content.override_paths()
    defaults = defaults_fun(entry)
    variables = RecipientLocale.in_locale(locale, fn -> evaluate(entry[:variables]) end)

    {content, sources} =
      Content.resolve_with_sources(name, @preview_recipient, variables, defaults,
        locale: locale,
        paths: paths,
        layout: Map.get(entry, :layout, true)
      )

    {:ok,
     %{
       content: content,
       sources: sources,
       variables: variables,
       missing: missing(name, content, defaults, variables, locale, paths)
     }}
  rescue
    error ->
      Logger.warning("Email preview of #{inspect(name)} failed: #{Exception.message(error)}")
      {:error, Exception.message(error)}
  catch
    kind, reason ->
      Logger.warning("Email preview of #{inspect(name)} failed: #{inspect({kind, reason})}")
      {:error, inspect(reason)}
  end

  # The placeholders the samples leave unbound, against the same content the
  # render used. Branding is bound on every send, so it is bound here too.
  # A database template renders through its provider, with placeholders of its
  # own; checking the file/default content would report on what was not used.
  defp missing(_name, %{db_template: template}, _defaults, _variables, _locale, _paths)
       when not is_nil(template),
       do: %{}

  defp missing(name, _content, defaults, variables, locale, paths) do
    Templates.missing_variables(
      name,
      RecipientLocale.in_locale(locale, defaults),
      Map.merge(Branding.variables(), variables),
      locale: locale,
      paths: paths
    )
  end

  defp normalize(%{name: name} = entry) when is_binary(name) do
    if Regex.match?(@name_pattern, name) do
      [
        entry
        |> Map.put(:label, label(entry))
        |> Map.put(:description, description(entry))
        |> Map.put_new(:module, nil)
      ]
    else
      Logger.warning(
        "Email catalog entry #{inspect(name)} from #{inspect(entry[:module])} is not a valid " <>
          "template name ([a-z0-9][a-z0-9_-]*); it is not listed"
      )

      []
    end
  end

  defp normalize(entry) do
    Logger.warning("Email catalog entry without a name ignored: #{inspect(entry)}")
    []
  end

  # Both are rendered as text on the preview page; anything else a module
  # hands over would crash the page rather than show.
  defp label(%{label: label}) when is_binary(label) and label != "", do: label
  defp label(%{name: name}), do: name

  defp description(%{description: description}) when is_binary(description), do: description
  defp description(_entry), do: nil

  defp defaults_fun(%{defaults: fun}) when is_function(fun, 0), do: fun
  defp defaults_fun(%{defaults: map}) when is_map(map), do: fn -> map end
  defp defaults_fun(_entry), do: fn -> %{} end

  defp evaluate(fun) when is_function(fun, 0), do: stringify(fun.())
  defp evaluate(map), do: stringify(map)

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_none), do: %{}
end
