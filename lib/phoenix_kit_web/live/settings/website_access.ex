defmodule PhoenixKitWeb.Live.Settings.WebsiteAccess do
  @moduledoc """
  Website access — the settings page where every way of controlling who
  sees this site lives, for now (the boss decides later where each piece
  belongs):

    * **presets** at the top — a button that switches a bundle of features
      on, the old "modes";
    * **the features**, each a checkbox with an explanation and, where it
      needs one, its own area: the password gate (password, lockout, access
      link, the history of tries), the redirect to production, the visitor
      notice, maintenance, hide from search engines (shared with the
      Crawlers page), allowed addresses;
    * **the environment** — how this install runs, with a suggested preset.

  Every change goes through `PhoenixKit.WebsiteAccess` and lands in the
  settings history with this admin as the actor.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Crawlers
  alias PhoenixKit.Modules.Maintenance
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: DateUtils
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.WebsiteAccess
  alias PhoenixKit.WebsiteAccess.{AllowedAddresses, Gate, Notice, Redirect}
  alias PhoenixKitWeb.Plugs.WebsiteAccess, as: AccessPlug

  # The features with a switch (allowed addresses has none — it is on when
  # the list is not empty).
  @features ~w(gate redirect notice maintenance no_index)

  # The tries table's columns; the admin picks which show (core's column
  # settings modal), the choice is kept as a site setting like the Users
  # table's.
  @attempt_columns ~w(when result typed address browser)
  @attempt_columns_key "website_access_attempt_columns"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Maintenance.subscribe()
      Gate.subscribe()
    end

    socket =
      socket
      |> assign(:page_title, gettext("Website access"))
      |> assign(
        :page_subtitle,
        gettext(
          "Who sees this site, and what they see: a list of features you switch on one by one, and presets that switch on a bundle."
        )
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, Settings.get_project_title())
      |> assign(
        :current_path,
        Routes.path("/admin/settings/website-access",
          locale: socket.assigns.current_locale_base
        )
      )
      |> assign(:show_password, false)
      |> assign(:show_column_modal, false)
      |> assign(:attempt_columns, load_attempt_columns())
      |> assign(:site_zone, Settings.get_setting_cached("time_zone", "0"))
      |> assign(:environment, WebsiteAccess.environment())
      |> assign(:presets, WebsiteAccess.presets())
      |> assign_state()

    {:ok, socket}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # ── Presets ────────────────────────────────────────────────────────

  def handle_event("apply_preset", %{"preset" => key}, socket) do
    case WebsiteAccess.apply_preset(key, history(socket)) do
      :ok ->
        label = Enum.find_value(socket.assigns.presets, key, &(&1.key == key && &1.label))

        {:noreply,
         socket
         |> put_flash(:info, gettext("Preset applied: %{name}", name: label))
         |> assign_state()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # ── Feature checkboxes ─────────────────────────────────────────────

  def handle_event("toggle_feature", %{"feature" => key}, socket) when key in @features do
    feature = Enum.find(socket.assigns.features, &(Atom.to_string(&1.key) == key))
    on? = not feature.switched_on?

    case WebsiteAccess.set(feature.key, on?, history(socket)) do
      {:ok, _} ->
        {:noreply, socket |> assign_state() |> put_flash(:info, toggled_text(feature, on?))}

      {:error, reason} ->
        # The switch in the browser already flipped on the click; the
        # refreshed assigns put it back where the server has it.
        {:noreply, socket |> assign_state() |> put_flash(:error, error_text(reason))}
    end
  end

  def handle_event("toggle_feature", _params, socket),
    do: {:noreply, put_flash(socket, :error, error_text(:not_switchable))}

  # ── Password gate ──────────────────────────────────────────────────

  def handle_event("save_gate", %{"gate" => params}, socket) do
    opts = history(socket)
    password = Map.get(params, "password", "")

    with {:ok, _} <-
           if(password == "", do: {:ok, :unchanged}, else: Gate.set_password(password, opts)),
         {:ok, _} <-
           Settings.update_setting(
             Gate.lockout_attempts_key(),
             bounded_int(Map.get(params, "lockout_attempts"), 0, 0..1000),
             opts
           ),
         {:ok, _} <-
           Settings.update_setting(
             Gate.lockout_minutes_key(),
             bounded_int(Map.get(params, "lockout_minutes"), 15, 1..1440),
             opts
           ),
         {:ok, _} <- Gate.set_users_pass(Map.get(params, "users_pass") == "true", opts),
         {:ok, _} <-
           Settings.update_setting(Gate.keep_typed_key(), keep_typed_choice(params), opts) do
      {:noreply,
       socket |> assign_state() |> put_flash(:info, gettext("Password gate settings saved."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("reveal_password", _params, socket) do
    {:noreply, assign(socket, :show_password, not socket.assigns.show_password)}
  end

  def handle_event("generate_link", _params, socket) do
    case Gate.regenerate_access_link(history(socket)) do
      {:ok, _token} ->
        {:noreply,
         socket
         |> assign_state()
         |> put_flash(:info, gettext("New access link made. The old one no longer works."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("revoke_link", _params, socket) do
    case Gate.revoke_access_link(history(socket)) do
      {:ok, _} ->
        {:noreply, socket |> assign_state() |> put_flash(:info, gettext("Access link revoked."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  def handle_event("relock", _params, socket) do
    case Gate.relock_everyone(history(socket)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_state()
         |> put_flash(:info, gettext("Everyone has to type the password again."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # ── The tries table's columns (core's column settings modal) ───────

  def handle_event("show_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_column_modal, true)}

  def handle_event("hide_column_modal", _params, socket),
    do: {:noreply, assign(socket, :show_column_modal, false)}

  def handle_event("add_column", %{"column_id" => id}, socket) when id in @attempt_columns do
    {:noreply, save_attempt_columns(socket, Enum.uniq(socket.assigns.attempt_columns ++ [id]))}
  end

  def handle_event("add_column", _params, socket), do: {:noreply, socket}

  def handle_event("remove_column", %{"column_id" => id}, socket) when is_binary(id) do
    # The last column stays: a table with no columns is no table.
    case List.delete(socket.assigns.attempt_columns, id) do
      [] -> {:noreply, socket}
      columns -> {:noreply, save_attempt_columns(socket, columns)}
    end
  end

  def handle_event("remove_column", _params, socket), do: {:noreply, socket}

  def handle_event("reorder_columns", %{"ordered_ids" => ids}, socket) when is_list(ids) do
    # Unknown ids are dropped, duplicates folded, and an order that names
    # no column at all is ignored — same rule as removing the last column.
    case ids |> Enum.filter(&(&1 in @attempt_columns)) |> Enum.uniq() do
      [] -> {:noreply, socket}
      columns -> {:noreply, save_attempt_columns(socket, columns)}
    end
  end

  def handle_event("reorder_columns", _params, socket), do: {:noreply, socket}

  def handle_event("reset_columns", _params, socket),
    do: {:noreply, save_attempt_columns(socket, @attempt_columns)}

  def handle_event("clear_attempts", _params, socket) do
    Gate.clear_attempts()
    {:noreply, socket |> assign_state() |> put_flash(:info, gettext("History cleared."))}
  end

  # ── Redirect ───────────────────────────────────────────────────────

  def handle_event("save_redirect", %{"redirect" => params}, socket) do
    opts = history(socket)
    url = params |> Map.get("url", "") |> String.trim()
    scope = Map.get(params, "scope", "everyone")

    with {:ok, _} <- Settings.update_setting(Redirect.url_key(), url, opts),
         {:ok, _} <- Settings.update_setting(Redirect.scope_key(), scope, opts) do
      {:noreply,
       socket |> assign_state() |> put_flash(:info, gettext("Redirect settings saved."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # ── Notice ─────────────────────────────────────────────────────────

  def handle_event("save_notice", %{"notice" => params}, socket) do
    opts = history(socket)

    with {:ok, _} <-
           Settings.update_setting(Notice.icon_key(), Map.get(params, "icon", "info"), opts),
         {:ok, _} <-
           Settings.update_setting(
             Notice.text_key(),
             String.trim(Map.get(params, "text", "")),
             opts
           ),
         {:ok, _} <-
           Settings.update_setting(
             Notice.link_key(),
             String.trim(Map.get(params, "link", "")),
             opts
           ) do
      {:noreply, socket |> assign_state() |> put_flash(:info, gettext("Notice saved."))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # ── Maintenance ────────────────────────────────────────────────────

  def handle_event("save_maintenance", %{"maintenance" => params}, socket) do
    opts = history(socket)
    zone = socket.assigns.site_zone

    # The window is read and checked before anything is written, so a
    # refused window changes nothing.
    with {:ok, from} <- parse_optional_local(Map.get(params, "from", ""), zone),
         {:ok, until} <- parse_optional_local(Map.get(params, "until", ""), zone),
         :ok <- check_window(from, until),
         {:ok, _} <- Maintenance.update_header(Map.get(params, "header", ""), opts),
         {:ok, _} <- Maintenance.update_subtext(Map.get(params, "subtext", ""), opts),
         :ok <- save_window(from, until, opts) do
      {:noreply, socket |> assign_state() |> put_flash(:info, gettext("Closed page saved."))}
    else
      {:error, reason} ->
        {:noreply, socket |> assign_state() |> put_flash(:error, error_text(reason))}
    end
  end

  # ── Allowed addresses ──────────────────────────────────────────────

  def handle_event("save_allowed", %{"allowed" => params}, socket) do
    addresses =
      params
      |> Map.get("addresses", "")
      |> String.split(~r/[\s,]+/, trim: true)
      |> Enum.uniq()
      |> Enum.join("\n")

    case Settings.update_setting(AllowedAddresses.key(), addresses, history(socket)) do
      {:ok, _} ->
        # Open pages re-check who may stay (an address taken off the list
        # must not keep its tabs).
        Gate.broadcast_relock()

        {:noreply,
         socket |> assign_state() |> put_flash(:info, gettext("Allowed addresses saved."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_text(reason))}
    end
  end

  # ── Live updates ───────────────────────────────────────────────────

  def handle_info({:maintenance_status_changed, _}, socket), do: {:noreply, assign_state(socket)}
  def handle_info({:website_access, _}, socket), do: {:noreply, assign_state(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  # ── State ──────────────────────────────────────────────────────────

  defp assign_state(socket) do
    link_token = Gate.access_link_token()

    # The bar on THIS page was injected at load time; tell the page to swap
    # it for the current one so a save shows at once, not after a reload.
    socket = push_event(socket, "website_access:notice", %{html: Notice.html() || ""})

    socket
    |> assign(:features, WebsiteAccess.features())
    |> assign(:crawlers_module_on?, Crawlers.module_enabled?())
    |> assign(:gate, %{
      password: Gate.password() || "",
      lockout_attempts: Gate.lockout_attempts(),
      lockout_minutes: Gate.lockout_minutes(),
      users_pass: Gate.users_pass?(),
      keep_typed: Gate.keep_typed(),
      link_url:
        link_token && site_origin(socket) <> AccessPlug.gate_path() <> "/link/" <> link_token,
      gate_url: site_origin(socket) <> AccessPlug.gate_path()
    })
    |> assign(:attempts, Gate.list_attempts(limit: 200))
    |> assign(:attempt_counts, Gate.attempt_counts())
    |> assign(:redirect, %{
      url: Settings.get_setting(Redirect.url_key(), "") || "",
      scope: Redirect.scope()
    })
    |> assign(:notice, %{
      icon: Notice.icon(),
      text: Notice.text(),
      link: Settings.get_setting(Notice.link_key(), "") || ""
    })
    |> assign(:notice_html, Notice.html(preview: true))
    |> assign(:maintenance, maintenance_state(socket.assigns.site_zone))
    |> assign(:allowed_addresses, Enum.join(AllowedAddresses.list(), "\n"))
  end

  # The origin the admin is looking at — a link they copy from here must
  # point at the site they are on, not at whatever the email base URL is.
  defp site_origin(%{host_uri: %URI{} = uri}), do: URI.to_string(%{uri | path: nil, query: nil})
  defp site_origin(_socket), do: Routes.base_url()

  defp maintenance_state(zone) do
    start = Maintenance.get_scheduled_start()
    finish = Maintenance.get_scheduled_end()

    %{
      header: Maintenance.get_header(),
      subtext: Maintenance.get_subtext(),
      active: Maintenance.active?(),
      manual: Maintenance.manually_enabled?(),
      from: DateUtils.format_datetime_local(start, zone),
      until: DateUtils.format_datetime_local(finish, zone),
      zone_label: Settings.get_timezone_label(zone),
      status: closed_status(Maintenance.active?(), Maintenance.manually_enabled?(), start, finish)
    }
  end

  defp closed_status(true, true, _start, nil), do: gettext("Closed now, by hand — no end time.")

  defp closed_status(true, true, _start, _finish),
    do: gettext("Closed now, by hand, until the time below.")

  defp closed_status(true, false, _start, nil),
    do: gettext("Closed now — the scheduled window is open and has no end.")

  defp closed_status(true, false, _start, _finish),
    do: gettext("Closed now — the scheduled window is open.")

  defp closed_status(false, _manual, %DateTime{} = start, _finish) do
    if DateTime.compare(start, DateTime.utc_now()) == :gt,
      do: gettext("Open. Closes by itself when the scheduled window starts."),
      else: gettext("Open.")
  end

  defp closed_status(false, _manual, _start, _finish), do: gettext("Open.")

  defp parse_optional_local("", _zone), do: {:ok, nil}
  defp parse_optional_local(nil, _zone), do: {:ok, nil}
  defp parse_optional_local(value, zone), do: DateUtils.parse_datetime_local(value, zone)

  # The scheduled window: "from" opens the closed page by itself when it
  # arrives, "until" is what visitors count down to and when it switches
  # itself off. Both blank clears the window. A window the form sends back
  # unchanged is left alone — its start may already have passed (the page
  # is closed right now, or was), and editing the heading must not require
  # throwing the window away or fail because of it.
  defp check_window(from, until) do
    cond do
      from == nil and until == nil -> :ok
      window_unchanged?(from, until) -> :ok
      true -> Maintenance.check_schedule(from, until)
    end
  end

  defp save_window(from, until, opts) do
    cond do
      window_unchanged?(from, until) -> :ok
      from == nil and until == nil -> Maintenance.clear_schedule(opts)
      true -> Maintenance.update_schedule(from, until, opts)
    end
  end

  defp window_unchanged?(from, until) do
    Maintenance.same_minute?(from, Maintenance.get_scheduled_start()) and
      Maintenance.same_minute?(until, Maintenance.get_scheduled_end())
  end

  # Form numbers are text: a blank, junk or out-of-range value becomes the
  # default or the nearest bound, so the stored setting is always a number
  # the gate can use.
  defp bounded_int(value, default, range) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> n |> max(range.first) |> min(range.last) |> Integer.to_string()
      _ -> Integer.to_string(default)
    end
  end

  defp bounded_int(_value, default, _range), do: Integer.to_string(default)

  defp keep_typed_choice(params) do
    case Map.get(params, "keep_typed") do
      choice when is_binary(choice) ->
        if choice in Gate.keep_typed_choices(), do: choice, else: "all"

      _ ->
        "all"
    end
  end

  defp load_attempt_columns do
    case Settings.get_setting(@attempt_columns_key) do
      nil ->
        @attempt_columns

      json ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) ->
            case list |> Enum.filter(&(&1 in @attempt_columns)) |> Enum.uniq() do
              [] -> @attempt_columns
              columns -> columns
            end

          _ ->
            @attempt_columns
        end
    end
  end

  defp save_attempt_columns(socket, columns) do
    case Settings.update_setting(@attempt_columns_key, Jason.encode!(columns), history(socket)) do
      {:ok, _} -> assign(socket, :attempt_columns, columns)
      {:error, reason} -> put_flash(socket, :error, error_text(reason))
    end
  end

  @doc false
  def attempt_column_options do
    [
      %{id: "when", label: fn -> gettext("When") end},
      %{id: "result", label: fn -> gettext("Result") end},
      %{id: "typed", label: fn -> gettext("Typed") end},
      %{id: "address", label: fn -> gettext("Address") end},
      %{id: "browser", label: fn -> gettext("Browser") end}
    ]
  end

  # The card view of the tries table (small screens): the same columns,
  # as label/value pairs.
  @doc false
  def attempt_card_fields(attempt, columns) do
    for col <- columns, col != "result" do
      value =
        case col do
          "when" ->
            attempt.inserted_at |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_string()

          "typed" ->
            attempt.typed || "—"

          "address" ->
            attempt.address || "—"

          "browser" ->
            attempt.user_agent || "—"
        end

      %{label: attempt_column_label(col), value: value}
    end
  end

  @doc false
  def attempt_column_label(id) do
    case Enum.find(attempt_column_options(), &(&1.id == id)) do
      %{label: label} -> label.()
      nil -> id
    end
  end

  defp history(socket) do
    [
      actor_uuid: get_in(socket.assigns, [:phoenix_kit_current_user, Access.key(:uuid)]),
      source: "settings"
    ]
  end

  # ── Text ───────────────────────────────────────────────────────────

  defp toggled_text(feature, true), do: gettext("%{feature} switched on.", feature: feature.label)

  defp toggled_text(feature, false),
    do: gettext("%{feature} switched off.", feature: feature.label)

  defp error_text(:unknown_preset), do: gettext("Unknown preset.")
  defp error_text(:not_switchable), do: gettext("That feature has no switch.")
  defp error_text(:end_in_past), do: gettext("The \"until\" time is in the past.")
  defp error_text(:start_in_past), do: gettext("The \"from\" time is in the past.")

  defp error_text(:end_before_start),
    do: gettext(~S(The "until" time is before the "from" time.))

  defp error_text(:too_far_future), do: gettext("That is more than a year away.")
  defp error_text(:empty), do: gettext("Nothing to save.")
  defp error_text(:invalid_format), do: gettext("That is not a date and time.")

  defp error_text(%Ecto.Changeset{} = changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} -> "#{field}: #{message}" end)
  end

  defp error_text(other), do: gettext("Could not save: %{reason}", reason: inspect(other))

  @doc false
  def verdict_text("correct"), do: gettext("correct")
  def verdict_text("case"), do: gettext("right letters, wrong case")
  def verdict_text("close"), do: gettext("close — a typo")
  def verdict_text("unrelated"), do: gettext("wrong")
  def verdict_text("empty"), do: gettext("empty")
  def verdict_text("locked"), do: gettext("locked out")
  def verdict_text("link"), do: gettext("access link")
  def verdict_text(other), do: other

  @doc false
  def verdict_class("correct"), do: "badge-success"
  def verdict_class("link"), do: "badge-success"
  def verdict_class("case"), do: "badge-warning"
  def verdict_class("close"), do: "badge-warning"
  def verdict_class("locked"), do: "badge-error"
  def verdict_class(_), do: "badge-ghost"

  @doc false
  def reason_text({:mix_env, value}), do: gettext("MIX_ENV is %{value}", value: value)
  def reason_text({:hostname, value}), do: gettext("the hostname is %{value}", value: value)
  def reason_text({:site_url, value}), do: gettext("the site URL is %{value}", value: value)

  @doc false
  def keep_typed_options do
    [
      {gettext("Everything typed on a wrong try"), "all"},
      {gettext("Only near misses (wrong case, a typo)"), "near"},
      {gettext("Nothing"), "none"}
    ]
  end

  @doc false
  def icon_options do
    [
      {gettext("Construction"), "construction"},
      {gettext("Warning"), "warning"},
      {gettext("Info"), "info"},
      {gettext("None"), "none"}
    ]
  end

  @doc false
  def scope_options do
    [{gettext("Everyone"), "everyone"}, {gettext("Search-engine crawlers only"), "crawlers"}]
  end

  @doc false
  def feature_icon(:gate), do: "hero-lock-closed"
  def feature_icon(:redirect), do: "hero-arrow-top-right-on-square"
  def feature_icon(:notice), do: "hero-megaphone"
  def feature_icon(:maintenance), do: "hero-wrench-screwdriver"
  def feature_icon(:no_index), do: "hero-eye-slash"
  def feature_icon(:allowed_addresses), do: "hero-map-pin"
end
