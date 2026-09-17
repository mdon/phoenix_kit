defmodule PhoenixKit.Migrations.Postgres.V196Test do
  @moduledoc """
  V196's `google_email` column, run as the real SQL: down removes it, up
  puts it back (re-runnable), the backfill copies an address a linked
  Google sign-in already proved, and each direction stamps its marker.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Migrations.Postgres.V196
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp run(statements), do: Enum.each(statements, &Repo.query!/1)

  defp column_shape do
    %{rows: rows} =
      Repo.query!("""
      SELECT data_type, character_maximum_length, is_nullable
      FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_users'
        AND column_name = 'google_email'
      """)

    rows
  end

  defp marker do
    %{rows: [[marker]]} = Repo.query!("SELECT obj_description('phoenix_kit'::regclass)")
    marker
  end

  defp user_with_google_link(provider_email, opts \\ []) do
    {:ok, user} =
      Auth.register_user(%{
        email: "v196_#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    Repo.query!(
      """
      INSERT INTO public.phoenix_kit_user_oauth_providers
        (uuid, user_uuid, provider, provider_uid, provider_email, raw_data, inserted_at, updated_at)
      VALUES (uuid_generate_v7(), $1, $2, $3, $4, '{}'::jsonb, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user.uuid),
        Keyword.get(opts, :provider, "google"),
        "uid_#{System.unique_integer([:positive])}",
        provider_email
      ]
    )

    user
  end

  defp google_email_of(user) do
    %{rows: [[value]]} =
      Repo.query!("SELECT google_email FROM public.phoenix_kit_users WHERE uuid = $1", [
        Ecto.UUID.dump!(user.uuid)
      ])

    value
  end

  test "down removes the column, up restores it, and each stamps its marker" do
    run(V196.down_statements("public"))
    assert column_shape() == []
    assert marker() == "195"

    run(V196.up_statements("public"))
    assert column_shape() == [["character varying", 160, "YES"]]
    assert marker() == "196"
  end

  test "up is re-runnable" do
    run(V196.up_statements("public"))
    run(V196.up_statements("public"))

    assert column_shape() == [["character varying", 160, "YES"]]
    assert marker() == "196"
  end

  describe "the backfill" do
    test "fills a linked Google account's address, and leaves other providers alone" do
      google = user_with_google_link("linked@example.com")
      github = user_with_google_link("gh@example.com", provider: "github")

      # The column exists already (the suite migrates on boot), so clear it
      # to stand in for a host that has not run V196 yet.
      Repo.query!("UPDATE public.phoenix_kit_users SET google_email = NULL")
      run(V196.up_statements("public"))

      assert google_email_of(google) == "linked@example.com"
      assert google_email_of(github) == nil
    end

    test "never overwrites an address already on the row" do
      user = user_with_google_link("linked@example.com")

      {:ok, _} = Auth.update_user_profile(user, %{google_email: "typed@example.com"})
      run(V196.up_statements("public"))

      assert google_email_of(user) == "typed@example.com"
    end

    test "skips a link that carries no address" do
      user = user_with_google_link("")

      Repo.query!("UPDATE public.phoenix_kit_users SET google_email = NULL")
      run(V196.up_statements("public"))

      assert google_email_of(user) == nil
    end
  end
end
