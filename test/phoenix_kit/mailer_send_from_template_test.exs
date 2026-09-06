defmodule PhoenixKit.MailerSendFromTemplateTest do
  @moduledoc """
  `send_from_template/4` after it stopped depending on the templates table.

  It is core's generic host-facing send API, and it is what
  `phoenix_kit_billing` reaches through for its invoice, receipt, credit-note
  and payment-confirmation emails. Before this, a name with no database row
  answered `{:error, :template_not_found}` — so retiring the table would have
  stopped those emails silently, with an error shape the caller already
  tolerates.
  """
  use PhoenixKit.DataCase, async: false

  import Swoosh.TestAssertions

  alias PhoenixKit.Mailer

  defp defaults do
    %{subject: "Your invoice", text: "Invoice {{invoice_number}} is ready."}
  end

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "with no database template" do
    test "a name that nothing answers is still template_not_found" do
      # The contract every existing caller holds. Nothing about this release
      # should make an unknown name look like a successful send.
      assert Mailer.send_from_template("no_such_template_#{System.unique_integer()}", "a@b.c") ==
               {:error, :template_not_found}
    end

    test "supplied defaults make the name resolve and send" do
      assert {:ok, _} =
               Mailer.send_from_template(
                 "billing_invoice_probe",
                 "a@b.c",
                 %{"invoice_number" => "INV-1"},
                 defaults: defaults()
               )

      assert_email_sent(fn email ->
        assert email.subject == "Your invoice"
        assert email.text_body == "Invoice INV-1 is ready."
      end)
    end

    test "defaults may be a function, evaluated in the recipient's locale" do
      # The shape billing wants: gettext content must be evaluated inside the
      # recipient's locale, not whatever locale the caller happened to be in.
      assert {:ok, _} =
               Mailer.send_from_template("probe_fun", "a@b.c", %{},
                 defaults: fn -> %{subject: "From a function", text: "body"} end
               )

      assert_email_sent(fn email -> assert email.subject == "From a function" end)
    end

    @tag :tmp_dir
    test "a host override file wins over the caller's defaults", %{tmp_dir: root} do
      write(root, "override_probe", "text.txt", "From the host's own file.")

      assert {:ok, _} =
               Mailer.send_from_template("override_probe", "a@b.c", %{},
                 defaults: %{subject: "Default subject", text: "Default body"},
                 paths: [root]
               )

      assert_email_sent(fn email ->
        assert email.text_body == "From the host's own file."
        # Only the overridden part is replaced.
        assert email.subject == "Default subject"
      end)
    end

    @tag :tmp_dir
    test "the locale option selects among override files", %{tmp_dir: root} do
      write(root, "locale_probe", "text.txt", "fallback")
      write(root, "locale_probe", "text.de.txt", "deutscher Text")

      assert {:ok, _} =
               Mailer.send_from_template("locale_probe", "a@b.c", %{},
                 defaults: %{subject: "s", text: "d"},
                 paths: [root],
                 locale: "de"
               )

      assert_email_sent(fn email -> assert email.text_body == "deutscher Text" end)
    end
  end
end
