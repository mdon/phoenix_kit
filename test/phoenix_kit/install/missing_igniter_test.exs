defmodule PhoenixKit.Install.MissingIgniterTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.MissingIgniter

  describe "message/1" do
    test "names the task and the exact dep line to add" do
      message = MissingIgniter.message("phoenix_kit.update")

      assert message =~ "mix phoenix_kit.update"
      assert message =~ ~s({:igniter, "~> 0.7", only: [:dev, :test]})
      assert message =~ "mix deps.get"
    end
  end

  describe "ensure_available!/2" do
    test "passes when the igniter task module is loadable" do
      assert :ok = MissingIgniter.ensure_available!("phoenix_kit.update", __MODULE__)
    end

    test "raises the guidance when the igniter task module is gone" do
      # The scenario is a beam compiled while igniter was on the path, running
      # in a project that has since dropped it: the module reference survives,
      # the module does not.
      assert_raise Mix.Error, ~r/needs the :igniter dependency/, fn ->
        MissingIgniter.ensure_available!("phoenix_kit.update", Igniter.Mix.Task.NotHere)
      end
    end
  end
end
