defmodule PhoenixKit.Utils.MultilangCurrentLocaleTest do
  @moduledoc """
  `Multilang.current_locale/0`: per-language content is read and stored by
  the full dialect the request resolved to — not by the Gettext locale,
  which is downgraded to a base code and cannot tell `en-GB` from `en-US`.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitWeb.Users.Auth

  test "with no request dialect recorded, it is the Gettext locale" do
    Gettext.put_locale(PhoenixKitWeb.Gettext, "et")

    assert Multilang.current_locale() == "et"
  end

  test "setting the Gettext locale records the undowngraded dialect beside it" do
    assert Auth.put_gettext_locale("en-GB") == "en"

    assert Gettext.get_locale(PhoenixKitWeb.Gettext) == "en"
    assert Languages.request_locale() == "en-GB"
    assert Multilang.current_locale() == "en-GB"
  end
end
