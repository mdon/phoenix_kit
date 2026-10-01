defmodule PhoenixKit.Email.BrandingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Email.Branding

  doctest Branding

  describe "normalize_color/1" do
    test "a six-digit hex colour, trimmed and lower-cased" do
      assert Branding.normalize_color("#1D4ED8") == "#1d4ed8"
      assert Branding.normalize_color("  #00aa00\n") == "#00aa00"
    end

    test "anything else is the neutral default" do
      for bad <- [nil, "", "red", "#abc", "#1d4ed8;", "1d4ed8", "#1d4ed8 x", "#gggggg", 0x1D4ED8] do
        assert Branding.normalize_color(bad) == "#18181b", inspect(bad)
      end
    end
  end

  describe "text_color_on/1" do
    test "white on dark colours, near-black on light ones" do
      assert Branding.text_color_on("#18181b") == "#ffffff"
      assert Branding.text_color_on("#1d4ed8") == "#ffffff"
      assert Branding.text_color_on("#ffffff") == "#18181b"
      assert Branding.text_color_on("#fde047") == "#18181b"
    end
  end

  describe "without a database" do
    test "no logo and the default accent colour" do
      assert Branding.variables() == %{"logo_url" => "", "accent_color" => "#18181b"}
    end
  end
end
