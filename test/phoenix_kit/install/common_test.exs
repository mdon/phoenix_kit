defmodule PhoenixKit.Install.CommonTest do
  @moduledoc """
  Regression coverage for `ensure_compilers_registered/2` — specifically the
  bug it fixes: two separate `Igniter.Project.MixProject.update/4` calls
  touching the same `:compilers` key corrupt the second one, because the
  first call's `nil` branch has to produce a `[atom] ++ Mix.compilers()`
  `++` node (not a literal list — `Mix.compilers()` is a live call), and
  `Igniter.Code.List.prepend_new_to_list/2` only understands literal lists.
  """

  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.Common

  defp mix_exs_content(igniter) do
    igniter.rewrite |> Rewrite.source!("mix.exs") |> Rewrite.Source.get(:content)
  end

  test "no :compilers key — inserts every atom ++ Mix.compilers()" do
    igniter =
      test_project()
      |> Common.ensure_compilers_registered([:phoenix_kit_css_sources, :phoenix_kit_js_sources])
      |> apply_igniter!()

    content = mix_exs_content(igniter)

    assert content =~ ":phoenix_kit_css_sources"
    assert content =~ ":phoenix_kit_js_sources"
    assert content =~ "Mix.compilers()"
  end

  test "repairs a :compilers value already left in the broken [atom] ++ Mix.compilers() shape" do
    igniter =
      test_project(
        files: %{
          "mix.exs" => """
          defmodule Test.MixProject do
            use Mix.Project

            def project do
              [
                app: :test,
                version: "0.1.0",
                compilers: [:phoenix_kit_css_sources] ++ Mix.compilers(),
                deps: []
              ]
            end
          end
          """
        }
      )
      |> Common.ensure_compilers_registered([:phoenix_kit_css_sources, :phoenix_kit_js_sources])
      |> apply_igniter!()

    content = mix_exs_content(igniter)

    assert content =~ ":phoenix_kit_css_sources"
    assert content =~ ":phoenix_kit_js_sources"
    assert content =~ "Mix.compilers()"
    assert occurrences(content, ":phoenix_kit_css_sources") == 1
    assert occurrences(content, ":phoenix_kit_js_sources") == 1
  end

  test "prepending into an existing plain literal list works too" do
    igniter =
      test_project(
        files: %{
          "mix.exs" => """
          defmodule Test.MixProject do
            use Mix.Project

            def project do
              [
                app: :test,
                version: "0.1.0",
                compilers: [:some_other_compiler],
                deps: []
              ]
            end
          end
          """
        }
      )
      |> Common.ensure_compilers_registered([:phoenix_kit_css_sources, :phoenix_kit_js_sources])
      |> apply_igniter!()

    content = mix_exs_content(igniter)

    assert content =~ ":some_other_compiler"
    assert content =~ ":phoenix_kit_css_sources"
    assert content =~ ":phoenix_kit_js_sources"
  end

  test "idempotent — running twice does not duplicate either atom" do
    igniter =
      test_project()
      |> Common.ensure_compilers_registered([:phoenix_kit_css_sources, :phoenix_kit_js_sources])
      |> apply_igniter!()

    igniter =
      igniter
      |> Common.ensure_compilers_registered([:phoenix_kit_css_sources, :phoenix_kit_js_sources])
      |> apply_igniter!()

    content = mix_exs_content(igniter)

    assert occurrences(content, ":phoenix_kit_css_sources") == 1
    assert occurrences(content, ":phoenix_kit_js_sources") == 1
  end

  defp occurrences(content, substring) do
    content
    |> String.split(substring)
    |> length()
    |> Kernel.-(1)
  end
end
