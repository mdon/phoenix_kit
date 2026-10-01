defmodule PhoenixKit.Email.CatalogTest do
  @moduledoc """
  The email catalog: which emails the system knows, and their previews.

  Core's emails come from `CoreTemplates`; modules add theirs through
  `email_templates/0`. A preview runs the same resolution as a send, so the
  checks here pin both the list and that the send and the preview share one
  copy.
  """

  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Email.CoreTemplates
  alias PhoenixKit.Mailer
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKit.Templates
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKit.Users.Auth.UserNotifier
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes

  @core_names ~w(register reset_password update_email magic_link magic_link_registration
                 organization_invitation new_login_alert failed_login_alert)

  defmodule EnabledEmailModule do
    @moduledoc false
    def enabled?, do: true
    def module_name, do: "Fixture Billing"

    def email_templates do
      [
        %{
          name: "fixture_invoice",
          label: "Invoice",
          defaults: fn -> %{subject: "Invoice {{number}}", markdown: "Pay [now]({{pay_url}})"} end,
          variables: %{"number" => "INV-1", "pay_url" => "https://pay.example.test/1"},
          layout: "billing"
        },
        # A name core already lists: core's entry stays.
        %{name: "register", label: "Hijacked"},
        # Not a template name: dropped.
        %{name: "_layout", label: "Reserved"},
        %{name: "Bad Name", label: "Spaces"},
        :not_a_map
      ]
    end
  end

  defmodule DisabledEmailModule do
    @moduledoc false
    def enabled?, do: false
    def email_templates, do: [%{name: "fixture_disabled", label: "Disabled"}]
  end

  defmodule WarnOnceEmailModule do
    @moduledoc false
    def enabled?, do: true

    def email_templates do
      [
        %{name: "Warn Once Bad", label: "x"},
        %{name: "warn_once_dup", label: "first"},
        %{name: "warn_once_dup", label: "second"},
        %{label: "no name"},
        "not a map"
      ]
    end
  end

  defmodule ThrowingEmailModule do
    @moduledoc false
    def enabled?, do: true
    def email_templates, do: throw(:no_list)
  end

  defmodule ExitingEmailModule do
    @moduledoc false
    def enabled?, do: true
    def email_templates, do: exit(:gone)
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "pk_catalog_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write(root, rel, content) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "entries/0" do
    test "lists core's emails first, in order, each with a label, defaults and samples" do
      entries = Catalog.entries()
      core = Enum.take(entries, length(@core_names))

      assert Enum.map(core, & &1.name) == @core_names

      for entry <- core do
        assert entry.module == nil
        assert is_binary(entry.label) and entry.label != ""
        assert is_function(entry.defaults, 0)
        assert is_function(entry.variables, 0)
      end
    end

    test "adds an enabled module's emails, tagged with the module; drops invalid ones" do
      ModuleRegistry.register(EnabledEmailModule)
      ModuleRegistry.register(DisabledEmailModule)

      try do
        entries = Catalog.entries()
        names = Enum.map(entries, & &1.name)

        assert %{module: EnabledEmailModule, layout: "billing"} =
                 Enum.find(entries, &(&1.name == "fixture_invoice"))

        # core wins a clash, and appears once
        assert Enum.count(names, &(&1 == "register")) == 1
        assert Catalog.get("register").label != "Hijacked"

        refute "_layout" in names
        refute "Bad Name" in names
        refute "fixture_disabled" in names
      after
        ModuleRegistry.unregister(EnabledEmailModule)
        ModuleRegistry.unregister(DisabledEmailModule)
      end
    end
  end

  describe "entries/0 robustness" do
    test "a module whose callback throws or exits leaves the list intact" do
      ModuleRegistry.register(ThrowingEmailModule)
      ModuleRegistry.register(ExitingEmailModule)

      try do
        capture_log(fn ->
          assert Enum.take(Catalog.entries(), 8) |> Enum.map(& &1.name) == @core_names
        end)
      after
        ModuleRegistry.unregister(ThrowingEmailModule)
        ModuleRegistry.unregister(ExitingEmailModule)
      end
    end

    test "a bad entry is warned about once, not on every call" do
      ModuleRegistry.register(WarnOnceEmailModule)

      try do
        first = capture_log(fn -> Catalog.entries() end)
        second = capture_log(fn -> Catalog.entries() end)

        assert first =~ ~s("Warn Once Bad")
        assert first =~ ~s("warn_once_dup")
        assert first =~ "has no name"
        assert first =~ "non-map entry"
        assert second == ""

        assert [%{label: "first"}] =
                 Enum.filter(Catalog.entries(), &(&1.name == "warn_once_dup"))
      after
        ModuleRegistry.unregister(WarnOnceEmailModule)
      end
    end
  end

  # The English copy is the msgid every translation is keyed on: changing a
  # word here silently reverts that email to English in every language until
  # the catalogues are updated. Change these literals only together with them.
  describe "core's default copy" do
    test "is exactly the copy the translations are keyed on" do
      Gettext.with_locale(PhoenixKitWeb.Gettext, "en", fn ->
        assert CoreTemplates.register_defaults() == %{
                 subject: "Confirm your account",
                 text: """
                 Hi {{user_email}},

                 You can confirm your account by visiting the URL below:

                 {{confirmation_url}}

                 If you didn't create an account with us, please ignore this.
                 """
               }

        assert CoreTemplates.reset_password_defaults() == %{
                 subject: "Reset your password",
                 text: """
                 Hi {{user_email}},

                 You can reset your password by visiting the URL below:

                 {{reset_url}}

                 If you didn't request this change, please ignore this.
                 """
               }

        assert CoreTemplates.update_email_defaults() == %{
                 subject: "Confirm your email change",
                 text: """
                 Hi {{user_email}},

                 You can change your email by visiting the URL below:

                 {{update_url}}

                 If you didn't request this change, please ignore this.
                 """
               }

        assert CoreTemplates.magic_link_defaults() == %{
                 subject: "Your secure login link",
                 text: """
                 Your login link: {{magic_link_url}}
                 This link expires in 15 minutes.
                 """
               }

        assert CoreTemplates.magic_link_registration_defaults() == %{
                 subject: "Complete your registration",
                 text: """
                 Hi {{user_email}},

                 Welcome! To complete your registration, please visit the URL below:

                 {{registration_url}}

                 This link will expire in 30 minutes for your security.

                 If you didn't request this registration, please ignore this email.
                 """
               }

        assert CoreTemplates.organization_invitation_defaults() == %{
                 subject: "You've been invited to join {{organization_name}}",
                 text: """
                 Hi {{user_email}},

                 {{organization_name}} has invited you to join their organization.

                 To accept the invitation, register an account by visiting the link below:

                 {{registration_url}}

                 This invitation link will expire in 7 days.

                 If you did not expect this invitation, you can safely ignore this email.
                 """
               }

        assert CoreTemplates.new_login_alert_defaults() == %{
                 subject: "New login to your account",
                 text: """
                 Hi {{user_email}},

                 We noticed a new login to your account from an unrecognized device:

                 Time: {{login_time}}
                 IP address: {{ip_address}}
                 Location: {{location}}
                 Device: {{browser_os}}

                 {{failed_attempts}}If this was you, no action is needed.

                 If you don't recognize this activity, secure your account here:

                 {{security_url}}
                 """
               }

        assert CoreTemplates.failed_login_alert_defaults() == %{
                 subject: "Failed sign-in attempts on your account",
                 text: """
                 Hi {{user_email}},

                 Someone has been trying to sign in to your account and failing.

                 Failed attempts: {{attempt_count}}
                 In the last: {{window_hours}} hour(s)

                 Nobody has signed in. You do not need to do anything if you recognize
                 this as your own mistyped password.

                 If you do not, your password may be being guessed. Change it to
                 something you do not use anywhere else:

                 {{security_url}}
                 """
               }
      end)
    end

    test "every core subject is translated (a changed msgid would fall back to English)" do
      for entry <- Enum.take(Catalog.entries(), 8), locale <- ["ru", "de", "et"] do
        english = Gettext.with_locale(PhoenixKitWeb.Gettext, "en", entry.defaults)
        translated = Gettext.with_locale(PhoenixKitWeb.Gettext, locale, entry.defaults)

        refute translated.subject == english.subject, "#{entry.name} subject in #{locale}"
        refute translated.text == english.text, "#{entry.name} text in #{locale}"
      end
    end
  end

  describe "preview/3 of core's emails" do
    for name <- ~w(register reset_password update_email magic_link magic_link_registration
                   organization_invitation new_login_alert failed_login_alert) do
      test "#{name}: every placeholder has a sample, and all three versions render" do
        entry = Catalog.get(unquote(name))

        for locale <- ["en", "ru"] do
          assert {:ok, preview} = Catalog.preview(entry, locale, paths: [])

          assert preview.missing == %{}, "unbound in #{locale}: #{inspect(preview.missing)}"
          assert preview.content.subject not in [nil, ""]
          refute preview.content.subject =~ "{{"
          refute preview.content.text =~ "{{"
          assert preview.content.html =~ "<!DOCTYPE html>"
          assert preview.sources.subject == :default
          assert preview.sources.text == :default
          assert preview.sources.html_from == :text
        end
      end
    end

    test "a dialect is rendered in its language, as a send to that reader is" do
      {:ok, %{content: %{subject: spanish}}} =
        Catalog.preview(Catalog.get("register"), "es", paths: [])

      refute spanish == "Confirm your account"

      for dialect <- ["es-ES", "es-MX"] do
        assert {:ok, %{content: %{subject: ^spanish}}} =
                 Catalog.preview(Catalog.get("register"), dialect, paths: [])
      end

      assert {:ok, email} =
               UserNotifier.deliver_confirmation_instructions(user("es-ES"), "https://x.test/c")

      assert email.subject == spanish
    end

    test "is rendered in the chosen language" do
      assert {:ok, %{content: %{subject: subject}}} =
               Catalog.preview(Catalog.get("register"), "ru", paths: [])

      refute subject == "Confirm your account"
    end
  end

  describe "preview/3 sources" do
    test "reports a host file with its path, and the group the email names" do
      root = tmp_root()
      subject = write(root, "register/subject.ru.txt", "Файл {{user_email}}\n")
      markdown = write(root, "register/markdown.md", "Hello [Confirm]({{confirmation_url}})")
      write(root, "register/layout.txt", "auth")
      header = write(root, "_header-auth/html.html", "<p>AUTH HEADER</p>")

      assert {:ok, preview} = Catalog.preview(Catalog.get("register"), "ru", paths: [root])

      assert preview.content.subject == "Файл jane.doe@example.com"
      assert preview.content.html =~ "AUTH HEADER"
      assert preview.sources.subject == {:file, subject}
      assert preview.sources.markdown == {:file, markdown}
      assert preview.sources.html_from == :markdown
      assert preview.sources.group == "auth"
      assert preview.sources.header == {:file, header}
      assert preview.sources.footer == :default
    end

    test "lists a placeholder the samples do not bind" do
      root = tmp_root()
      write(root, "register/text.txt", "Hi {{user_email}}, your code is {{code}}")

      assert {:ok, %{missing: %{text: ["code"]}}} =
               Catalog.preview(Catalog.get("register"), "en", paths: [root])
    end

    test "a module entry previews with its own defaults, samples and layout group" do
      entry = hd(EnabledEmailModule.email_templates())

      assert {:ok, preview} = Catalog.preview(entry, "en", paths: [])

      assert preview.content.subject == "Invoice INV-1"
      assert preview.content.html =~ ~s(href="https://pay.example.test/1")
      assert preview.sources.group == "billing"
      assert preview.sources.group_from == :option
    end

    test "an entry whose own function raises, throws or exits answers an error, not a crash" do
      capture_log(fn ->
        entry = %{name: "fixture_broken", label: "Broken", variables: fn -> raise "boom" end}
        assert {:error, "boom"} = Catalog.preview(entry, "en", paths: [])

        entry = %{name: "fixture_broken", label: "Broken", variables: fn -> throw(:nope) end}
        assert {:error, ":nope"} = Catalog.preview(entry, "en", paths: [])

        entry = %{name: "fixture_broken", label: "Broken", defaults: fn -> exit(:gone) end}
        assert {:error, ":gone"} = Catalog.preview(entry, "en", paths: [])
      end)
    end

    test "sample variables and defaults are evaluated in the previewed locale" do
      entry = %{
        name: "fixture_locale",
        label: "Locale",
        defaults: fn -> %{subject: "{{loc}}", text: Gettext.get_locale(PhoenixKitWeb.Gettext)} end,
        variables: fn -> %{"loc" => Gettext.get_locale(PhoenixKitWeb.Gettext)} end
      }

      assert {:ok, %{content: %{subject: "ru", text: "ru"}}} =
               Catalog.preview(entry, "ru", paths: [])
    end
  end

  describe "the send uses the catalog's defaults" do
    defp user(locale) do
      %User{
        uuid: Ecto.UUID.generate(),
        email: "reader@example.test",
        custom_fields: %{"preferred_locale" => locale}
      }
    end

    # What the send must produce if it renders `fun` — so copy that drifts
    # between a send site and CoreTemplates fails here.
    defp expected(name, recipient, variables, fun) do
      Content.resolve(name, recipient, variables, fun)
    end

    test "UserNotifier's emails" do
      u = user("de")
      url = "https://x.test/t"

      cases = [
        {fn -> UserNotifier.deliver_confirmation_instructions(u, url) end, "register",
         %{"user_email" => u.email, "confirmation_url" => url},
         &CoreTemplates.register_defaults/0},
        {fn -> UserNotifier.deliver_reset_password_instructions(u, url) end, "reset_password",
         %{"user_email" => u.email, "reset_url" => url},
         &CoreTemplates.reset_password_defaults/0},
        {fn -> UserNotifier.deliver_update_email_instructions(u, url) end, "update_email",
         %{"user_email" => u.email, "update_url" => url}, &CoreTemplates.update_email_defaults/0},
        {fn -> UserNotifier.deliver_magic_link_registration(u, url) end,
         "magic_link_registration", %{"user_email" => u.email, "registration_url" => url},
         &CoreTemplates.magic_link_registration_defaults/0},
        {fn -> UserNotifier.deliver_failed_login_alert(u, %{count: 4, window_hours: 1}) end,
         "failed_login_alert",
         %{
           "user_email" => u.email,
           "attempt_count" => "4",
           "window_hours" => "1",
           # built in the recipient's locale, as the send builds it
           "security_url" =>
             RecipientLocale.in_locale("de", fn ->
               Routes.base_url() <> Routes.user_settings_path()
             end)
         }, &CoreTemplates.failed_login_alert_defaults/0}
      ]

      for {send, name, variables, fun} <- cases do
        assert {:ok, email} = send.()
        want = expected(name, u, variables, fun)

        assert {email.subject, email.text_body, email.html_body} ==
                 {want.subject, want.text, want.html},
               name
      end
    end

    test "the organization invitation" do
      url = "https://x.test/o"
      assert {:ok, email} = UserNotifier.deliver_organization_invitation("a@x.test", "Acme", url)

      want =
        expected(
          "organization_invitation",
          "a@x.test",
          %{"user_email" => "a@x.test", "organization_name" => "Acme", "registration_url" => url},
          &CoreTemplates.organization_invitation_defaults/0
        )

      assert {email.subject, email.text_body} == {want.subject, want.text}
    end

    test "the magic link (Mailer's own send)" do
      u = user("en")
      url = "https://x.test/m"
      assert {:ok, _} = Mailer.send_magic_link_email(u, url)

      want =
        expected(
          "magic_link",
          u,
          %{"user_email" => u.email, "magic_link_url" => url},
          &CoreTemplates.magic_link_defaults/0
        )

      assert_email_sent(fn email ->
        assert {email.subject, email.text_body} == {want.subject, want.text}
      end)
    end

    # The send site names the template; a typo there would silently stop a
    # host's files from applying and point the preview's hints at the wrong
    # directory. Each send must pick up an override under its catalog name.
    test "every core send resolves under its catalog name" do
      root = tmp_root()

      for name <- @core_names, do: write(root, "#{name}/subject.txt", "OVERRIDE #{name}")

      previous = Application.get_env(:phoenix_kit, :template_paths)
      Application.put_env(:phoenix_kit, :template_paths, [root])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :template_paths, previous),
          else: Application.delete_env(:phoenix_kit, :template_paths)
      end)

      u = user("en")
      url = "https://x.test/t"
      at = ~U[2026-09-30 12:00:00Z]

      sends = %{
        "register" => fn -> UserNotifier.deliver_confirmation_instructions(u, url) end,
        "reset_password" => fn -> UserNotifier.deliver_reset_password_instructions(u, url) end,
        "update_email" => fn -> UserNotifier.deliver_update_email_instructions(u, url) end,
        "magic_link" => fn -> Mailer.send_magic_link_email(u, url) end,
        "magic_link_registration" => fn ->
          UserNotifier.deliver_magic_link_registration(u, url)
        end,
        "organization_invitation" => fn ->
          UserNotifier.deliver_organization_invitation(u.email, "Acme", url)
        end,
        "new_login_alert" => fn ->
          UserNotifier.deliver_new_login_alert(u, %{ip_address: "1.2.3.4", first_seen_at: at})
        end,
        "failed_login_alert" => fn ->
          UserNotifier.deliver_failed_login_alert(u, %{count: 3, window_hours: 1})
        end
      }

      assert Enum.sort(Map.keys(sends)) == Enum.sort(@core_names)

      for name <- @core_names do
        assert {:ok, _} = sends[name].()
        expected = "OVERRIDE #{name}"
        assert_email_sent(fn email -> assert email.subject == expected end)
      end
    end

    test "the new login alert's helper lines" do
      assert CoreTemplates.failed_attempts_note(0) == ""
      assert CoreTemplates.failed_attempts_note(1) =~ ~r/1 failed sign-in attempt on/
      assert CoreTemplates.failed_attempts_note(3) =~ ~r/\n\n\z/
      assert CoreTemplates.location_line("Tallinn") == "Tallinn (approximate)"
      assert CoreTemplates.location_line(nil) == "Unknown"

      # every placeholder of the default copy is one the send binds
      assert Templates.missing_variables(
               "new_login_alert",
               CoreTemplates.new_login_alert_defaults(),
               Map.new(
                 ~w(user_email login_time ip_address location browser_os failed_attempts security_url),
                 &{&1, "x"}
               )
             ) == %{}
    end
  end
end
