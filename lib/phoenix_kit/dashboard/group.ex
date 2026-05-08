defmodule PhoenixKit.Dashboard.Group do
  @moduledoc """
  Struct representing a dashboard tab group.

  Groups organize tabs in the dashboard sidebar. Each group has an ID,
  an optional label, and a priority for ordering.

  ## Fields

  - `id` - Unique group identifier atom (e.g., `:admin_main`, `:shop`)
  - `label` - Optional display label (nil for unlabeled groups)
  - `priority` - Sort priority (lower = first, default: 100)
  - `icon` - Optional heroicon name (e.g., `"hero-cube"`)
  - `collapsible` - Whether the group can be collapsed in the sidebar
  - `gettext_backend` - Optional Gettext backend module for label translation (default: nil)
  - `gettext_domain` - Gettext domain for translation lookups (default: "default")
  """

  @enforce_keys [:id]
  defstruct [
    :id,
    :label,
    :icon,
    :gettext_backend,
    priority: 100,
    collapsible: false,
    gettext_domain: "default"
  ]

  @type t :: %__MODULE__{
          id: atom(),
          label: String.t() | nil,
          priority: integer(),
          icon: String.t() | nil,
          collapsible: boolean(),
          gettext_backend: module() | nil,
          gettext_domain: String.t()
        }

  @doc """
  Returns the group's label, translated via the configured gettext backend if one is set.

  Falls back to the raw label string when:
    * `gettext_backend` is `nil` (default — no translation configured)
    * the label is `nil` (unlabeled groups)
    * gettext has no translation for the msgid (gettext's own fallback)
  """
  @spec localized_label(t()) :: String.t() | nil
  def localized_label(%__MODULE__{label: nil}), do: nil
  def localized_label(%__MODULE__{gettext_backend: nil, label: label}), do: label

  def localized_label(%__MODULE__{gettext_backend: backend, gettext_domain: domain, label: label}),
    do: Gettext.dgettext(backend, domain, label)

  @doc """
  Creates a new group from a map or keyword list.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: attrs[:id] || attrs["id"],
      label: attrs[:label] || attrs["label"],
      priority: attrs[:priority] || attrs["priority"] || 100,
      icon: attrs[:icon] || attrs["icon"],
      collapsible: attrs[:collapsible] || attrs["collapsible"] || false,
      gettext_backend: attrs[:gettext_backend] || attrs["gettext_backend"],
      gettext_domain: attrs[:gettext_domain] || attrs["gettext_domain"] || "default"
    }
  end

  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      label: Keyword.get(attrs, :label),
      priority: Keyword.get(attrs, :priority, 100),
      icon: Keyword.get(attrs, :icon),
      collapsible: Keyword.get(attrs, :collapsible, false),
      gettext_backend: Keyword.get(attrs, :gettext_backend),
      gettext_domain: Keyword.get(attrs, :gettext_domain, "default")
    }
  end
end
