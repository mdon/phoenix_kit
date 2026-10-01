defmodule PhoenixKit.Integration.Email.BrandingTest do
  @moduledoc """
  `PhoenixKit.Email.Branding` against the real settings and storage tables:
  the accent colour setting, and the logo URL for a site file, a file in a
  private library, and a logo that no longer exists.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Email.Branding
  alias PhoenixKit.Email.Content
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Library
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  setup do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "brand-#{System.unique_integer([:positive])}@example.com",
        "password" => "ValidPassword123!"
      })

    %{user: user}
  end

  defp insert_file(user, attrs \\ %{}) do
    {:ok, file} =
      %Storage.File{}
      |> Storage.File.changeset(
        Map.merge(
          %{
            user_uuid: user.uuid,
            original_file_name: "logo.png",
            file_name: "logo.png",
            file_path: "x",
            mime_type: "image/png",
            file_type: "image",
            ext: "png",
            file_checksum: Ecto.UUID.generate(),
            user_file_checksum: Ecto.UUID.generate(),
            size: 1,
            status: "active"
          },
          attrs
        )
      )
      |> Repo.insert()

    file
  end

  defp set_logo(uuid), do: {:ok, _} = Settings.update_setting("auth_logo_file_uuid", uuid)

  describe "accent colour" do
    test "the setting is read, normalised, and bound in the email" do
      {:ok, _} = Settings.update_setting(Branding.accent_color_key(), "#1D4ED8")

      assert Branding.accent_color() == "#1d4ed8"

      html =
        Content.resolve("accent_probe", "a@b.c", %{}, fn ->
          %{subject: "s", markdown: "[Go](https://a.test)"}
        end).html

      assert html =~ ~s(bgcolor="#1d4ed8")
      assert html =~ "border-top:3px solid #1d4ed8;"
    end

    test "an invalid setting reads as the default" do
      {:ok, _} = Settings.update_setting(Branding.accent_color_key(), "red;x:y")

      assert Branding.accent_color() == "#18181b"
    end
  end

  describe "logo" do
    test "a site file: an absolute URL of its small variant, in the header", %{user: user} do
      file = insert_file(user)
      set_logo(file.uuid)

      url = Routes.base_url() <> URLSigner.signed_url(file.uuid, "small")
      assert Branding.logo_url() == url

      html = Content.resolve("logo_probe", "a@b.c", %{}, fn -> %{text: "x"} end).html
      assert html =~ ~s(<img src="#{url}")
    end

    test "a file in a private library gets no URL", %{user: user} do
      n = System.unique_integer([:positive])

      library =
        Repo.insert!(%Library{
          name: "Private #{n}",
          kind: "user",
          visibility: "private",
          owner_uuid: user.uuid,
          key_prefix: "brand#{n}",
          slug: "brand-#{n}"
        })

      file = insert_file(user)
      Repo.update!(Ecto.Changeset.change(file, library_uuid: library.uuid))
      set_logo(file.uuid)

      assert Branding.logo_url() == ""
      refute Content.resolve("logo_probe", "a@b.c", %{}, fn -> %{text: "x"} end).html =~ "<img"
    end

    test "a logo that no longer exists gets no URL" do
      set_logo(Ecto.UUID.generate())

      assert Branding.logo_url() == ""
    end
  end
end
