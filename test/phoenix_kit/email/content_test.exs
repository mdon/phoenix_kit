defmodule PhoenixKit.Email.ContentTest do
  use ExUnit.Case, async: true

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Email.Content

  @moduletag :tmp_dir

  # The real msgids core sends, so the assertions below break if a translation
  # is reworded rather than passing against copy invented for the test.
  defp defaults do
    fn ->
      %{
        subject: gettext("Confirm your account"),
        text:
          gettext("""
          Hi {{user_email}},

          You can confirm your account by visiting the URL below:

          {{confirmation_url}}

          If you didn't create an account with us, please ignore this.
          """)
      }
    end
  end

  defp user(locale), do: %{email: "a@b.c", custom_fields: %{"preferred_locale" => locale}}

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "resolve/4 without a host override" do
    test "evaluates the defaults inside the recipient's locale" do
      # The point of the whole exercise: the sender's locale is not the
      # recipient's, and these render on a process that has neither.
      assert Content.resolve("register", user("de"), %{}, defaults()).subject ==
               "Bestätigen Sie Ihr Konto"

      assert Content.resolve("register", user("ru"), %{}, defaults()).subject ==
               "Подтвердите ваш аккаунт"
    end

    test "substitutes variables into the translated body" do
      resolved =
        Content.resolve("register", user("de"), %{"user_email" => "a@b.c"}, defaults())

      assert resolved.text =~ "Hallo a@b.c,"
      # An unbound placeholder stays visible rather than blanking silently.
      assert resolved.text =~ "{{confirmation_url}}"
    end

    test "reports no database template on this path" do
      assert Content.resolve("register", user("de"), %{}, defaults()).db_template == nil
    end

    test "a recipient with no preference still resolves to a usable locale" do
      resolved = Content.resolve("register", "stranger@example.com", %{}, defaults())

      assert is_binary(resolved.subject) and resolved.subject != ""
    end
  end

  describe "resolve/4 with a host override" do
    test "an override replaces that part and leaves the others translated", %{tmp_dir: root} do
      write(root, "register", "text.txt", "Custom body for {{user_email}}.")

      resolved =
        Content.resolve("register", user("de"), %{"user_email" => "a@b.c"}, defaults(),
          paths: [root]
        )

      assert resolved.text == "Custom body for a@b.c."
      assert resolved.subject == "Bestätigen Sie Ihr Konto"
    end

    test "the recipient's locale selects among override files", %{tmp_dir: root} do
      write(root, "register", "text.txt", "fallback")
      write(root, "register", "text.de.txt", "deutscher Text")

      assert Content.resolve("register", user("de"), %{}, defaults(), paths: [root]).text ==
               "deutscher Text"

      assert Content.resolve("register", user("fr"), %{}, defaults(), paths: [root]).text ==
               "fallback"
    end
  end

  describe "override_paths/0" do
    test "always answers with a list" do
      # An unloaded parent application is the normal state inside a mix task,
      # where "no overrides" is the right answer and a crash is not.
      assert is_list(Content.override_paths())
    end
  end
end
