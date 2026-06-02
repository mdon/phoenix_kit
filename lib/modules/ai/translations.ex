defmodule PhoenixKit.Modules.AI.Translations do
  @moduledoc """
  Core orchestration for AI-driven translation — the shared layer every
  feature module enqueues against instead of re-implementing its own
  context + worker.

  Pairs with:

  - `PhoenixKit.Modules.AI.Translation` — the engine (the AI call + parse).
  - `PhoenixKit.Modules.AI.Translatable` — the per-module adapter behaviour.
  - `PhoenixKit.Modules.AI.TranslateWorker` — the generic Oban worker this
    module enqueues.

  ## What a consumer does

  1. Implement a `Translatable` adapter and register it via
     `ai_translatables/0` on its `PhoenixKit.Module`.
  2. From a form LV: `subscribe/1`, then on a button click call
     `enqueue/1` (or `enqueue_all_missing/2`), and react to the
     `{:ai_translation, event, payload}` messages.

  Everything else — the AI call, parsing, persistence (via the adapter),
  retry policy, broadcasts, and the unified audit log — is shared.

  ## Status messages

  The worker broadcasts `{:ai_translation, event, payload}` where `event`
  is `:translation_started | :translation_completed | :translation_failed`.
  `payload` always has `:resource_type`, `:resource_uuid`, `:source_lang`,
  `:target_lang`. `:translation_completed` adds `:fields` (the translated
  `%{field => text}` map, possibly empty); `:translation_failed` adds
  `:reason`.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.AI.TranslateWorker
  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings

  # Job states that mean "already covered" for de-dup. Deliberately excludes
  # `:suspended` — it's missing from the `oban_job_state` enum on some hosts
  # and referencing it in a query raises `22P02` (see TranslateWorker docs).
  @incomplete_states ~w(available scheduled executing retryable)

  @endpoint_setting_key "ai_translation_endpoint_uuid"
  @prompt_setting_key "ai_translation_prompt_uuid"
  # `PhoenixKitAI` derives a prompt's slug from its name (`Slug.slugify/1`,
  # overriding any passed `:slug`), so the slug here MUST equal
  # `slugify(@prompt_name)` or the idempotency lookup never matches and every
  # `ensure_default_prompt/0` re-attempts the create.
  @prompt_name "PhoenixKit Translate Content"
  @prompt_slug "phoenixkit-translate-content"
  @topic "phoenix_kit:ai_translation"

  # `PhoenixKitAI` is an optional plugin — guard MFAs so core compiles +
  # runs on hosts without it.
  @compile {:no_warn_undefined,
            [
              {PhoenixKitAI, :enabled?, 0},
              {PhoenixKitAI, :list_endpoints, 1},
              {PhoenixKitAI, :list_prompts, 1},
              {PhoenixKitAI, :get_prompt_by_slug, 1},
              {PhoenixKitAI, :create_prompt, 1},
              {PhoenixKitAI, :create_prompt, 2}
            ]}

  # ── Availability + configuration ─────────────────────────────────

  @doc """
  Is AI translation usable right now? `PhoenixKitAI` loaded + enabled +
  at least one enabled endpoint configured. Hosts gate the UI on this.
  """
  @spec available?() :: boolean()
  def available? do
    AI.available?() and
      safe_ai(fn -> PhoenixKitAI.enabled?() end, false) and
      list_endpoints() != []
  end

  @doc "Configured AI endpoints as `[{uuid, name}]`. Empty when unavailable."
  @spec list_endpoints() :: [{String.t(), String.t()}]
  def list_endpoints do
    safe_ai(
      fn ->
        if PhoenixKitAI.enabled?() do
          {endpoints, _} = PhoenixKitAI.list_endpoints(enabled: true)
          Enum.map(endpoints, &{&1.uuid, &1.name})
        else
          []
        end
      end,
      []
    )
  end

  @doc "Configured AI prompts as `[{uuid, name}]`. Empty when unavailable."
  @spec list_prompts() :: [{String.t(), String.t()}]
  def list_prompts do
    safe_ai(
      fn ->
        if PhoenixKitAI.enabled?() do
          case PhoenixKitAI.list_prompts(enabled: true) do
            {prompts, _} -> Enum.map(prompts, &{&1.uuid, &1.name})
            prompts when is_list(prompts) -> Enum.map(prompts, &{&1.uuid, &1.name})
          end
        else
          []
        end
      end,
      []
    )
  end

  @doc "Default endpoint UUID: the `#{@endpoint_setting_key}` setting, else the first enabled endpoint, else nil."
  @spec default_endpoint_uuid() :: String.t() | nil
  def default_endpoint_uuid do
    case blank_to_nil(Settings.get_setting(@endpoint_setting_key)) do
      nil ->
        case list_endpoints() do
          [{uuid, _name} | _] -> uuid
          [] -> nil
        end

      uuid ->
        uuid
    end
  end

  @doc "Default prompt UUID: the `#{@prompt_setting_key}` setting, else the shared `#{@prompt_slug}` prompt, else nil."
  @spec default_prompt_uuid() :: String.t() | nil
  def default_prompt_uuid do
    case blank_to_nil(Settings.get_setting(@prompt_setting_key)) do
      nil -> shared_prompt_uuid()
      uuid -> uuid
    end
  end

  defp shared_prompt_uuid do
    safe_ai(
      fn ->
        case PhoenixKitAI.get_prompt_by_slug(@prompt_slug) do
          nil -> nil
          prompt -> prompt.uuid
        end
      end,
      nil
    )
  end

  @doc """
  Idempotently provision the shared translation prompt. Returns
  `{:ok, prompt}` (existing or freshly created) or `{:error, reason}`.
  `{:error, :ai_not_installed}` when the plugin is unavailable.
  """
  @spec ensure_default_prompt() :: {:ok, struct()} | {:error, term()}
  def ensure_default_prompt do
    if AI.available?() do
      safe_ai(fn -> do_ensure_prompt() end, {:error, :ai_not_installed})
    else
      {:error, :ai_not_installed}
    end
  end

  defp do_ensure_prompt do
    case PhoenixKitAI.get_prompt_by_slug(@prompt_slug) do
      nil ->
        case PhoenixKitAI.create_prompt(default_prompt_attrs()) do
          {:ok, prompt} ->
            {:ok, prompt}

          # Lost a create race (or the slug/name was taken concurrently) —
          # re-read by slug. Since @prompt_slug == slugify(@prompt_name), the
          # row the racing caller inserted is now findable.
          {:error, %Ecto.Changeset{}} ->
            case PhoenixKitAI.get_prompt_by_slug(@prompt_slug) do
              nil -> {:error, :prompt_unavailable}
              prompt -> {:ok, prompt}
            end
        end

      prompt ->
        {:ok, prompt}
    end
  end

  # The SOURCE block enumerates the common translatable field names across
  # PhoenixKit modules (name/title/description/summary/body/content). The
  # engine binds only the fields an adapter actually provides; any unbound
  # `{{placeholder}}` stays literal in the rendered prompt and the RULES tell
  # the model to skip it, and only requested fields are parsed back. An
  # adapter whose `source_fields/2` returns a field name NOT listed here must
  # supply its own prompt (pass `prompt_uuid`) — its value would otherwise
  # never reach the model and the parse would report a missing field.
  defp default_prompt_attrs do
    %{
      slug: @prompt_slug,
      name: @prompt_name,
      description: "Shared PhoenixKit prompt for translating resource fields between languages.",
      content: """
      You are translating fields of a content resource from {{SourceLanguage}} to {{TargetLanguage}}.

      RULES:
      - Preserve formatting exactly (line breaks, spacing, Markdown if present).
      - Do NOT translate text inside code blocks, inline code, or URLs.
      - Translate naturally and idiomatically — match the tone of the source.
      - Keep any HTML tags and special syntax unchanged.
      - Output ONLY the structured markers below — no commentary, no preface, no closing remarks.

      OUTPUT FORMAT — for each non-empty field in the SOURCE section below,
      emit ONE marker named after the field (uppercased), followed by the
      translation:

          ---<FIELD_NAME_UPPERCASE>---
          [translated value]

      Example:

          ---NAME---
          <translated name>

          ---DESCRIPTION---
          <translated description>

      Skip any field that is missing, blank, or still a literal placeholder
      (e.g. a value that looks like `{{title}}` means the caller did not bind
      it) — do NOT emit a marker for it, and do NOT translate the placeholder
      text itself.

      === SOURCE ===

      Name: {{name}}

      Title: {{title}}

      Summary: {{summary}}

      Description: {{description}}

      Body: {{body}}

      Content: {{content}}
      """
    }
  end

  # ── PubSub ───────────────────────────────────────────────────────

  @doc "The global AI-translation status topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Per-resource AI-translation status topic."
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(resource_type, resource_uuid)
      when is_binary(resource_type) and is_binary(resource_uuid),
      do: "#{@topic}:#{resource_type}:#{resource_uuid}"

  @doc "Subscribe to the global translation topic."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSubManager.subscribe(@topic)

  @doc "Subscribe to a single resource's translation topic."
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(resource_type, resource_uuid),
    do: PubSubManager.subscribe(topic(resource_type, resource_uuid))

  @doc false
  # Called by `TranslateWorker` to fan an event out on the global topic,
  # the per-resource topic, and any adapter-supplied topics.
  def broadcast(event, payload, extra_topics \\ []) do
    msg = {:ai_translation, event, payload}
    PubSubManager.broadcast(@topic, msg)

    with %{resource_type: t, resource_uuid: u} when is_binary(t) and is_binary(u) <- payload do
      PubSubManager.broadcast(topic(t, u), msg)
    end

    Enum.each(extra_topics, &PubSubManager.broadcast(&1, msg))
    :ok
  end

  # ── Missing-language helper ──────────────────────────────────────

  @doc """
  Given the enabled base language codes, the primary code, and the langs
  that already have a translation, return the still-missing base codes
  (primary excluded — it's the source, never a target).
  """
  @spec missing_languages([String.t()], String.t(), [String.t()]) :: [String.t()]
  def missing_languages(enabled_codes, primary_code, existing_langs)
      when is_list(enabled_codes) and is_list(existing_langs) do
    existing = MapSet.new(existing_langs)

    Enum.filter(enabled_codes, fn code ->
      code != primary_code and not MapSet.member?(existing, code)
    end)
  end

  # ── Enqueue ──────────────────────────────────────────────────────

  @type enqueue_params :: %{
          required(:resource_type) => String.t(),
          required(:resource_uuid) => String.t(),
          required(:endpoint_uuid) => String.t(),
          required(:prompt_uuid) => String.t(),
          required(:source_lang) => String.t(),
          required(:target_lang) => String.t(),
          optional(:actor_uuid) => String.t() | nil
        }

  @doc """
  Enqueue one translation job for a single `(resource, target_lang)`.

  Returns `{:ok, %{conflict?: boolean}}` (`conflict?: true` when an
  identical job is already in flight) or `{:error, reason}` on a malformed
  input map.
  """
  @spec enqueue(map()) :: {:ok, %{conflict?: boolean()}} | {:error, term()}
  def enqueue(%{} = params) do
    with :ok <- validate(params, full_required()) do
      if job_in_flight?(params) do
        {:ok, %{conflict?: true}}
      else
        case params |> to_args() |> TranslateWorker.new() |> Oban.insert() do
          {:ok, _job} -> {:ok, %{conflict?: false}}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def enqueue(_other), do: {:error, {:invalid, :not_a_map}}

  # App-level uniqueness: is there already a non-terminal TranslateWorker job
  # for this (resource_type, resource_uuid, target_lang)? Fails open (returns
  # false → proceed with insert) on any query error.
  defp job_in_flight?(params) do
    repo = PhoenixKit.RepoHelper.repo()
    type = value_for(params, :resource_type)
    uuid = value_for(params, :resource_uuid)
    target = value_for(params, :target_lang)

    query =
      from(j in "oban_jobs",
        where: j.worker == "PhoenixKit.Modules.AI.TranslateWorker",
        where: j.state in ^@incomplete_states,
        where: fragment("?->>'resource_type' = ?", j.args, ^type),
        where: fragment("?->>'resource_uuid' = ?", j.args, ^uuid),
        where: fragment("?->>'target_lang' = ?", j.args, ^target)
      )

    repo.exists?(query)
  rescue
    _ -> false
  end

  @doc """
  Enqueue one job per missing target language. `base_params` is
  `enqueue_params` minus `:target_lang`. Returns
  `{:ok, %{enqueued, conflicts, errors, in_flight}}` — `in_flight` is the
  langs a host should mark spinning (newly enqueued + conflicts; never the
  errored ones, since no broadcast will arrive to clear them).
  """
  @spec enqueue_all_missing(map(), [String.t()]) ::
          {:ok,
           %{
             enqueued: non_neg_integer(),
             conflicts: non_neg_integer(),
             errors: [{String.t(), term()}],
             in_flight: [String.t()]
           }}
          | {:error, term()}
  def enqueue_all_missing(%{} = base_params, missing_langs) when is_list(missing_langs) do
    case validate(Map.drop(base_params, [:target_lang]), partial_required()) do
      :ok ->
        results =
          Enum.map(missing_langs, fn lang ->
            {lang, base_params |> Map.put(:target_lang, lang) |> enqueue()}
          end)

        enqueued = for {lang, {:ok, %{conflict?: false}}} <- results, do: lang
        conflicts = for {lang, {:ok, %{conflict?: true}}} <- results, do: lang
        errors = for {lang, {:error, reason}} <- results, do: {lang, reason}

        {:ok,
         %{
           enqueued: length(enqueued),
           conflicts: length(conflicts),
           errors: errors,
           in_flight: enqueued ++ conflicts
         }}

      {:error, _} = err ->
        err
    end
  end

  def enqueue_all_missing(_base, _langs), do: {:error, {:invalid, :bad_arguments}}

  defp full_required,
    do: [:resource_type, :resource_uuid, :endpoint_uuid, :prompt_uuid, :source_lang, :target_lang]

  defp partial_required,
    do: [:resource_type, :resource_uuid, :endpoint_uuid, :prompt_uuid, :source_lang]

  defp validate(params, required) do
    missing = for key <- required, blank?(value_for(params, key)), do: key

    bad_uuids =
      for key <- [:resource_uuid, :endpoint_uuid, :prompt_uuid],
          value = value_for(params, key),
          is_binary(value),
          not blank?(value),
          Ecto.UUID.cast(value) == :error,
          do: key

    cond do
      missing != [] -> {:error, {:invalid, missing}}
      bad_uuids != [] -> {:error, {:invalid_uuids, bad_uuids}}
      true -> :ok
    end
  end

  defp value_for(params, key) when is_atom(key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_), do: nil

  defp to_args(params) do
    %{
      "resource_type" => value_for(params, :resource_type),
      "resource_uuid" => value_for(params, :resource_uuid),
      "endpoint_uuid" => value_for(params, :endpoint_uuid),
      "prompt_uuid" => value_for(params, :prompt_uuid),
      "source_lang" => value_for(params, :source_lang),
      "target_lang" => value_for(params, :target_lang),
      "actor_uuid" => value_for(params, :actor_uuid)
    }
  end

  # Plugin-boundary fuse: an absent/broken optional plugin must not crash
  # the caller. Narrow rescue for the shapes a missing/incompatible plugin
  # raises; broad catch for the arbitrary GenServer tree underneath.
  defp safe_ai(fun, default) do
    fun.()
  rescue
    UndefinedFunctionError -> default
    FunctionClauseError -> default
    ArgumentError -> default
  catch
    :exit, _ -> default
    :throw, _ -> default
  end
end
