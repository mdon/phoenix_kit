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
      |> assign(:page_title, gettext("Organization Settings"))
      |> assign(:project_title, project_title)
      |> assign(:current_path, get_current_path(socket.assigns.current_locale_base))
      |> load_settings()

    {:ok, socket}
  end

  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_settings(socket) do
    company_info = get_company_info()
    bank_details = get_bank_details()

    socket
    |> assign_company_info(company_info)
    |> assign_country_data(company_info["country"])
    |> assign_tax_settings(company_info)
    |> assign_bank_details(bank_details)
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
    |> assign(:eu_country, eu_country?(country))
    |> assign(:country_priority, Settings.get_setting_cached("country_select_priority", ""))
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

  defp assign_bank_details(socket, details) do
    socket
    |> assign(:bank_name, details["bank_name"] || "")
    |> assign(:bank_iban, details["iban"] || "")
    |> assign(:bank_swift, details["swift"] || "")
  end

  # ===================================
  # EVENT HANDLERS
  # ===================================

  def handle_event("country_changed", %{"company_country" => country_code}, socket) do
    # Update suggested tax rate when country changes
    current_rate = parse_tax_rate(socket.assigns.tax_rate)

    suggested_rate =
      if country_code != "" do
        rate = CountryData.get_standard_vat_percent(country_code)
        if rate != 0 and rate != current_rate, do: rate
      end

    {:noreply,
     socket
     |> assign(:company_country, country_code)
     |> assign(:subdivision_label, get_subdivision_label(country_code))
     |> assign(:eu_country, eu_country?(country_code))
     |> assign(:suggested_tax_rate, suggested_rate)}
  end

  def handle_event("save_company", params, socket) do
    data = extract_company_data(params)

    # The country-priority list is an independent setting from the rest of
    # the company form — it must persist whether or not the company data
    # below validates, so it is saved unconditionally here rather than from
    # inside the `[] ->` branch.
    priority_result = save_country_priority(params["country_priority"])

    socket =
      case validate_company_data(data) do
        [] ->
          save_company_info(data, params)

          # Broadcast to all admin sessions
          broadcast_settings_change(:company_info_updated)

          socket
          |> load_settings()
          |> put_flash(:info, gettext("Organization information saved"))

        errors ->
          put_flash(socket, :error, Enum.join(errors, ". "))
      end

    {:noreply, put_country_priority_flash(socket, priority_result)}
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

  def handle_event("save_bank", params, socket) do
    iban = (params["bank_iban"] || "") |> String.trim()
    swift = (params["bank_swift"] || "") |> String.trim()
    country_code = socket.assigns.company_country

    errors =
      []
      |> validate_bank_iban(iban, country_code)
      |> validate_bank_swift(swift)

    case errors do
      [] ->
        save_bank_details(params, iban, swift)

        # Broadcast to all admin sessions
        broadcast_settings_change(:bank_details_updated)

        {:noreply,
         socket
         |> load_settings()
         |> put_flash(:info, gettext("Bank details saved"))}

      errors ->
        {:noreply, put_flash(socket, :error, Enum.join(Enum.reverse(errors), ". "))}
    end
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
  Gets bank details from consolidated key with fallback to legacy keys.
  """
  def get_bank_details do
    Map.merge(@default_bank_details, CountryData.get_bank_details())
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
      city: (params["company_city"] || "") |> String.trim()
    }
  end

  defp validate_company_data(data) do
    []
    |> validate_required(data.name, gettext("Company name is required"))
    |> validate_required(data.country, gettext("Country is required"))
    |> validate_required(data.vat, gettext("VAT number is required"))
    |> validate_required(data.address_line1, gettext("Street address is required"))
    |> validate_required(data.city, gettext("City is required"))
    |> validate_eu_vat(data.vat, data.country)
    |> Enum.reverse()
  end

  defp validate_required(errors, "", message), do: [message | errors]
  defp validate_required(errors, _value, _message), do: errors

  defp validate_eu_vat(errors, vat, country) when vat != "" and country != "" do
    if eu_country?(country) do
      if Regex.match?(~r/^[A-Z]{2}[0-9A-Z]{2,12}$/, String.upcase(vat)) do
        errors
      else
        [
          gettext("VAT number must be in EU format (e.g., %{country}123456789)", country: country)
          | errors
        ]
      end
    else
      errors
    end
  end

  defp validate_eu_vat(errors, _vat, _country), do: errors

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
        "state" => (params["company_state"] || "") |> String.trim(),
        "postal_code" => (params["company_postal_code"] || "") |> String.trim(),
        "country" => data.country,
        "vat_number" => String.upcase(data.vat),
        "registration_number" => (params["company_registration"] || "") |> String.trim()
      })

    Settings.update_json_setting("company_info", company_info)
  end

  # Stored normalized — upper-cased, deduplicated, unknown codes dropped — so
  # what the operator sees after saving is exactly what the dropdown will do.
  # Blank clears the setting, which hands the default back to
  # `config :phoenix_kit, :country_select_priority`. Typing the literal word
  # "none" (case-insensitive, trimmed — `CountryData.none_priority?/1`)
  # stores the sentinel `CountryData.configured_priority/0` honours over
  # that config, so it must be checked BEFORE `known_country_codes/1` runs —
  # "none" is not a real country code and would otherwise be silently
  # dropped just like any other unknown one, storing blank instead of the
  # sentinel and leaving pinning impossible to turn off.
  #
  # Returns `{:ok, %{kept: [...], rejected: [...]}}` — the codes actually
  # stored and the ones the operator typed that name no real country, for
  # the caller to report — or `{:error, changeset}` if the write itself
  # failed (e.g. over the settings value's 1000-character cap).
  defp save_country_priority(value) do
    trimmed = (value || "") |> String.trim()

    if CountryData.none_priority?(trimmed) do
      write_country_priority(CountryData.none_priority_value(), %{kept: [], rejected: []})
    else
      typed = CountryData.parse_priority(trimmed)
      known = CountryData.known_country_codes(typed)
      rejected = typed -- known

      write_country_priority(Enum.join(known, ", "), %{kept: known, rejected: rejected})
    end
  end

  defp write_country_priority(stored_value, outcome) do
    case Settings.update_setting("country_select_priority", stored_value) do
      {:ok, _setting} -> {:ok, outcome}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # A partial drop still saved something, so it rides alongside whatever
  # flash the company-info save already produced. A total drop (something
  # was typed, nothing survived) gets the same treatment — it must not be
  # silently folded into an unqualified "saved" flash — but says so plainly
  # rather than implying a partial success. Both are :error, matching this
  # LiveView's only two flash kinds; company_info's own flash is untouched
  # either way.
  defp put_country_priority_flash(socket, {:ok, %{rejected: []}}), do: socket

  defp put_country_priority_flash(socket, {:ok, %{kept: [], rejected: rejected}}) do
    put_flash(
      socket,
      :error,
      gettext(
        "None of the preferred-country codes you entered are valid, so preferred countries was cleared: %{codes}",
        codes: Enum.join(rejected, ", ")
      )
    )
  end

  defp put_country_priority_flash(socket, {:ok, %{rejected: rejected}}) do
    put_flash(
      socket,
      :error,
      gettext("Preferred countries saved, but ignored unrecognized code(s): %{codes}",
        codes: Enum.join(rejected, ", ")
      )
    )
  end

  defp put_country_priority_flash(socket, {:error, _changeset}) do
    put_flash(socket, :error, gettext("Preferred countries could not be saved"))
  end

  defp save_bank_details(params, iban, swift) do
    bank_details = %{
      "bank_name" => (params["bank_name"] || "") |> String.trim(),
      "iban" => normalize_iban(iban),
      "swift" => String.upcase(swift)
    }

    Settings.update_json_setting("company_bank_details", bank_details)
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

  defp eu_country?(nil), do: false
  defp eu_country?(""), do: false
  defp eu_country?(country_code), do: CountryData.eu_member?(country_code)

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
