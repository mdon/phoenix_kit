defmodule PhoenixKitWeb.Live.Settings.Integrations do
  @moduledoc """
  Integrations list page — shows all configured service connections.

  Each connection is displayed as a card with status, connected account info,
  and quick actions (disconnect, test). An "Add Integration" button links to
  the form page for creating new connections.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  # Imported per-LiveView rather than from `PhoenixKitWeb, :live_view`: a host
  # app that defines its own `row_link/1` would get an ambiguous import the
  # moment core wired this one in project-wide.
  import PhoenixKitWeb.Components.Core.RowLink, only: [row_link: 1]

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Encryption
  alias PhoenixKit.Integrations.Events
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe()

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, gettext("Integrations"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> load_connections()
      |> assign(:validating, nil)

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  def handle_event("disconnect", %{"uuid" => uuid}, socket) do
    Integrations.disconnect(uuid, actor_uuid(socket), owner: :system)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Disconnected"))
     |> load_connections()}
  end

  def handle_event("validate_connection", %{"uuid" => uuid}, socket) do
    send(self(), {:do_validate, uuid})
    {:noreply, assign(socket, :validating, uuid)}
  end

  def handle_event("remove_connection", %{"uuid" => uuid}, socket) do
    case Integrations.remove_connection(uuid, actor_uuid(socket), owner: :system) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Connection removed"))
         |> load_connections()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove connection"))}
    end
  end

  # ---------------------------------------------------------------------------
  # Async validation
  # ---------------------------------------------------------------------------

  def handle_info({:do_validate, uuid}, socket) do
    actor = actor_uuid(socket)
    result = Integrations.validate_connection(uuid, actor, owner: :system)
    Integrations.record_validation(uuid, result, owner: :system)

    {:noreply,
     socket
     |> assign(:validating, nil)
     |> load_connections()}
  end

  # ---------------------------------------------------------------------------
  # PubSub handlers
  # ---------------------------------------------------------------------------

  def handle_info({:integration_setup_saved, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connected, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_disconnected, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_validated, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_added, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_removed, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  def handle_info({:integration_connection_renamed, _, _, _}, socket),
    do: {:noreply, load_connections(socket)}

  # Catch-all to prevent crashes from unexpected messages
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_connections(socket) do
    # Recomputed on every reload (mount AND every PubSub-triggered refresh
    # below), not just once at mount — this is a long-lived LiveView, and an
    # admin who rotates the key / flips integration_encryption_enabled while
    # the page is open should see the banner update on the next connection
    # event rather than only after a fresh page load. `status/0` is a pure
    # config read (see its own doc), so recomputing it here is free.
    # ONE report per render. This used to be three separate calls —
    # `status/0`, `key_diagnosis/0`, `key_fingerprint/0` — each re-resolving the
    # key independently, and a key store that answers one read and fails the
    # next could hand the three of them different answers for the same page.
    report = Encryption.key_report()

    socket =
      socket
      |> assign(:encryption_report, report)
      |> assign(:encryption_fingerprint, encryption_fingerprint(report))

    # System page: only providers usable system-wide, and only SYSTEM-owned
    # connections (owner: :system) — a user's personal connection never leaks here.
    providers = Providers.for_scope(:system)
    provider_keys = Enum.map(providers, & &1.key)
    providers_by_key = Map.new(providers, &{&1.key, &1})

    # Single query for all providers instead of N+1
    all_connections = Integrations.load_all_connections(provider_keys, owner: :system)

    connections =
      Enum.flat_map(providers, fn provider ->
        Map.get(all_connections, provider.key, [])
        |> Enum.map(fn %{uuid: uuid, name: name, data: data} ->
          %{
            provider: providers_by_key[provider.key],
            uuid: uuid,
            name: name,
            data: data
          }
        end)
      end)

    socket
    |> assign(:connections, connections)
    |> assign(:provider_names, join_with_and(Enum.map(providers, & &1.name)))
  end

  # Joins a list of names with commas, using a translated "and" before
  # the final item: ["A"] → "A", ["A", "B"] → "A and B",
  # ["A", "B", "C"] → "A, B and C". `gettext("and")` is extracted to the
  # .pot so each locale can supply its own conjunction.
  defp join_with_and([]), do: ""
  defp join_with_and([single]), do: single

  defp join_with_and(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " " <> gettext("and") <> " " <> last
  end

  defp actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

  defp get_current_path(locale) do
    Routes.path("/admin/settings/integrations/website", locale: locale)
  end

  defp integration_status_badge("connected"), do: {"badge-success", gettext("Connected")}
  defp integration_status_badge("configured"), do: {"badge-warning", gettext("Not tested")}
  defp integration_status_badge("disconnected"), do: {"badge-ghost", gettext("Not connected")}
  defp integration_status_badge("error"), do: {"badge-error", gettext("Error")}
  defp integration_status_badge(_), do: {"badge-ghost", gettext("Not configured")}

  # Public seams, `@doc false`: the defect these exist against lives in the
  # rendering, and a test that cannot reach the rendering cannot guard it — the
  # same reasoning that made `Mix.Tasks.PhoenixKit.Doctor.integration_key_result/2`
  # public. The template guards the banner on the report's severity, so the
  # healthy `{:dedicated, :ok}` case never reaches these.
  #
  # Keyed on `report.diagnosis`, not on the status alone. Keyed on the status,
  # this page told an operator whose key store is merely UNREADABLE that "no
  # dedicated encryption key is configured" — false, they configured one — and
  # then advised the rotation that would abandon the key their data may be
  # encrypted under.
  #
  # `{:dedicated, :store_unreadable}` gets its own clause ahead of the generic
  # one for the same reason it got its own clause in `Encryption.key_report/1`:
  # without it this page called a working dedicated key a FALLBACK, and — since
  # the banner used to be guarded on `status != :dedicated` — printed that label
  # under no banner at all, so the broken store was never mentioned.
  @doc false
  def encryption_status_title({:dedicated, :store_unreadable}),
    do: gettext("The encryption key is fine, but its key store cannot be read")

  def encryption_status_title({_status, :store_unreadable}),
    do: gettext("The configured encryption key store cannot be read")

  def encryption_status_title({_status, :key_too_short}),
    do: gettext("The configured encryption key was rejected as too short")

  def encryption_status_title({:legacy_secret_key_base, _reason}),
    do: gettext("Credentials are protected only by a shared application secret")

  def encryption_status_title({:disabled_no_key, _reason}),
    do: gettext("Credentials are stored in plain text")

  def encryption_status_title({:disabled_explicit, _reason}),
    do: gettext("Encryption is turned off for integration credentials")

  # Catch-all: the template renders this banner for ANY status other than
  # `:dedicated` (see the guard note above), so a future `key_status/0`
  # value this page hasn't been taught about must degrade to a generic
  # warning instead of a `FunctionClauseError` crashing the settings page.
  def encryption_status_title(_other),
    do: gettext("Integration credential encryption needs attention")

  # Two clauses per fault, because the consequence genuinely differs: with a
  # legacy secret still available the data is merely on a weaker key, with none
  # it is in plain text. Saying "fell back" in the second case is the exact
  # falsehood this module already removed from two other surfaces — and saying
  # it for `{:dedicated, _}` is the same falsehood a third time, since nothing
  # fell back at all there.
  @doc false
  def encryption_status_detail({:dedicated, :store_unreadable}) do
    gettext(
      "Encryption itself is working — the key in use comes from configuration. The configured " <>
        "key store cannot be read, so nothing confirms that key is saved anywhere. Do not " <>
        "rotate until the store reads back: the rotation pre-flight only checks that the " <>
        "store can be written, so it will not stop for this."
    )
  end

  def encryption_status_detail({:disabled_no_key, :store_unreadable}) do
    gettext(
      "A key store is configured but its secret could not be read, and no other key resolves " <>
        "either — credentials below are being written in plain text. Do NOT run " <>
        "mix phoenix_kit.integrations.rotate_key: the stored key may be the one existing " <>
        "credentials are encrypted under. Repair the store first; repairing it later will not " <>
        "make anything written in the meantime readable."
    )
  end

  def encryption_status_detail({_status, :store_unreadable}) do
    gettext(
      "A key store is configured but its secret could not be read, so encryption fell back to " <>
        "a weaker key. Values written under the stored key will not decrypt. Do NOT run " <>
        "mix phoenix_kit.integrations.rotate_key: the stored key may be the one they are " <>
        "encrypted under. Repair the store first; repairing it later will not make anything " <>
        "written in the meantime readable."
    )
  end

  def encryption_status_detail({:disabled_no_key, :key_too_short}) do
    gettext(
      "A dedicated encryption key is configured but was rejected as too short, and no other " <>
        "key resolves — credentials below are being written in plain text. Replace it with a " <>
        "longer secret and restart; rotation cannot help while no key is active."
    )
  end

  def encryption_status_detail({_status, :key_too_short}) do
    gettext(
      "A dedicated encryption key is configured but was rejected as too short, so a weaker " <>
        "key is in use. This is not the same as having none configured. Replace it with a " <>
        "longer secret — while a rejected key is set, the key store is not consulted at all, " <>
        "so repairing or filling the store changes nothing."
    )
  end

  def encryption_status_detail({:legacy_secret_key_base, _reason}) do
    gettext(
      "No dedicated encryption key is configured, so credentials below fall back to a key " <>
        "derived from secret_key_base — a secret shared with session signing and CSRF tokens. " <>
        "Anyone who can read secret_key_base can decrypt every credential here. Run " <>
        "mix phoenix_kit.integrations.rotate_key to fix this."
    )
  end

  def encryption_status_detail({:disabled_no_key, _reason}) do
    gettext(
      "No encryption key could be resolved. New and existing credentials below are stored as " <>
        "plain text in the database."
    )
  end

  def encryption_status_detail({:disabled_explicit, _reason}) do
    gettext(
      "integration_encryption_enabled is set to false. Credentials below are stored as plain " <>
        "text in the database."
    )
  end

  # See `encryption_status_title/1`'s catch-all note.
  def encryption_status_detail(_other) do
    gettext(
      "The current encryption status could not be described by this admin page — it may be " <>
        "newer than what this page recognizes. Check PhoenixKit.Integrations.Encryption.status/0 " <>
        "directly."
    )
  end

  # Returns `{fingerprint, tier}` or nil. The tier is not decoration: a site
  # whose key store is unreadable, or whose dedicated key was rejected as too
  # short, fingerprints its FALLBACK key. A bare number would let an operator
  # comparing two sites conclude their keys differ when the comparison was never
  # like-for-like.
  #
  # `:none` renders nothing rather than a placeholder: with no key there is
  # nothing to compare, and the banner above already says the credentials are
  # unencrypted.
  defp encryption_fingerprint(report) do
    case report.fingerprint do
      {:ok, fingerprint, _label} -> {fingerprint, fingerprint_tier(report.diagnosis)}
      :none -> nil
    end
  end

  @doc false
  def fingerprint_tier({:dedicated, :ok}), do: gettext("dedicated key")

  # Ahead of the generic `:store_unreadable` clause below, which would otherwise
  # label a working dedicated key "FALLBACK".
  def fingerprint_tier({:dedicated, :store_unreadable}),
    do: gettext("dedicated key — its key store could not be read")

  def fingerprint_tier({_status, :store_unreadable}),
    do: gettext("FALLBACK key — the configured key store could not be read")

  def fingerprint_tier({_status, :key_too_short}),
    do: gettext("FALLBACK key — the configured key was rejected as too short")

  def fingerprint_tier({:legacy_secret_key_base, _}),
    do: gettext("derived from secret_key_base")

  def fingerprint_tier(_other), do: gettext("unrecognised key state")
end
