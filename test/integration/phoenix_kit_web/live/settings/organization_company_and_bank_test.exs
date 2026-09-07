defmodule PhoenixKitWeb.Live.Settings.OrganizationCompanyAndBankTest do
  use PhoenixKitWeb.ConnCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Live.Settings.Organization

  # Settings are a single global row, not per-test isolated (same reason
  # organization_main_countries_test.exs resets country_select_priority
  # itself) — clear company_info before every test so one test's saved
  # country/state/vat can't leak into the next.
  setup do
    Settings.delete_setting("company_info")
    :ok
  end

  defp mount_organization do
    {admin, _token} = create_admin_user()
    conn = log_in_user(build_conn(), admin)
    {:ok, lv, _html} = live(conn, Routes.path("/admin/settings/organization"))
    lv
  end

  defp submit_company(lv, params) do
    lv
    |> element(~s(form[phx-submit="save_company"]))
    |> render_submit(params)
  end

  defp submit_bank_account(lv, params) do
    lv
    |> element(~s(form[phx-submit="save_bank_account"]))
    |> render_submit(params)
  end

  defp base_company_params(overrides) do
    Map.merge(
      %{
        "company_name" => "Acme Inc",
        "company_country" => "US",
        "company_address_line1" => "123 Main St",
        "company_city" => "Springfield",
        "company_vat" => "12-3456789",
        "company_state" => "IL",
        "company_postal_code" => "62701"
      },
      overrides
    )
  end

  describe "Company Information — US" do
    test "renders a state <select> populated with US states, not free text" do
      lv = mount_organization()
      html = render_click(lv, "country_changed", %{"company_country" => "US"})

      assert html =~ ~s(name="company_state")
      assert html =~ "<select"
      assert html =~ "California"
      assert html =~ ~s(value="CA")
    end

    test "labels the tax field EIN and the postal field ZIP Code" do
      lv = mount_organization()
      html = render_click(lv, "country_changed", %{"company_country" => "US"})

      assert html =~ "EIN"
      assert html =~ "ZIP Code"
    end

    test "saves successfully with a valid EIN, US state code, and ZIP" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "US"})

      html = submit_company(lv, base_company_params(%{}))

      assert html =~ "Organization information saved"
      info = Organization.get_company_info()
      assert info["country"] == "US"
      assert info["state"] == "IL"
      assert info["postal_code"] == "62701"
      assert info["vat_number"] == "12-3456789"
    end

    test "rejects a malformed EIN" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "US"})

      html = submit_company(lv, base_company_params(%{"company_vat" => "not an ein"}))

      assert html =~ "EIN"
      refute html =~ "Organization information saved"
    end

    test "rejects a malformed ZIP code" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "US"})

      html = submit_company(lv, base_company_params(%{"company_postal_code" => "not a zip"}))

      assert html =~ "ZIP Code"
      refute html =~ "Organization information saved"
    end

    test "rejects a state code that isn't a real US state" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "US"})

      html = submit_company(lv, base_company_params(%{"company_state" => "ZZ"}))

      refute html =~ "Organization information saved"
    end
  end

  describe "Company Information — Canada" do
    test "renders a province/territory <select>, labels BN and Postal Code" do
      lv = mount_organization()
      html = render_click(lv, "country_changed", %{"company_country" => "CA"})

      assert html =~ ~s(name="company_state")
      assert html =~ "Ontario"
      assert html =~ ~s(value="ON")
      assert html =~ "Business Number (BN)"
      assert html =~ "Postal Code"
    end

    test "saves successfully with a valid BN, province code, and postal code" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "CA"})

      html =
        submit_company(
          lv,
          base_company_params(%{
            "company_country" => "CA",
            "company_state" => "ON",
            "company_vat" => "123456789RT0001",
            "company_postal_code" => "K1A 0B1"
          })
        )

      assert html =~ "Organization information saved"
      info = Organization.get_company_info()
      assert info["state"] == "ON"
      assert info["postal_code"] == "K1A 0B1"
    end

    test "rejects a malformed Business Number" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "CA"})

      html =
        submit_company(
          lv,
          base_company_params(%{
            "company_country" => "CA",
            "company_state" => "ON",
            "company_vat" => "not a bn",
            "company_postal_code" => "K1A 0B1"
          })
        )

      refute html =~ "Organization information saved"
    end
  end

  describe "Company Information — everywhere else" do
    test "a country with no subdivision data keeps the free-text state field" do
      lv = mount_organization()
      html = render_click(lv, "country_changed", %{"company_country" => "VA"})

      refute html =~ ~s(name="company_state" type="hidden")
      # No <select name="company_state"> — falls through to <.input>.
      refute html =~ ~s(<select\n      id="company_state")
    end

    test "a non-EU, non-US, non-CA country gets the generic Tax ID label and no format check" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "JP"})

      html =
        submit_company(
          lv,
          base_company_params(%{
            "company_country" => "JP",
            "company_state" => "",
            "company_vat" => "anything at all",
            "company_postal_code" => "100-0001"
          })
        )

      assert html =~ "Organization information saved"
    end

    test "an EU country still requires EU VAT format" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "DE"})

      html =
        submit_company(
          lv,
          base_company_params(%{
            "company_country" => "DE",
            "company_state" => "",
            "company_vat" => "not a vat number",
            "company_postal_code" => "10115"
          })
        )

      refute html =~ "Organization information saved"

      html2 =
        submit_company(
          lv,
          base_company_params(%{
            "company_country" => "DE",
            "company_state" => "",
            "company_vat" => "DE123456789",
            "company_postal_code" => "10115"
          })
        )

      assert html2 =~ "Organization information saved"
    end

    test "switching country clears a previously-chosen state" do
      lv = mount_organization()
      render_click(lv, "country_changed", %{"company_country" => "US"})
      submit_company(lv, base_company_params(%{}))
      assert Organization.get_company_info()["state"] == "IL"

      render_click(lv, "country_changed", %{"company_country" => "DE"})

      # No "company_state" in this submit — the real form would have reset
      # to blank client-side too, since the <.select>'s stale "IL" value no
      # longer matches any option in Germany's subdivision list.
      submit_company(
        lv,
        base_company_params(%{
          "company_country" => "DE",
          "company_vat" => "DE123456789",
          "company_postal_code" => "10115"
        })
        |> Map.delete("company_state")
      )

      assert Organization.get_company_info()["state"] == ""
    end
  end

  describe "Bank Accounts" do
    # Settings are a single global row, not per-test isolated (same reason
    # organization_main_countries_test.exs resets country_select_priority
    # itself) — clear both the list and the legacy single-account key before
    # every test so one test's accounts can't leak into the next.
    setup do
      Settings.delete_setting("company_bank_accounts")
      Settings.delete_setting("company_bank_details")
      :ok
    end

    defp bank_params(overrides) do
      Map.merge(
        %{
          "account_label" => "EUR account",
          "bank_name" => "Test Bank",
          "iban" => "EE382200221020145685",
          "swift" => "HABAEE2X",
          "primary" => "true"
        },
        overrides
      )
    end

    test "starts empty" do
      lv = mount_organization()
      assert render(lv) =~ "No bank accounts added yet"
    end

    test "adding an account persists it and shows it in the list" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})
      html = submit_bank_account(lv, bank_params(%{}))

      assert html =~ "Bank account saved"
      assert html =~ "EUR account"
      assert html =~ "Test Bank"

      [account] = Organization.get_bank_accounts()
      assert account["bank_name"] == "Test Bank"
      assert account["iban"] == "EE382200221020145685"
      assert account["primary"] == true
      assert is_binary(account["uuid"])
    end

    test "a company can have more than one account" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})

      submit_bank_account(
        lv,
        bank_params(%{"account_label" => "EUR account", "primary" => "true"})
      )

      render_click(lv, "show_add_bank_account_form", %{})

      html =
        submit_bank_account(
          lv,
          bank_params(%{
            "account_label" => "USD account",
            "iban" => "",
            "swift" => "",
            "primary" => "false"
          })
        )

      assert html =~ "EUR account"
      assert html =~ "USD account"
      assert length(Organization.get_bank_accounts()) == 2
    end

    test "marking a new account primary un-sets the previous primary" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})

      submit_bank_account(
        lv,
        bank_params(%{"account_label" => "EUR account", "primary" => "true"})
      )

      render_click(lv, "show_add_bank_account_form", %{})

      submit_bank_account(
        lv,
        bank_params(%{"account_label" => "USD account", "primary" => "true"})
      )

      accounts = Organization.get_bank_accounts()
      primaries = Enum.filter(accounts, & &1["primary"])
      assert length(primaries) == 1
      assert hd(primaries)["label"] == "USD account"
    end

    test "editing an account updates it in place rather than adding a new row" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})
      submit_bank_account(lv, bank_params(%{}))

      [account] = Organization.get_bank_accounts()

      render_click(lv, "show_edit_bank_account_form", %{"uuid" => account["uuid"]})
      submit_bank_account(lv, bank_params(%{"bank_name" => "Renamed Bank"}))

      accounts = Organization.get_bank_accounts()
      assert length(accounts) == 1
      assert hd(accounts)["bank_name"] == "Renamed Bank"
      assert hd(accounts)["uuid"] == account["uuid"]
    end

    test "deleting an account removes it" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})
      submit_bank_account(lv, bank_params(%{}))

      [account] = Organization.get_bank_accounts()

      html = render_click(lv, "delete_bank_account", %{"uuid" => account["uuid"]})

      assert html =~ "Bank account removed"
      assert Organization.get_bank_accounts() == []
    end

    test "rejects a malformed IBAN" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})
      html = submit_bank_account(lv, bank_params(%{"iban" => "not an iban"}))

      refute html =~ "Bank account saved"
    end

    test "bank name is required" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})
      html = submit_bank_account(lv, bank_params(%{"bank_name" => ""}))

      refute html =~ "Bank account saved"
    end

    test "get_bank_details/0 (phoenix_kit_billing's integration point) returns the primary account" do
      lv = mount_organization()

      render_click(lv, "show_add_bank_account_form", %{})

      submit_bank_account(
        lv,
        bank_params(%{"account_label" => "EUR account", "primary" => "false"})
      )

      render_click(lv, "show_add_bank_account_form", %{})

      submit_bank_account(
        lv,
        bank_params(%{"account_label" => "USD account", "primary" => "true"})
      )

      details = Organization.get_bank_details()
      assert details["bank_name"] == "Test Bank"
      assert Map.has_key?(details, "iban")
      assert Map.has_key?(details, "swift")
    end

    test "legacy single-account settings migrate transparently into the accounts list" do
      Settings.update_json_setting("company_bank_details", %{
        "bank_name" => "Legacy Bank",
        "iban" => "EE382200221020145685",
        "swift" => "HABAEE2X"
      })

      lv = mount_organization()
      html = render(lv)

      assert html =~ "Legacy Bank"
      [account] = Organization.get_bank_accounts()
      assert account["bank_name"] == "Legacy Bank"
      assert account["primary"] == true

      details = Organization.get_bank_details()
      assert details["bank_name"] == "Legacy Bank"
    end
  end
end
