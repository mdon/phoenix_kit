defmodule PhoenixKit.Modules.AI.Translation do
  @moduledoc """
  Generic AI translation helper. Translates a `%{field_name => text}`
  map from `source_lang` to `target_lang` using the optional
  `PhoenixKitAI` plugin, and parses the structured response back into
  the same shape.

  Designed to be the single orchestration layer shared by every
  feature module that wants AI translation — `phoenix_kit_publishing`,
  `phoenix_kit_projects`, future consumers. Each module wraps this
  helper in its own Oban worker (or controller action) and owns the
  per-module storage write, broadcasts, caching, and per-resource
  activity log entry.

  ## What lives here

  - Prompt rendering with `{{SourceLanguage}}` / `{{TargetLanguage}}`
    / arbitrary field-name variables.
  - The `PhoenixKitAI.ask_with_prompt/4` call, guarded so absence of
    the plugin returns `{:error, :ai_not_installed}` instead of
    raising.
  - A structured-response parser for the `---FIELD_NAME---` shape
    that publishing's prompt template ships with. Generalised — any
    list of field names is accepted, ordering follows the input.
  - Error normalisation: every failure path returns
    `{:error, atom_or_tuple}` so callers can pattern-match without
    knowing whether the failure came from the plugin, the parser, or
    a network blip.
  - A single core activity-log entry (`core.ai_translation.requested`)
    on every dispatched request — gives Max a unified audit trail of
    AI token spend regardless of which feature module triggered it.
    Modules still log their own per-resource action (e.g.
    `publishing.translation.added`, `projects.translation.added`).

  ## What does NOT live here

  - Storage of the translation result — each consumer owns its own
    write path (publishing's `publishing_content` rows, projects'
    `Project.translations` JSONB, etc.).
  - Broadcasts — each consumer has its own PubSub topic shape.
  - Per-language status (in-flight, completed, errored) — that's the
    consumer's worker and the host UI.
  - Retry policy / queue choice — each consumer's Oban worker picks
    its own queue, max-attempts, and uniqueness constraints. This
    module is a synchronous function-call shape; consumers wrap it.

  ## Usage

      Translation.translate_fields(
        endpoint_uuid,
        prompt_uuid,
        "en",
        "es",
        %{"title" => "Hello", "body" => "World"}
      )
      # => {:ok, %{"title" => "Hola", "body" => "Mundo"}}
      # |  {:error, :ai_not_installed}
      # |  {:error, :no_endpoint}
      # |  {:error, :missing_prompt}
      # |  {:error, {:ai_error, reason}}
      # |  {:error, {:parse_error, reason}}
  """

  alias PhoenixKit.Modules.AI

  # `PhoenixKitAI` is an optional plugin — present at compile time only
  # when the host depends on `:phoenix_kit_ai`. Silence the unknown-MFA
  # warning for the specific call below so core compiles cleanly on hosts
  # that don't have it. Targeting the 3-tuple (instead of the whole
  # module) keeps real typos visible — a misspelled `PhoenixKitAI.asx_with_prompt`
  # still warns.
  @compile {:no_warn_undefined, [{PhoenixKitAI, :ask_with_prompt, 4}]}

  @core_activity_action "core.ai_translation.requested"

  @type field_map :: %{required(String.t()) => String.t()}
  @type translation_result ::
          {:ok, field_map()}
          | {:error,
             :ai_not_installed
             | :no_endpoint
             | :missing_prompt
             | {:ai_error, term()}
             | {:parse_error, term()}}

  @doc """
  Translate `fields` from `source_lang` to `target_lang`.

  - `endpoint_uuid` — UUID of a configured `PhoenixKitAI` endpoint.
    Required even when the plugin is installed; the plugin's prompt
    machinery binds to a specific endpoint at call time.
  - `prompt_uuid` — UUID of a `PhoenixKitAI.Prompt` whose template
    references `{{SourceLanguage}}`, `{{TargetLanguage}}`, and one
    `{{<FieldName>}}` placeholder per key in `fields`.
  - `source_lang` / `target_lang` — language codes (base or dialect;
    the helper passes them through unchanged).
  - `fields` — `%{field_name => text}` map. Field names become the
    structured-response markers (`---<FIELD_NAME>---`, uppercased).

  ## Options

  - `:actor_uuid` — included in the `core.ai_translation.requested`
    activity log entry. When omitted the log is still written with
    `actor_uuid: nil`.
  - `:resource_type` / `:resource_uuid` — let the audit log point at
    the row being translated.
  - `:source` — string identifier for the calling module (e.g.
    `"Publishing.TranslatePostWorker"`); included in the
    `PhoenixKitAI` request log so usage reports break down by caller.
  """
  @spec translate_fields(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          field_map(),
          keyword()
        ) :: translation_result()
  def translate_fields(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts \\ [])
      when is_map(fields) and is_binary(source_lang) and is_binary(target_lang) do
    cond do
      not AI.available?() ->
        {:error, :ai_not_installed}

      not is_binary(endpoint_uuid) or endpoint_uuid == "" ->
        {:error, :no_endpoint}

      not is_binary(prompt_uuid) or prompt_uuid == "" ->
        {:error, :missing_prompt}

      true ->
        do_translate(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts)
    end
  end

  defp do_translate(endpoint_uuid, prompt_uuid, source_lang, target_lang, fields, opts) do
    variables =
      fields
      |> Enum.reduce(%{}, fn {name, value}, acc ->
        Map.put(acc, variable_key(name), value)
      end)
      |> Map.merge(%{
        "SourceLanguage" => source_lang,
        "TargetLanguage" => target_lang
      })

    ai_opts =
      opts
      |> Keyword.take([:source])
      |> Keyword.put_new(:source, "PhoenixKit.Modules.AI.Translation")

    log_request(source_lang, target_lang, Map.keys(fields), opts)

    case PhoenixKitAI.ask_with_prompt(endpoint_uuid, prompt_uuid, variables, ai_opts) do
      {:ok, response} ->
        parse_response(response, Map.keys(fields))

      {:error, reason} ->
        {:error, {:ai_error, reason}}
    end
  end

  # Variable names in `PhoenixKitAI.Prompt` templates are case-insensitive
  # by convention but the publishing translation prompt uses TitleCase for
  # the language slots and the field's original casing for everything else.
  # Pass field names through unchanged so existing prompts keep working.
  defp variable_key(name) when is_binary(name), do: name
  defp variable_key(name), do: to_string(name)

  @doc """
  Parses a structured `---FIELD_NAME---` response into a field map.

  Public for testing — consumers normally hit `translate_fields/6`,
  which calls this internally. Useful when a caller already has the
  raw AI response (e.g. a previously cached completion) and just
  needs to extract field values.

  Field names are matched case-insensitively against the markers but
  the returned map preserves the input casing of `fields` so callers
  can round-trip with their original field-name strings.

  When a marker is missing from the response the field is omitted
  from the result (rather than nil-padded). Callers should treat a
  missing key as "model didn't return this field" and fall back to
  the source value as appropriate.

      iex> Translation.parse_response(
      ...>   "---TITLE---\\nHola\\n---BODY---\\nMundo",
      ...>   ["title", "body"]
      ...> )
      {:ok, %{"title" => "Hola", "body" => "Mundo"}}

      iex> Translation.parse_response(":shrug:", ["title"])
      {:error, {:parse_error, :no_markers}}
  """
  @spec parse_response(String.t(), [String.t()]) ::
          {:ok, field_map()} | {:error, {:parse_error, term()}}
  def parse_response(response, field_names) when is_binary(response) and is_list(field_names) do
    upcased = Enum.map(field_names, &{&1, marker(&1)})
    body = String.trim(response)

    parsed =
      Enum.reduce(upcased, %{}, fn {name, marker}, acc ->
        case extract_section(body, marker, upcased) do
          nil -> acc
          value -> Map.put(acc, name, value)
        end
      end)

    if map_size(parsed) == 0 do
      {:error, {:parse_error, :no_markers}}
    else
      {:ok, parsed}
    end
  end

  defp marker(field) when is_binary(field) do
    field |> String.upcase() |> String.replace(~r/[^A-Z0-9]+/, "_")
  end

  # Pulls the text between `---MARKER---` and the next `---OTHER---`
  # marker (or end-of-string). Returns nil when the marker isn't
  # present.
  defp extract_section(body, marker, all_markers) do
    others = for {_, m} <- all_markers, m != marker, do: Regex.escape(m)
    boundary = if others == [], do: ~s|\\z|, else: "---(?:#{Enum.join(others, "|")})---"
    pattern = ~r/---#{Regex.escape(marker)}---\s*\n?(.+?)(?=#{boundary}|\z)/s

    case Regex.run(pattern, body) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end

  # Writes one `core.ai_translation.requested` audit entry per dispatched
  # request. The host's worker also logs its own per-resource action
  # (e.g. `publishing.translation.added`); this entry is the unified
  # token-spend audit trail.
  #
  # If `PhoenixKit.Activity` isn't loaded (host has the module disabled)
  # the log is skipped silently. Beyond that we let `Activity.log/1`
  # failures propagate — a DB-level problem here is the same bug we'd
  # want to see in any other log site, and the caller (an Oban worker
  # in every documented consumer) owns retry policy.
  defp log_request(source_lang, target_lang, field_names, opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) and
         function_exported?(PhoenixKit.Activity, :log, 1) do
      PhoenixKit.Activity.log(%{
        action: @core_activity_action,
        module: "ai",
        mode: "auto",
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type, "ai_translation"),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        metadata: %{
          "source_lang" => source_lang,
          "target_lang" => target_lang,
          "field_count" => length(field_names),
          "fields" => field_names
        }
      })
    end
  end
end
