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
    socket =
      socket
      |> assign(:encryption_status, Encryption.status())
      |> assign(:encryption_fingerprint, encryption_fingerprint())

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

  # Deliberately no clause for `:dedicated` — the template guards rendering
  # on `@encryption_status != :dedicated`, so the healthy case never reaches
  # these.
  defp encryption_status_title(:legacy_secret_key_base),
    do: gettext("Credentials are protected only by a shared application secret")

  defp encryption_status_title(:disabled_no_key),
    do: gettext("Credentials are stored in plain text")

  defp encryption_status_title(:disabled_explicit),
    do: gettext("Encryption is turned off for integration credentials")

  # Catch-all: the template renders this banner for ANY status other than
  # `:dedicated` (see the guard note above), so a future `key_status/0`
  # value this page hasn't been taught about must degrade to a generic
  # warning instead of a `FunctionClauseError` crashing the settings page.
  defp encryption_status_title(_other),
    do: gettext("Integration credential encryption needs attention")

  defp encryption_status_detail(:legacy_secret_key_base) do
    gettext(
      "No dedicated encryption key is configured, so credentials below fall back to a key " <>
        "derived from secret_key_base — a secret shared with session signing and CSRF tokens. " <>
        "Anyone who can read secret_key_base can decrypt every credential here. Run " <>
        "mix phoenix_kit.integrations.rotate_key to fix this."
    )
  end

  defp encryption_status_detail(:disabled_no_key) do
    gettext(
      "No encryption key could be resolved. New and existing credentials below are stored as " <>
        "plain text in the database."
    )
  end

  defp encryption_status_detail(:disabled_explicit) do
    gettext(
      "integration_encryption_enabled is set to false. Credentials below are stored as plain " <>
        "text in the database."
    )
  end

  # See `encryption_status_title/1`'s catch-all note.
  defp encryption_status_detail(_other) do
    gettext(
      "The current encryption status could not be described by this admin page — it may be " <>
        "newer than what this page recognizes. Check PhoenixKit.Integrations.Encryption.status/0 " <>
        "directly."
    )
  end

  # `:none` renders nothing rather than a placeholder: with no key there is
  # nothing to compare between sites, and the banner above already says the
  # credentials are unencrypted.
  defp encryption_fingerprint do
    case Encryption.key_fingerprint() do
      {:ok, fingerprint} -> fingerprint
      :none -> nil
    end
  end
end
