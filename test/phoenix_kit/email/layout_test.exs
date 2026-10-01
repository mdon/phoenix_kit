defmodule PhoenixKit.Email.LayoutTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKit.Email.Layout
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  @moduletag :tmp_dir

  # Host `_layout` files need phoenix_kit_templates 0.2.1; see the module.
  @needs_underscore_names PhoenixKit.Test.UnderscoreTemplateNames.skip_reason()

  defp write(root, name, file, content) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), content)
  end

  describe "text_to_html/1" do
    test "a blank line starts a paragraph, a single line break becomes <br>" do
      assert Layout.text_to_html("one\ntwo\n\nthree\n") ==
               ~s(<p style="margin:0 0 16px;">one<br>\ntwo</p>\n) <>
                 ~s(<p style="margin:0 0 16px;">three</p>)
    end

    test "CRLF line endings and whitespace-only separator lines count the same" do
      assert Layout.text_to_html("one\r\ntwo\r\n  \r\nthree") ==
               Layout.text_to_html("one\ntwo\n\nthree")
    end

    test "every character of the text is escaped" do
      html = Layout.text_to_html(~s[Hi <script>alert("x")</script> & 'you'])

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; &#39;you&#39;"
    end

    test "an http(s) address becomes a link; the full stop after it does not" do
      html = Layout.text_to_html("Open https://example.com/c/abc?x=1&y=2. Or http://a.test")

      assert html =~
               ~s(<a href="https://example.com/c/abc?x=1&amp;y=2">https://example.com/c/abc?x=1&amp;y=2</a>.)

      assert html =~ ~s(<a href="http://a.test">http://a.test</a>)
    end

    test "a closing parenthesis stays inside the link only when the link opened one" do
      assert Layout.text_to_html("(see https://a.test/x)") =~
               ~s{(see <a href="https://a.test/x">https://a.test/x</a>)}

      assert Layout.text_to_html("https://a.test/Foo_(bar)") =~
               ~s{<a href="https://a.test/Foo_(bar)">}
    end

    test "an address cannot break out of the href attribute" do
      html = Layout.text_to_html(~s(https://a.test/"onmouseover="x https://b.test/'q))

      # `"` ends the address; `'` is part of it but escaped inside the attribute.
      assert html =~ ~s(<a href="https://a.test/">https://a.test/</a>&quot;onmouseover=)
      assert html =~ ~s(<a href="https://b.test/&#39;q">)
    end

    test "no other scheme becomes a link" do
      html =
        Layout.text_to_html("javascript:alert(1) data:text/html,x ftp://a.test mailto:a@b.c")

      refute html =~ "<a"
      assert html =~ "javascript:alert(1)"
    end

    test "an address ends at Unicode whitespace and CJK/fullwidth punctuation" do
      for separator <- ["\u00A0", "\u2028", "\u3000", "\u3002", "\uFF0C", "\u200A"] do
        html = Layout.text_to_html("https://a.test/x" <> separator <> "tail")

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x</a>),
               "separator #{inspect(separator)}: #{html}"

        refute html =~ "tail</a>"
      end
    end

    test "non-ASCII letters stay part of the address" do
      assert Layout.text_to_html("https://de.wikipedia.org/wiki/Köln") =~
               ~s(<a href="https://de.wikipedia.org/wiki/Köln">)
    end

    test "an address ends at typographic quotes, guillemets, dashes, an ellipsis" do
      for {text, after_link} <- [
            {"«https://a.test/x»", "</a>»"},
            {"“https://a.test/x”", "</a>”"},
            {"‘https://a.test/x’", "</a>’"},
            {"https://a.test/x…", "</a>…"},
            {"https://a.test/x—next", "</a>—next"},
            {"https://a.test/x–next", "</a>–next"},
            {"https://a.test/x\u200Bnext", "</a>\u200Bnext"}
          ] do
        html = Layout.text_to_html(text)

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x) <> after_link,
               "#{inspect(text)}: #{html}"
      end
    end

    test "a long run of punctuation after an address neither raises nor stalls" do
      for text <- [
            "https://a.test/" <> String.duplicate(".", 5000) <> "a",
            "see https://a.test/x" <> String.duplicate("!", 5000) <> "wow",
            "https://a.test/x" <> String.duplicate(".", 20_000)
          ] do
        {microseconds, html} = :timer.tc(fn -> Layout.text_to_html(text) end)

        assert is_binary(html)
        assert microseconds < 500_000
      end
    end

    test "trailing punctuation is split off in time linear in its length" do
      for text <- [
            "https://a.test/x" <> String.duplicate(")", 50_000),
            "https://a.test/x" <> String.duplicate(".)", 20_000)
          ] do
        {microseconds, html} = :timer.tc(fn -> Layout.text_to_html(text) end)

        assert html =~ ~s(<a href="https://a.test/x">https://a.test/x</a>)
        assert microseconds < 500_000
      end
    end

    test "an address longer than 2 KB stays text" do
      long = "https://a.test/" <> String.duplicate("a", 2100)
      html = Layout.text_to_html(long)

      refute html =~ "<a"
      assert html =~ long
    end

    test "a line that is not valid UTF-8 is escaped whole instead of raising" do
      html = Layout.text_to_html(<<"<b> https://a.test/ ", 0xFF>>)

      assert html =~ "&lt;b&gt;"
      refute html =~ "<a"
    end

    test "empty text is no paragraphs at all" do
      assert Layout.text_to_html("") == ""
      assert Layout.text_to_html("\n\n  \n") == ""
    end
  end

  describe "document?/1" do
    test "a doctype or an html element opens a whole document" do
      assert Layout.document?("<!DOCTYPE html><html></html>")
      assert Layout.document?("  \n<!doctype html>")
      assert Layout.document?("<HTML lang=\"en\">")
      assert Layout.document?("<html>")
    end

    test "a byte-order mark, comments, an XML prolog and any whitespace come first" do
      assert Layout.document?("\uFEFF<!DOCTYPE html><html></html>")
      assert Layout.document?("<!-- exported 2026-09-30 --><html>")
      assert Layout.document?(~s(<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>))
      assert Layout.document?("\u00A0\u2003<html>")
      assert Layout.document?("\uFEFF \n<!-- a -->\n<!-- b --> <?xml?><html lang=\"de\">")
    end

    test "a comment or prolog before a fragment is still a fragment" do
      refute Layout.document?("<!-- note --><p>Hi</p>")
      refute Layout.document?("<?xml version=\"1.0\"?><p>Hi</p>")
      refute Layout.document?("<!-- never closed <html>")
    end

    test "anything else is a fragment" do
      refute Layout.document?("<p>Hi</p>")
      refute Layout.document?("<htmlish>")
      refute Layout.document?("Text mentioning <html> later")
      refute Layout.document?("")
    end
  end

  describe "default_html/0" do
    test "carries no words of its own, so it needs no translation" do
      words =
        Layout.default_html()
        |> String.replace(~r/<[^>]*>/s, " ")
        |> String.replace(~r/\{\{\{?\s*\w+\s*\}?\}\}/, " ")
        |> String.trim()

      assert words == ""
    end

    test "names the document's language only for a well-formed tag" do
      assert Layout.default_html(locale: "de") =~ ~s(<html lang="de">)
      assert Layout.default_html(locale: "pt-BR") =~ ~s(<html lang="pt-BR">)
      assert Layout.default_html(locale: "pt_BR") =~ ~s(<html lang="pt-BR">)
      assert Layout.default_html() =~ "<html>\n"
      assert Layout.default_html(locale: ~s(de" onload="x)) =~ "<html>\n"
    end

    test "links the site unless told not to" do
      assert Layout.default_html() =~ ~s(<a href="{{site_url}}")
      refute Layout.default_html(link: false) =~ "<a "
      assert Layout.default_html(link: false) =~ "{{site_url}}"
    end

    test "carries bgcolor for clients that drop CSS backgrounds, and an Outlook width" do
      html = Layout.default_html()

      assert html =~ ~s(bgcolor="#f4f4f5")
      assert html =~ ~s(bgcolor="#ffffff")
      assert html =~ "<!--[if mso]>"
    end

    test "is table markup with inline styles and nothing loaded from outside" do
      html = Layout.default_html()

      assert html =~ "<table role=\"presentation\""
      assert html =~ "max-width:600px"
      refute html =~ "<style"
      refute html =~ "<link"
      refute html =~ ~r/src=/
      refute html =~ "url("
    end
  end

  describe "wrap/3 with core's default layout" do
    test "puts the body in raw and escapes the subject" do
      html = Layout.wrap("<p>Body &amp; soul</p>", ~s(Tom & "Jerry" <b>))

      assert html =~ "<p>Body &amp; soul</p>"
      assert html =~ "<title>Tom &amp; &quot;Jerry&quot; &lt;b&gt;</title>"
    end

    test "names and links the site, from the settings core already has" do
      # This process owns no database connection: Settings answers from its
      # fallbacks rather than crashing, and so does the layout.
      html = Layout.wrap("<p>x</p>", "s")

      site_name = Settings.get_project_title()
      site_url = Routes.base_url()

      assert is_binary(site_name) and site_name != ""
      assert is_binary(site_url) and site_url != ""
      assert html =~ ">#{Phoenix.HTML.html_escape(site_name) |> Phoenix.HTML.safe_to_string()}<"
      assert html =~ ~s(href="#{site_url}")
    end

    test "the reader's locale becomes the document's language" do
      assert Layout.wrap("<p>x</p>", "s", locale: "et") =~ ~s(<html lang="et">)
    end

    test "a nil subject leaves an empty title rather than a placeholder" do
      html = Layout.wrap("<p>x</p>", nil)

      assert html =~ "<title></title>"
      refute html =~ "{{"
    end

    test "an override root with no _layout still gets the default", %{tmp_dir: root} do
      assert Layout.wrap("<p>x</p>", "s", paths: [root]) == Layout.wrap("<p>x</p>", "s")
    end
  end

  describe "wrap/3 with a host _layout" do
    @tag skip: @needs_underscore_names
    test "the host's file replaces core's layout", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{content}}}</main>")

      assert Layout.wrap("<p>x</p>", "s", paths: [root]) == "<main><p>x</p></main>"
    end

    @tag skip: @needs_underscore_names
    test "a locale file wins for its readers, the rest fall back", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "any:{{{content}}}")
      write(root, "_layout", "html.de.html", "de:{{{content}}}")

      assert Layout.wrap("b", "s", paths: [root], locale: "de") == "de:b"
      assert Layout.wrap("b", "s", paths: [root], locale: "de-AT") == "de:b"
      assert Layout.wrap("b", "s", paths: [root], locale: "fr") == "any:b"
      assert Layout.wrap("b", "s", paths: [root]) == "any:b"
    end

    @tag skip: @needs_underscore_names
    test "a layout that drops the body is refused, with a warning", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "<main>{{{contnet}}}</main>")

      log =
        capture_log(fn ->
          html = Layout.wrap("<p>the body</p>", "s", paths: [root])

          assert html =~ "<p>the body</p>"
          assert html =~ "<!DOCTYPE html>"
        end)

      assert log =~ "has no {{{content}}} placeholder"

      # Once per roots and locale, not on every send.
      assert capture_log(fn -> Layout.wrap("<p>again</p>", "s", paths: [root]) end) == ""

      assert capture_log(fn -> Layout.wrap("<p>x</p>", "s", paths: [root], locale: "de") end) =~
               "has no {{{content}}} placeholder"
    end

    @tag skip: @needs_underscore_names
    test "an empty layout file is refused the same way", %{tmp_dir: root} do
      write(root, "_layout", "html.html", "")

      capture_log(fn ->
        assert Layout.wrap("<p>the body</p>", "s", paths: [root]) =~ "<p>the body</p>"
      end)
    end

    @tag skip: @needs_underscore_names
    test "triple braces keep the body's markup; double braces escape", %{tmp_dir: root} do
      write(
        root,
        "_layout",
        "html.html",
        "<title>{{subject}}</title>{{{content}}}|{{content}}|{{site_name}}|{{site_url}}"
      )

      html = Layout.wrap("<p>x</p>", "<i>s</i>", paths: [root])

      assert html =~ "<title>&lt;i&gt;s&lt;/i&gt;</title><p>x</p>|&lt;p&gt;x&lt;/p&gt;|"
      refute html =~ "{{site_name}}"
      refute html =~ "{{site_url}}"
    end
  end
end
