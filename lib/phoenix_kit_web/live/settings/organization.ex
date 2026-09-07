defmodule PhoenixKitWeb.Live.Settings.Organization do
  @moduledoc """
  Organization settings management LiveView for PhoenixKit.

  Provides a unified interface for company information shared between
  Legal and Billing modules. This includes company details and bank information.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.PubSub.Manager, as: PubSubManager
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes

  @default_company_info %{
    "name" => "",
    "address_line1" => "",
    "address_line2" => "",
    "city" => "",
    "state" => "",
    "postal_code" => "",
    "country" => "",
    "vat_number" => "",
    "registration_number" => ""
  }

  @default_bank_details %{
    "bank_name" => "",
    "iban" => "",
    "swift" => ""
  }

  def mount(_params, _session, socket) do
    # Subscribe to organization settings updates for real-time sync
    if connected?(socket) do
      PubSubManager.subscribe("organization:settings")
    end

    project_title = Settings.get_project_title()

    socket =
      socket
      |> assign(:page_title, gettext("Organization"))
      |> assign(
        :page_subtitle,
        gettext("Company information shared across Legal and Billing modules")
      )
      |> assign(:page_section, gettext("Settings"))
      |> assign(:page_section_path, Routes.path("/admin/settings"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> assign(:active_tab, "company")
      # Kept out of load_settings/1 on purpose: that runs on every save AND
      # on the PubSub broadcast from any OTHER admin session's edit, and
      # neither should be able to slam this session's own open modal shut.
      |> assign(:show_bank_account_form, false)
      |> assign(:editing_bank_account, nil)
      |> load_settings()

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    company_info = get_company_info()

    socket
    |> assign_company_info(company_info)
    |> assign_country_data(company_info["country"])
    |> assign_tax_settings(company_info)
    |> assign(:bank_accounts, get_bank_accounts())
    |> assign(:site_url, Settings.get_setting("site_url", ""))
  end

  defp assign_company_info(socket, info) do
    socket
    |> assign(:company_name, info["name"] || "")
    |> assign(:company_vat, info["vat_number"] || "")
    |> assign(:company_registration, info["registration_number"] || "")
    |> assign(:company_address_line1, info["address_line1"] || "")
    |> assign(:company_address_line2, info["address_line2"] || "")
    |> assign(:company_city, info["city"] || "")
    |> assign(:company_state, info["state"] || "")
    |> assign(:company_postal_code, info["postal_code"] || "")
    |> assign(:company_country, info["country"] || "")
  end

  defp assign_country_data(socket, country) do
    socket
    |> assign(:countries, CountryData.countries_for_select())
    |> assign(:subdivision_label, get_subdivision_label(country))
    |> assign(:subdivisions, subdivisions_for(country))
    |> assign(:tax_id_label, tax_id_label(country))
    |> assign(:postal_code_label, postal_code_label(country))
    |> assign(:eu_country, eu_country?(country))
    |> assign_main_countries(stored_main_countries(), country)
  end

  defp stored_main_countries do
    "country_select_priority"
    |> Settings.get_setting_cached("")
    |> CountryData.parse_priority()
    |> CountryData.known_country_codes()
  end

  # Everything the card renders is precomputed here rather than called from
  # the template: a `defp` invoked from HEEX cannot be verified by the
  # compiler. `:main_country_suggestion` is what the host's own country
  # proposes and is deliberately empty once every suggested code is already
  # in the list — there is nothing left to offer.
  defp assign_main_countries(socket, codes, country) do
    chosen = MapSet.new(codes)

    socket
    |> assign(:main_countries, codes)
    |> assign(:main_country_rows, main_country_rows(codes))
    |> assign(
      :main_country_options,
      # `priority: []` on purpose: the picker is where you go to CHANGE the
      # pinned set, so it must not itself be reordered by it — otherwise the
      # first thing the dropdown offers is whatever is already pinned.
      Enum.reject(CountryData.countries_for_select(priority: []), fn {_label, code} ->
        MapSet.member?(chosen, code)
      end)
    )
    |> assign(:main_country_suggestion, main_country_suggestion(country, chosen))
  end

  defp main_country_rows(codes) do
    last = length(codes) - 1

    codes
    |> Enum.with_index()
    |> Enum.map(fn {code, index} ->
      %{
        code: code,
        label: country_label(code),
        first?: index == 0,
        last?: index == last
      }
    end)
  end

  defp main_country_suggestion(country, chosen) do
    country
    |> CountryData.suggested_priority()
    |> Enum.reject(&MapSet.member?(chosen, &1))
    |> Enum.map(fn code -> %{code: code, label: country_label(code)} end)
  end

  # Same shape as CountryData's own select entries — flag, space, localized
  # name — and defensive about the flag for the same reason its `select_entry/2`
  # is: the struct field is nilable and blank on some rows in other datasets,
  # and `nil <> " "` is an ArgumentError that would take the whole settings
  # page down. Every one of beamlab_countries 1.1.0's 250 rows carries a flag,
  # so this is about not depending on that.
  defp country_label(code) do
    name = CountryData.get_country_name(code) || code

    case CountryData.get_flag(code) do
      nil -> name
      "" -> name
      flag -> flag <> " " <> name
    end
  end

  defp assign_tax_settings(socket, _company_info) do
    tax_config = CountryData.get_tax_config()
    country = socket.assigns.company_country

    suggested_rate =
      if country != "" do
        rate = CountryData.get_standard_vat_percent(country)
        current = parse_tax_rate(tax_config.rate)
        if rate != 0 and rate != current, do: rate
      end

    socket
    |> assign(:tax_enabled, tax_config.enabled)
    |> assign(:tax_rate, tax_config.rate)
    |> assign(:suggested_tax_rate, suggested_rate)
  end

  # ===================================
  # EVENT HANDLERS
  # ===================================

  def handle_event("switch_settings_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, tab)}
  end

  def handle_event("country_changed", %{"company_country" => country_code}, socket) do
    # Update suggested tax rate when country changes
    current_rate = parse_tax_rate(socket.assigns.tax_rate)

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        if rate != 0 and rate != current_rate, do: rate
      end

    # The main-countries suggestion is derived from the company country too,
    # so it goes stale the same way the tax rate would if left alone: an
    # unsaved country pick must not leave the previous country's neighbours
    # on screen.
    suggestion =
      main_country_suggestion(country_code, MapSet.new(socket.assigns.main_countries))

    {:noreply,
     socket
     |> assign(:company_country, country_code)
     # A state/province chosen for the PREVIOUS country is nonsense once the
     # country changes — a raw US state code sitting in a German company's
     # `state` field would round-trip silently on save otherwise, since
     # `save_company_info/2` doesn't cross-check the two against each other.
     |> assign(:company_state, "")
     |> assign(:subdivision_label, get_subdivision_label(country_code))
     |> assign(:subdivisions, subdivisions_for(country_code))
     |> assign(:tax_id_label, tax_id_label(country_code))
     |> assign(:postal_code_label, postal_code_label(country_code))
     |> assign(:eu_country, eu_country?(country_code))
     |> assign(:suggested_tax_rate, suggested_rate)
     |> assign(:main_country_suggestion, suggestion)}
  end

  def handle_event("save_company", params, socket) do
    data = extract_company_data(params)

    case validate_company_data(data) do
      [] ->
        save_company_info(data, params)

        # Broadcast to all admin sessions
        broadcast_settings_change(:company_info_updated)

        {:noreply,
         socket
         |> load_settings()
         |> put_flash(:info, gettext("Organization information saved"))}

      errors ->
        {:noreply, put_flash(socket, :error, Enum.join(errors, ". "))}
    end
  end

  # The main-countries card writes on every action rather than behind a save
  # button: each click is already a deliberate edit, and there is no second
  # field whose validation could hold the list hostage.
  def handle_event("add_main_country", %{"code" => code}, socket) when is_binary(code) do
    {:noreply, put_main_countries(socket, socket.assigns.main_countries ++ [code])}
  end

  def handle_event("add_main_country", _params, socket), do: {:noreply, socket}

  def handle_event("remove_main_country", %{"code" => code}, socket) do
    {:noreply,
     put_main_countries(socket, Enum.reject(socket.assigns.main_countries, &(&1 == code)))}
  end

  def handle_event("remove_main_country", _params, socket), do: {:noreply, socket}

  # SortableGrid pushes the full order on drop, so the list is taken as given
  # rather than diffed — but only codes that were already pinned are honoured,
  # so a forged payload can neither add a country nor drop one silently.
  def handle_event("reorder_main_countries", %{"ordered_ids" => ordered}, socket)
      when is_list(ordered) do
    current = socket.assigns.main_countries
    reordered = Enum.filter(ordered, &(&1 in current))
    codes = reordered ++ (current -- reordered)

    {:noreply, put_main_countries(socket, codes)}
  end

  def handle_event("reorder_main_countries", _params, socket), do: {:noreply, socket}

  # Restored alongside drag: SortableJS is a CDN fetch that a strict CSP or
  # an offline deploy can block, and dragging itself has no keyboard path —
  # without these buttons a keyboard/screen-reader operator could not
  # reorder at all.
  def handle_event("move_main_country", %{"code" => code, "direction" => direction}, socket)
      when is_binary(code) and direction in ["up", "down"] do
    {:noreply, put_main_countries(socket, move(socket.assigns.main_countries, code, direction))}
  end

  def handle_event("move_main_country", _params, socket), do: {:noreply, socket}

  def handle_event("apply_main_country_suggestion", _params, socket) do
    suggested = Enum.map(socket.assigns.main_country_suggestion, & &1.code)

    {:noreply, put_main_countries(socket, socket.assigns.main_countries ++ suggested)}
  end

  def handle_event("save_tax", params, socket) do
    tax_enabled = params["tax_enabled"] == "true"
    tax_rate = (params["tax_rate"] || "0") |> String.trim()

    # Save tax settings into company_info JSON
    company_info = get_company_info()

    updated_info =
      company_info
      |> Map.put("tax_enabled", tax_enabled)
      |> Map.put("tax_rate", tax_rate)

    Settings.update_json_setting("company_info", updated_info)

    # Also sync to legacy keys for backward compatibility with Billing/Shop
    Settings.update_setting(
      "billing_tax_enabled",
      if(tax_enabled, do: "true", else: "false")
    )

    Settings.update_setting("billing_default_tax_rate", tax_rate)
    Settings.update_setting("shop_tax_enabled", if(tax_enabled, do: "true", else: "false"))
    Settings.update_setting("shop_tax_rate", tax_rate)

    broadcast_settings_change(:tax_settings_updated)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, gettext("Tax settings saved"))}
  end

  def handle_event("tax_rate_changed", %{"tax_rate" => tax_rate}, socket) do
    current_rate = parse_tax_rate(tax_rate)
    country_code = socket.assigns.company_country

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        if rate != 0 and rate != current_rate, do: rate
      end

    {:noreply,
     socket
     |> assign(:tax_rate, tax_rate)
     |> assign(:suggested_tax_rate, suggested_rate)}
  end

  def handle_event("apply_suggested_tax", _params, socket) do
    case socket.assigns.suggested_tax_rate do
      nil ->
        {:noreply, socket}

      rate ->
        {:noreply,
         socket
         |> assign(:tax_rate, to_string(rate))
         |> assign(:suggested_tax_rate, nil)}
    end
  end

  def handle_event("show_add_bank_account_form", _params, socket) do
    {:noreply, assign(socket, show_bank_account_form: true, editing_bank_account: nil)}
  end

  def handle_event("show_edit_bank_account_form", %{"uuid" => uuid}, socket) do
    account = Enum.find(socket.assigns.bank_accounts, &(&1["uuid"] == uuid))
    {:noreply, assign(socket, show_bank_account_form: true, editing_bank_account: account)}
  end

  def handle_event("hide_bank_account_form", _params, socket) do
    {:noreply, assign(socket, show_bank_account_form: false, editing_bank_account: nil)}
  end

  def handle_event("save_bank_account", params, socket) do
    bank_name = (params["bank_name"] || "") |> String.trim()
    iban = (params["iban"] || "") |> String.trim()
    swift = (params["swift"] || "") |> String.trim()
    label = (params["account_label"] || "") |> String.trim()
    primary? = params["primary"] == "true"
    country_code = socket.assigns.company_country

    errors =
      []
      |> validate_required(bank_name, gettext("Bank name is required"))
      |> validate_bank_iban(iban, country_code)
      |> validate_bank_swift(swift)

    case errors do
      [] ->
        account = %{
          "uuid" => existing_bank_account_uuid(socket) || UUIDv7.generate(),
          "label" => if(label == "", do: bank_name, else: label),
          "bank_name" => bank_name,
          "iban" => normalize_iban(iban),
          "swift" => String.upcase(swift),
          "primary" => primary?
        }

        socket.assigns.bank_accounts
        |> upsert_bank_account(account)
        |> save_bank_accounts()

        broadcast_settings_change(:bank_details_updated)

        {:noreply,
         socket
         |> load_settings()
         |> assign(show_bank_account_form: false, editing_bank_account: nil)
         |> put_flash(:info, gettext("Bank account saved"))}

      errors ->
        {:noreply, put_flash(socket, :error, Enum.join(Enum.reverse(errors), ". "))}
    end
  end

  def handle_event("delete_bank_account", %{"uuid" => uuid}, socket) do
    socket.assigns.bank_accounts
    |> Enum.reject(&(&1["uuid"] == uuid))
    |> save_bank_accounts()

    broadcast_settings_change(:bank_details_updated)

    {:noreply,
     socket
     |> load_settings()
     |> put_flash(:info, gettext("Bank account removed"))}
  end

  # Handle PubSub messages for settings sync
  def handle_info({:organization_settings_changed, _data}, socket) do
    {:noreply, load_settings(socket)}
  end

  # ===================================
  # DATA ACCESS (with fallback to legacy keys)
  # ===================================

  @doc """
  Gets company info from consolidated key with fallback to legacy keys.
  """
  def get_company_info do
    Map.merge(@default_company_info, CountryData.get_company_info())
  end

  @doc """
  Gets bank details in the original single-account shape — the PRIMARY
  bank account's fields (falling back to whichever account comes first if
  none is marked primary, and to blank if there are no accounts at all).

  Kept for `phoenix_kit_billing`, which calls this exact function via a
  soft dependency (see its `core_compat.ex`) and has no notion of multiple
  accounts. New code wanting the full list should call `get_bank_accounts/0`.
  """
  def get_bank_details do
    accounts = get_bank_accounts()
    account = Enum.find(accounts, & &1["primary"]) || List.first(accounts) || %{}
    Map.merge(@default_bank_details, Map.take(account, ["bank_name", "iban", "swift"]))
  end

  @doc """
  Gets the list of bank accounts. A company can have more than one (a EUR
  operating account and a USD reserve account, say) — each entry carries
  `"uuid"`, `"label"`, `"bank_name"`, `"iban"`, `"swift"`, `"primary"`.

  Falls back to migrating the legacy single-account `"company_bank_details"`
  setting (from before multi-account support) into a one-entry list marked
  primary. That migration is computed on every read, not persisted — it
  costs nothing until the operator actually saves an account, at which
  point the real list setting takes over.
  """
  def get_bank_accounts do
    # `value_json` is an Ecto `:map` column — it rejects a bare JSON array
    # (`Settings.update_json_setting/2` would return an unchecked
    # `{:error, changeset}` for one), so the list is wrapped the same way
    # Custom User Fields wraps its own list (`%{"fields" => [...]}`).
    case Settings.get_json_setting("company_bank_accounts", nil) do
      %{"accounts" => accounts} when is_list(accounts) -> accounts
      _ -> migrate_legacy_bank_details()
    end
  end

  defp migrate_legacy_bank_details do
    legacy = Map.merge(@default_bank_details, CountryData.get_bank_details())

    if legacy["bank_name"] != "" or legacy["iban"] != "" or legacy["swift"] != "" do
      [
        %{
          "uuid" => UUIDv7.generate(),
          "label" => "",
          "bank_name" => legacy["bank_name"],
          "iban" => legacy["iban"],
          "swift" => legacy["swift"],
          "primary" => true
        }
      ]
    else
      []
    end
  end

  # ===================================
  # VALIDATION
  # ===================================

  defp extract_company_data(params) do
    %{
      name: (params["company_name"] || "") |> String.trim(),
      country: params["company_country"] || "",
      vat: (params["company_vat"] || "") |> String.trim(),
      address_line1: (params["company_address_line1"] || "") |> String.trim(),
      city: (params["company_city"] || "") |> String.trim(),
      state: (params["company_state"] || "") |> String.trim(),
      postal_code: (params["company_postal_code"] || "") |> String.trim()
    }
  end

  defp validate_company_data(data) do
    []
    |> validate_required(data.name, gettext("Company name is required"))
    |> validate_required(data.country, gettext("Country is required"))
    |> validate_required(
      data.vat,
      gettext("%{label} is required", label: tax_id_label(data.country))
    )
    |> validate_required(data.address_line1, gettext("Street address is required"))
    |> validate_required(data.city, gettext("City is required"))
    |> validate_tax_id(data.vat, data.country)
    |> validate_state(data.state, data.country)
    |> validate_postal_code(data.postal_code, data.country)
    |> Enum.reverse()
  end

  defp validate_required(errors, "", message), do: [message | errors]
  defp validate_required(errors, _value, _message), do: errors

  defp validate_tax_id(errors, vat, country) when vat != "" and country != "" do
    case CountryData.validate_tax_id(country, vat) do
      :ok ->
        errors

      {:error, msg} ->
        [gettext("%{label} %{msg}", label: tax_id_label(country), msg: msg) | errors]
    end
  end

  defp validate_tax_id(errors, _vat, _country), do: errors

  # Only a country WITH subdivision data renders a <.select> — free text for
  # everyone else has nothing to check against, same as today.
  defp validate_state(errors, state, country) when state != "" and country != "" do
    subdivisions = subdivisions_for(country)

    if subdivisions == [] or Enum.any?(subdivisions, fn {_name, code} -> code == state end) do
      errors
    else
      [
        gettext("%{label} is not valid for %{country}",
          label: get_subdivision_label(country),
          country: country
        )
        | errors
      ]
    end
  end

  defp validate_state(errors, _state, _country), do: errors

  defp validate_postal_code(errors, postal_code, country)
       when postal_code != "" and country != "" do
    case CountryData.validate_postal_code(country, postal_code) do
      :ok ->
        errors

      {:error, msg} ->
        [gettext("%{label} %{msg}", label: postal_code_label(country), msg: msg) | errors]
    end
  end

  defp validate_postal_code(errors, _postal_code, _country), do: errors

  defp validate_bank_iban(errors, iban, country_code) do
    case CountryData.validate_iban_format(iban, country_code) do
      :ok -> errors
      {:error, msg} -> [msg | errors]
    end
  end

  defp validate_bank_swift(errors, swift) do
    case CountryData.validate_swift_format(swift) do
      :ok -> errors
      {:error, msg} -> [msg | errors]
    end
  end

  # ===================================
  # SAVE OPERATIONS
  # ===================================

  defp save_company_info(data, params) do
    # Merge with existing company_info to preserve tax_enabled/tax_rate keys
    existing = get_company_info()

    company_info =
      Map.merge(existing, %{
        "name" => data.name,
        "address_line1" => data.address_line1,
        "address_line2" => (params["company_address_line2"] || "") |> String.trim(),
        "city" => data.city,
        "state" => data.state,
        "postal_code" => data.postal_code,
        "country" => data.country,
        "vat_number" => String.upcase(data.vat),
        "registration_number" => (params["company_registration"] || "") |> String.trim()
      })

    Settings.update_json_setting("company_info", company_info)
  end

  # Only real, deduplicated country codes ever reach the setting: the card
  # offers a picker over the country list, so there is no free text to
  # sanitize, and `known_country_codes/1` is the belt-and-braces guard on a
  # forged phx-value. An empty list means nothing is pinned and every country
  # list is plain alphabetical — the setting is the only source, there is no
  # config underneath it.
  defp put_main_countries(socket, codes) do
    codes =
      codes
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()
      |> CountryData.known_country_codes()

    if codes == socket.assigns.main_countries do
      # Nothing actually changed (e.g. "Add" with an empty selection, or
      # removing/reordering into the same set) — don't write an identical
      # value and don't broadcast a no-op.
      socket
    else
      case Settings.update_setting("country_select_priority", Enum.join(codes, ", ")) do
        {:ok, _setting} ->
          # Broadcast to all admin sessions, same mechanism the other cards
          # use. `handle_info` only calls `load_settings/1` — it never
          # broadcasts itself — so the acting session's own bounce-back
          # cannot loop; it just reloads with the value already written.
          broadcast_settings_change(:main_countries_updated)

          socket
          # The Company card's country <.select> is computed once in
          # `load_settings/1`; without recomputing it here it keeps
          # offering the pre-pin alphabetical order until the next reload.
          |> assign(:countries, CountryData.countries_for_select())
          |> assign_main_countries(codes, socket.assigns.company_country)

        {:error, _changeset} ->
          put_flash(socket, :error, gettext("Main countries could not be saved"))
      end
    end
  end

  defp move(codes, code, direction) do
    case Enum.find_index(codes, &(&1 == code)) do
      nil -> codes
      index -> swap(codes, index, target_index(index, direction, length(codes)))
    end
  end

  defp target_index(index, "up", _length), do: max(index - 1, 0)
  defp target_index(index, "down", length), do: min(index + 1, length - 1)
  defp target_index(index, _direction, _length), do: index

  defp swap(codes, index, index), do: codes

  defp swap(codes, from, to) do
    moved = Enum.at(codes, from)

    codes
    |> List.delete_at(from)
    |> List.insert_at(to, moved)
  end

  defp existing_bank_account_uuid(%{assigns: %{editing_bank_account: %{"uuid" => uuid}}}),
    do: uuid

  defp existing_bank_account_uuid(_socket), do: nil

  # A newly-primary account un-sets every other one — daisyUI's checkbox
  # has no "radio group" mode, so this is done here rather than in the
  # markup. Update-in-place by uuid if it already exists, append otherwise.
  defp upsert_bank_account(accounts, account) do
    accounts =
      if account["primary"] do
        Enum.map(accounts, &Map.put(&1, "primary", false))
      else
        accounts
      end

    if Enum.any?(accounts, &(&1["uuid"] == account["uuid"])) do
      Enum.map(accounts, fn a -> if a["uuid"] == account["uuid"], do: account, else: a end)
    else
      accounts ++ [account]
    end
  end

  defp save_bank_accounts(accounts) do
    Settings.update_json_setting("company_bank_accounts", %{"accounts" => accounts})

    # Legacy single-account key, kept in sync for anything still reading
    # CountryData.get_bank_details/0 directly instead of going through
    # Organization.get_bank_details/0 (which now derives from this list).
    primary = Enum.find(accounts, & &1["primary"]) || List.first(accounts) || %{}

    Settings.update_json_setting("company_bank_details", %{
      "bank_name" => primary["bank_name"] || "",
      "iban" => primary["iban"] || "",
      "swift" => primary["swift"] || ""
    })
  end

  defp normalize_iban(iban) do
    iban |> String.replace(~r/\s/, "") |> String.upcase()
  end

  # ===================================
  # HELPERS
  # ===================================

  defp get_subdivision_label(nil), do: gettext("State/Province")
  defp get_subdivision_label(""), do: gettext("State/Province")

  defp get_subdivision_label(country_code) do
    CountryData.get_subdivision_label(country_code)
  end

  # `[]` (not a real select) rather than showing an empty dropdown when a
  # country has no subdivision data — the template falls back to free text
  # whenever this is empty, same contract as CountryData.subdivisions?/1.
  defp subdivisions_for(nil), do: []
  defp subdivisions_for(""), do: []
  defp subdivisions_for(country_code), do: CountryData.subdivisions_for_select(country_code)

  defp tax_id_label(nil), do: gettext("Tax ID")
  defp tax_id_label(""), do: gettext("Tax ID")
  defp tax_id_label(country_code), do: CountryData.tax_id_label(country_code)

  defp postal_code_label(nil), do: gettext("Postal Code")
  defp postal_code_label(""), do: gettext("Postal Code")
  defp postal_code_label(country_code), do: CountryData.postal_code_label(country_code)

  defp eu_country?(nil), do: false
  defp eu_country?(""), do: false
  defp eu_country?(country_code), do: CountryData.eu_member?(country_code)

  defp tax_id_placeholder("US", _eu_country?), do: "12-3456789"
  defp tax_id_placeholder("CA", _eu_country?), do: "123456789RT0001"
  defp tax_id_placeholder(country_code, true), do: "#{country_code}123456789"
  defp tax_id_placeholder(_country_code, false), do: gettext("Tax ID")

  defp postal_code_placeholder("US"), do: "10001"
  defp postal_code_placeholder("CA"), do: "K1A 0B1"
  defp postal_code_placeholder(_country_code), do: "10115"

  defp parse_tax_rate(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {value, _} -> if value == trunc(value), do: trunc(value), else: value
      :error -> 0
    end
  end

  defp parse_tax_rate(_), do: 0

  defp get_current_path(locale) do
    Routes.path("/admin/settings/organization", locale: locale)
  end

  # Broadcast settings change to all connected admin sessions
  defp broadcast_settings_change(type) do
    PubSubManager.broadcast(
      "organization:settings",
      {:organization_settings_changed, %{type: type, timestamp: UtilsDate.utc_now()}}
    )
  rescue
    # PubSub may not be available in all environments
    _ -> :ok
  end
end
