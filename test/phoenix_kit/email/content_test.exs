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

  defp text_only(text), do: fn -> %{subject: "Hello <you>", text: text} end

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

  describe "resolve/5 and the shared layout" do
    test "a text-only message gets an HTML body: layout, escaped paragraphs, a link" do
      resolved =
        Content.resolve(
          "layout_probe",
          user("en"),
          %{"name" => ~s[<script>alert("x")</script>], "url" => "https://example.test/c/abc"},
          text_only("Hi {{name}},\n\nOpen {{url}}.\nOr javascript:alert(1)\n")
        )

      html = resolved.html

      # Core's layout around the body.
      assert html =~ "<!DOCTYPE html>"
      assert html =~ "<title>Hello &lt;you&gt;</title>"
      # The variable's markup and quotes are text, not HTML.
      refute html =~ "<script>"
      assert html =~ "Hi &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;,</p>"
      assert html =~ ~s(<a href="https://example.test/c/abc">https://example.test/c/abc</a>.<br>)
      refute html =~ ~s(href="javascript)

      # The text and subject are what they always were.
      assert resolved.text ==
               ~s[Hi <script>alert("x")</script>,\n\nOpen https://example.test/c/abc.\nOr javascript:alert(1)\n]

      assert resolved.subject == "Hello <you>"
    end

    test "core's own translated default arrives as HTML in the reader's language" do
      html =
        Content.resolve(
          "register",
          user("de"),
          %{"user_email" => "a@b.c", "confirmation_url" => "https://example.test/c"},
          defaults()
        ).html

      assert html =~ "<title>Bestätigen Sie Ihr Konto</title>"
      assert html =~ "Hallo a@b.c,"
      assert html =~ ~s(<a href="https://example.test/c">)
    end

    test "layout: false leaves a text-only message without HTML" do
      resolved =
        Content.resolve("layout_probe", user("en"), %{}, text_only("body"), layout: false)

      assert resolved.html == nil
      assert resolved.text == "body"
    end

    test "an html fragment is wrapped, its own markup kept", %{tmp_dir: root} do
      write(root, "fragment_probe", "html.html", "<p class=\"x\">Hi {{name}}</p>")

      resolved =
        Content.resolve("fragment_probe", user("en"), %{"name" => "<b>"}, text_only("t"),
          paths: [root]
        )

      assert resolved.html =~ "<!DOCTYPE html>"
      assert resolved.html =~ ~s(<p class="x">Hi &lt;b&gt;</p>)
      assert resolved.text == "t"
    end

    test "a whole html document is left alone", %{tmp_dir: root} do
      document = "  <!doctype html>\n<html><body>Own chrome</body></html>"
      write(root, "document_probe", "html.html", document)

      assert Content.resolve("document_probe", user("en"), %{}, text_only("t"), paths: [root]).html ==
               document
    end

    test "layout: false leaves a fragment as it was", %{tmp_dir: root} do
      write(root, "fragment_off_probe", "html.html", "<p>bare</p>")

      assert Content.resolve("fragment_off_probe", user("en"), %{}, text_only("t"),
               paths: [root],
               layout: false
             ).html == "<p>bare</p>"
    end

    test "a whole document behind a byte-order mark and a comment is left alone",
         %{tmp_dir: root} do
      document = "\uFEFF<!-- exported -->\n<!DOCTYPE html><html><body>Own</body></html>"
      write(root, "bom_document_probe", "html.html", document)

      assert Content.resolve("bom_document_probe", user("en"), %{}, text_only("t"), paths: [root]).html ==
               document
    end

    test "an empty html file counts as no html: the text is wrapped", %{tmp_dir: root} do
      write(root, "empty_html_probe", "html.html", "")

      html =
        Content.resolve("empty_html_probe", user("en"), %{}, text_only("from text"),
          paths: [root]
        ).html

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "from text</p>"
    end

    test "blank html and blank text resolve to nil" do
      resolved =
        Content.resolve("blank_probe", user("en"), %{}, fn ->
          %{subject: "s", text: "", html: "  \n"}
        end)

      assert resolved.html == nil
      assert resolved.text == nil
    end

    test "a blank part is no part without the layout either", %{tmp_dir: root} do
      write(root, "blank_off_probe", "html.html", "")

      resolved =
        Content.resolve("blank_off_probe", user("en"), %{}, fn -> %{subject: "s", text: " "} end,
          paths: [root],
          layout: false
        )

      assert %{html: nil, text: nil} = resolved
    end

    test "the layout resolves from the message's own roots and reader locale",
         %{tmp_dir: root} do
      write(root, "_layout", "html.html", "ANY[{{{content}}}]")
      write(root, "_layout", "html.de.html", "DE[{{{content}}}]")

      assert Content.resolve("layout_locale_probe", user("de"), %{}, text_only("body"),
               paths: [root]
             ).html =~ ~r/\ADE\[<p[^>]*>body<\/p>\]\z/

      assert Content.resolve("layout_locale_probe", user("fr"), %{}, text_only("body"),
               paths: [root]
             ).html =~ ~r/\AANY\[/

      # The :locale option wins over the recipient's own preference.
      assert Content.resolve("layout_locale_probe", user("fr"), %{}, text_only("body"),
               paths: [root],
               locale: "de"
             ).html =~ ~r/\ADE\[/
    end

    test "nothing to wrap leaves every part nil" do
      resolved = Content.resolve("empty_probe", user("en"), %{}, fn -> %{} end)

      assert %{subject: nil, text: nil, html: nil} = resolved
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
