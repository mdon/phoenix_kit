defmodule PhoenixKit.Install.MissingIgniterTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.MissingIgniter

  @dep_line ~s({:igniter, "~> 0.7", only: [:dev, :test]})

  defp mix_exs(deps) do
    """
    defmodule MyApp.MixProject do
      use Mix.Project

      def project do
        [app: :my_app, version: "0.1.0", deps: deps()]
      end

      defp deps do
    #{deps}
      end
    end
    """
  end

  describe "message/2" do
    test "names the task and the exact dep line to add" do
      message = MissingIgniter.message("phoenix_kit.update")

      assert message =~ "mix phoenix_kit.update"
      assert message =~ @dep_line
      assert message =~ "mix deps.get"
    end

    test "leads with what stopped the automatic path" do
      assert MissingIgniter.message("phoenix_kit.update", :declined) =~ "Nothing was changed."

      assert MissingIgniter.message("phoenix_kit.update", :already_declared) =~
               "already declared in mix.exs"

      assert MissingIgniter.message("phoenix_kit.update", :deps_not_found) =~
               "added by hand"

      assert MissingIgniter.message("phoenix_kit.update", :fetch_failed) =~
               "`mix deps.get` did not succeed"

      # Both post-prompt outcomes drop the "add it to mix.exs" instructions:
      # one because the prompt just said all of it, one because the line is
      # already written.
      refute MissingIgniter.message("phoenix_kit.update", :declined) =~ "OPTIONAL dependency"
      refute MissingIgniter.message("phoenix_kit.update", :fetch_failed) =~ "Add it to your"

      assert MissingIgniter.message("phoenix_kit.update", :unsupported_env) =~
               "Re-run with MIX_ENV=dev"
    end
  end

  describe "add_igniter_dep/1" do
    test "inserts the dep as the first entry, at the list's own indentation" do
      source =
        mix_exs("""
            [
              {:phoenix, "~> 1.7"},
              {:phoenix_kit, "~> 2.13"}
            ]\
        """)

      assert {:ok, updated} = MissingIgniter.add_igniter_dep(source)

      assert updated =~ """
                 [
                   #{@dep_line},
                   {:phoenix, "~> 1.7"},
             """
    end

    test "handles an empty deps list" do
      source =
        mix_exs("""
            [
            ]\
        """)

      assert {:ok, updated} = MissingIgniter.add_igniter_dep(source)
      assert updated =~ "#{@dep_line},\n"
    end

    test "refuses to duplicate a declaration that is already there" do
      source =
        mix_exs("""
            [
              {:igniter, "~> 0.7", only: [:dev, :test]}
            ]\
        """)

      assert {:error, :already_declared} = MissingIgniter.add_igniter_dep(source)
    end

    test "declines to guess at a deps list it cannot recognise" do
      source = mix_exs("    Enum.concat(base_deps(), extra_deps())")

      assert {:error, :deps_not_found} = MissingIgniter.add_igniter_dep(source)
    end

    test "leaves the rest of the file byte-for-byte alone" do
      source =
        mix_exs("""
            [
              # ünïcödé comment, so byte offsets ≠ grapheme offsets
              {:phoenix, "~> 1.7"}
            ]\
        """)

      assert {:ok, updated} = MissingIgniter.add_igniter_dep(source)
      assert String.replace(updated, "      #{@dep_line},\n", "", global: false) == source
    end
  end

  describe "ensure_available!/3" do
    test "passes when the igniter task module is loadable" do
      assert :ok = MissingIgniter.ensure_available!("phoenix_kit.update", [], __MODULE__)
    end

    test "stops with guidance when igniter is gone and cannot be added for us" do
      # The scenario is a beam compiled while igniter was on the path, running
      # in a project that has since dropped it: the module reference survives,
      # the module does not. PhoenixKit's own mix.exs already declares igniter,
      # so this exercises the branch that stops before touching any file.
      assert_raise Mix.Error, ~r/already declared in mix.exs/, fn ->
        MissingIgniter.ensure_available!("phoenix_kit.update", [], Igniter.Mix.Task.NotHere)
      end
    end
  end

  describe "stand_in_run/2" do
    test "asks for a recompile when igniter turned up after PhoenixKit was compiled" do
      # This module IS the stand-in, so reaching it while igniter is loadable
      # means only the compiled branch is out of date.
      assert_raise Mix.Error, ~r/mix deps\.compile phoenix_kit --force/, fn ->
        MissingIgniter.stand_in_run("phoenix_kit.update", [])
      end
    end
  end
end
