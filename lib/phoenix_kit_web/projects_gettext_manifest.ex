defmodule PhoenixKitWeb.ProjectsGettextManifest do
  @moduledoc false

  # Lists translatable strings used by `phoenix_kit_projects` that route via
  # the shared `PhoenixKitWeb.Gettext` backend (the "common" bucket per the
  # hybrid gettext convention — date/month formatting helpers in
  # `PhoenixKitProjects.L10n` and generic table chrome in
  # `PhoenixKitProjects.Web.Components.SortableTable`).
  #
  # Projects-domain-specific strings stay in `phoenix_kit_projects`' own
  # `PhoenixKitProjects.Gettext` backend; this manifest only mirrors the
  # subset that's deliberately shared workspace-wide.
  #
  # See `phoenix_kit_projects/dev_docs/i18n_triage.md` for the per-file
  # bucket assignments and `legal_gettext_manifest.ex` for the same pattern
  # applied to `phoenix_kit_legal`.
  #
  # ## Refreshing the list
  #
  # Run from a `phoenix_kit_projects` checkout to confirm the current set:
  #
  #     grep -hEo 'gettext\("[^"]+' \
  #       lib/phoenix_kit_projects/l10n.ex \
  #       lib/phoenix_kit_projects/web/components/sortable_table.ex \
  #     | sort -u
  #
  # This module is never called at runtime — it exists purely as an
  # extraction target for `mix gettext.extract`.

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc false
  def __extract__ do
    [
      # Month abbreviations (PhoenixKitProjects.L10n.short_month/1).
      gettext("Jan"),
      gettext("Feb"),
      gettext("Mar"),
      gettext("Apr"),
      gettext("May"),
      gettext("Jun"),
      gettext("Jul"),
      gettext("Aug"),
      gettext("Sep"),
      gettext("Oct"),
      gettext("Nov"),
      gettext("Dec"),
      # Date/time format templates (PhoenixKitProjects.L10n).
      gettext("%{month} %{day}, %{year}", month: "", day: "", year: ""),
      gettext("%{month} %{day}, %{year} at %{time}", month: "", day: "", year: "", time: ""),
      gettext("%{month} %{day} %{time}", month: "", day: "", time: ""),
      # Generic table chrome
      # (PhoenixKitProjects.Web.Components.SortableTable column headers).
      gettext("Title")
    ]
  end
end
