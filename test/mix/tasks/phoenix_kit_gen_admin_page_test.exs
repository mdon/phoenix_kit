defmodule Mix.Tasks.PhoenixKit.Gen.Admin.PageTest do
  # Igniter temporarily evaluates the fixture's config into Application env
  # while formatting, including its MyApp.Repo. LiveView tests read that env.
  use ExUnit.Case, async: false

  import Igniter.Test

  defp file(igniter, path),
    do: igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

  defp generate(config) do
    test_project(files: %{"config/config.exs" => config})
    |> Igniter.compose_task("phoenix_kit.gen.admin.page", ["Reports"])
    |> apply_igniter!()
  end

  test "appends the new tabs without moving or dropping the host's comments" do
    igniter =
      generate("""
      import Config

      config :phoenix_kit,
        repo: MyApp.Repo,
        # Registered admin pages
        admin_dashboard_tabs: [
          # The A page
          %{id: :a, label: "A", path: "/a"}
          # more to come
        ],
        # Hide these admin tabs
        hidden_admin_tabs: [:foo]
      """)

    config = file(igniter, "config/config.exs")

    # A comment stays with the entry it annotates (the old full-list rewrite
    # dropped this one). A comment trailing the LAST entry inside the list is
    # moved by Sourceror to just after the `]` — kept, not lost.
    assert config =~ ~r/# The A page\s*\n\s*%\{id: :a/
    assert config =~ "# more to come"
    assert config =~ ~r/# Hide these admin tabs\s*\n\s*hidden_admin_tabs/
    assert config =~ ~s(label: "A")
    assert config =~ "Reports"
  end

  test "the generated page does not point gettext at the kit's backend" do
    igniter =
      generate("""
      import Config

      config :phoenix_kit, repo: MyApp.Repo
      """)

    page =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.find(&(Rewrite.Source.get(&1, :path) =~ ~r{phoenix_kit/admin/.*\.ex$}))

    assert page, "no generated LiveView"
    refute Rewrite.Source.get(page, :content) =~ "PhoenixKitWeb.Gettext"
  end
end
