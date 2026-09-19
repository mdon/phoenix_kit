defmodule PhoenixKit.Modules.Storage.FileDetails do
  @moduledoc """
  A media file's translatable details: title, alt text and description.

  Not a table. The three live on the file row in two places, and this module
  is the one read and write path for both:

    * the **primary-language** text sits in `metadata` under `"title"`,
      `"alt"` and `"description"` — where the media UI has always kept the
      title and description, next to rotation, tags and the EXIF/PDF keys
    * the **translations** sit in the `data` column (V199) as the
      `PhoenixKit.Utils.Multilang` structure, keyed `"_title"`, `"_alt"`,
      `"_description"` per language. Its primary-language entry is a copy of
      the `metadata` text, refreshed on every save

  `metadata` cannot hold the multilang structure itself: the structure takes
  over the map it is written to, and `metadata["rotation"]` and friends are
  read at the top level.

  ## Reading

      FileDetails.translated_alt(file, "et")      # "" when there is none
      FileDetails.translated_title(file, "et")    # nil when there is none
      FileDetails.for_locale(file, "et")          # all three

  A language with no translation of its own falls back to the primary
  text. The alt text never falls back to the file name: a file name read
  aloud helps nobody, and `alt=""` correctly marks the image as undescribed.

  ## Writing

  The struct is the form's data — it has the shape
  `PhoenixKitWeb.Components.MultilangForm` expects (the primary text as
  fields, the translations in `:data`):

      changeset = Storage.change_file_details(file)
      Storage.update_file_details(file, params)
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Utils.Multilang

  @fields ~w(title alt description)
  @max_length %{"title" => 255, "alt" => 500, "description" => 5000}
  @primary_language_key "_primary_language"

  @type t :: %__MODULE__{
          title: String.t() | nil,
          alt: String.t() | nil,
          description: String.t() | nil,
          data: map()
        }

  @primary_key false
  embedded_schema do
    field :title, :string
    field :alt, :string
    field :description, :string
    field :data, :map, default: %{}
  end

  @doc "The translatable field names, as `MultilangForm.merge_translatable_params/4` takes them."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc "The details a file row currently holds."
  @spec from_file(File.t()) :: t()
  def from_file(%File{} = file) do
    metadata = file.metadata || %{}

    %__MODULE__{
      title: text(metadata["title"]),
      alt: text(metadata["alt"]),
      description: text(metadata["description"]),
      data: file.data || %{}
    }
  end

  @doc """
  Changeset for the details form. `attrs` holds the primary text under
  `"title"`, `"alt"` and `"description"`, and optionally the multilang
  `"data"`. A key that is absent keeps its current value.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = details, attrs) do
    details
    |> cast(attrs, [:title, :alt, :description, :data])
    |> update_change(:title, &clean/1)
    |> update_change(:alt, &clean/1)
    |> update_change(:description, &clean/1)
    |> validate_length(:title, max: @max_length["title"])
    |> validate_length(:alt, max: @max_length["alt"])
    |> validate_length(:description, max: @max_length["description"])
    |> update_change(:data, &sanitize_data/1)
    |> validate_translation_lengths()
    |> sync_primary_entry()
  end

  @doc """
  The `File.details_changeset/2` attrs that store `details` on `file`.
  The three text keys are merged into the file's current `metadata`; every
  other key there is kept. A cleared field is stored as `""`, not removed —
  the PDF processor fills a *missing* `"title"` from the document, and a
  title the user cleared must stay cleared.
  """
  @spec file_attrs(File.t(), t()) :: %{metadata: map(), data: map()}
  def file_attrs(%File{} = file, %__MODULE__{} = details) do
    metadata =
      Enum.reduce(@fields, file.metadata || %{}, fn field, acc ->
        Map.put(acc, field, Map.fetch!(details, String.to_existing_atom(field)) || "")
      end)

    %{metadata: metadata, data: details.data || %{}}
  end

  # ── Reading ───────────────────────────────────────────────────

  @doc """
  One detail of `file` in `locale`: the language's own translation, else the
  primary-language text, else `nil`. A `nil` locale reads the primary text.
  """
  @spec translated(File.t(), String.t(), String.t() | nil) :: String.t() | nil
  def translated(%File{} = file, field, locale) when field in @fields do
    translation(file.data, field, locale) || text((file.metadata || %{})[field])
  end

  @doc "The title in `locale`, or `nil`."
  @spec translated_title(File.t(), String.t() | nil) :: String.t() | nil
  def translated_title(file, locale \\ nil), do: translated(file, "title", locale)

  @doc "The description in `locale`, or `nil`."
  @spec translated_description(File.t(), String.t() | nil) :: String.t() | nil
  def translated_description(file, locale \\ nil), do: translated(file, "description", locale)

  @doc """
  The alt text in `locale`, ready for an `alt` attribute: `""` when the file
  has none. Never the file name.
  """
  @spec translated_alt(File.t(), String.t() | nil) :: String.t()
  def translated_alt(file, locale \\ nil), do: translated(file, "alt", locale) || ""

  @doc "All three details of `file` in `locale`."
  @spec for_locale(File.t(), String.t() | nil) :: %{
          title: String.t() | nil,
          alt: String.t(),
          description: String.t() | nil
        }
  def for_locale(%File{} = file, locale \\ nil) do
    %{
      title: translated_title(file, locale),
      alt: translated_alt(file, locale),
      description: translated_description(file, locale)
    }
  end

  defp translation(_data, _field, nil), do: nil

  defp translation(data, field, locale) when is_binary(locale) do
    if Multilang.multilang_data?(data) do
      data |> Multilang.get_raw_language_data(locale) |> Map.get("_" <> field) |> text()
    end
  end

  defp translation(_data, _field, _locale), do: nil

  # ── Changeset internals ───────────────────────────────────────

  # Only what this module owns survives: the primary-language marker, and
  # per language the three `_`-prefixed keys as cleaned, non-blank strings.
  # The map arrives from a form, so anything else in it is not ours to store.
  defp sanitize_data(data) when is_map(data) do
    Enum.reduce(data, %{}, fn
      {@primary_language_key, lang}, acc when is_binary(lang) ->
        Map.put(acc, @primary_language_key, clean(lang))

      {lang, %{} = entry}, acc when is_binary(lang) ->
        Map.put(acc, clean(lang), sanitize_entry(entry))

      _other, acc ->
        acc
    end)
  end

  defp sanitize_data(_), do: %{}

  defp sanitize_entry(entry) do
    for field <- @fields,
        value = text(entry["_" <> field]),
        into: %{},
        do: {"_" <> field, value}
  end

  defp validate_translation_lengths(changeset) do
    too_long? =
      changeset
      |> get_field(:data)
      |> Kernel.||(%{})
      |> Enum.any?(fn
        {_lang, %{} = entry} ->
          Enum.any?(@fields, fn field ->
            String.length(entry["_" <> field] || "") > @max_length[field]
          end)

        _ ->
          false
      end)

    if too_long?,
      do: add_error(changeset, :data, "a translation is too long"),
      else: changeset
  end

  # The multilang structure's primary entry is a copy of the primary text;
  # a save made with multilang off (no "data" in the params) would otherwise
  # leave it stale, and the primary language would read the old text back.
  defp sync_primary_entry(changeset) do
    data = get_field(changeset, :data) || %{}

    case data do
      %{@primary_language_key => primary} when is_binary(primary) ->
        entry =
          for field <- @fields,
              value = text(get_field(changeset, String.to_existing_atom(field))),
              into: %{},
              do: {"_" <> field, value}

        put_change(changeset, :data, Map.put(data, primary, entry))

      _ ->
        changeset
    end
  end

  # Postgres rejects null bytes in text and jsonb.
  defp clean(value) when is_binary(value),
    do: value |> String.replace("\x00", "") |> String.trim()

  defp clean(value), do: value

  # A cleaned, non-blank string, or nil.
  defp text(value) when is_binary(value) do
    case clean(value) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp text(_), do: nil
end
