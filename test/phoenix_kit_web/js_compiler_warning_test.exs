defmodule PhoenixKitWeb.JsCompilerWarningTest do
  @moduledoc """
  The warning that fires when installed modules ship JS hooks the host will
  never load.

  A module declares its bundle with `js_sources/0`, and the only thing that
  consumes that declaration is the `:phoenix_kit_js_sources` compiler. Without
  it in the host's `:compilers` the hooks are simply absent — no error
  anywhere, the module's pages render, and only the half that needed
  JavaScript is missing, so it reads as a broken module rather than as JS that
  never loaded. `phoenix_kit_boards` shipped exactly that state twice before
  anyone traced it.

  Two things are worth pinning, and they pull against each other: it has to
  speak up in that state, and stay silent in every other. A warning that fires
  on correctly-configured hosts gets muted, which puts everyone back where
  they started.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PhoenixKitWeb.Integration

  defp warning(modules, compiler_configured?) do
    capture_io(:stderr, fn ->
      assert Integration.warn_missing_js_compiler(modules, compiler_configured?) == :ok
    end)
  end

  describe "the host is missing the compiler" do
    test "names the modules whose hooks will not load" do
      output = warning([SomeModule.WithHooks, Another.Module], false)

      assert output =~ "will not be loaded"
      assert output =~ "SomeModule.WithHooks"
      assert output =~ "Another.Module"
    end

    test "says what to do about it" do
      # A warning naming a problem and not its fix is a warning people learn
      # to scroll past.
      output = warning([SomeModule.WithHooks], false)

      assert output =~ ":phoenix_kit_js_sources"
      assert output =~ "compilers:"
      assert output =~ "vendor/phoenix_kit_modules.js"
    end

    test "says what the failure looks like, because it looks like nothing" do
      # The reason this is worth a warning at all: there is no error to find
      # later. Someone reading it should recognise the symptom they will hit.
      output = warning([SomeModule.WithHooks], false)

      assert output =~ "no further error"
    end
  end

  describe "silence" do
    test "when the compiler is configured" do
      refute warning([SomeModule.WithHooks], true) =~ "will not be loaded"
    end

    test "when nothing declares a bundle" do
      # A host with no JS-bearing modules has nothing to be warned about,
      # compiler or not.
      assert warning([], false) == ""
      assert warning([], true) == ""
    end
  end

  describe "it stays a warning" do
    test "does not register a compiler diagnostic" do
      # `IO.warn/1` does, and a diagnostic is a build failure on any host
      # compiling with `--warnings-as-errors` — so the check that exists to
      # save people a silent misconfiguration would instead break their CI on
      # upgrade, over a mix.exs condition that is not a regression in their
      # code. Everything else here is guarded against failing a host's
      # compile; this is the same promise.
      {_captured, diagnostics} =
        Code.with_diagnostics(fn ->
          capture_io(:stderr, fn ->
            Integration.warn_missing_js_compiler([SomeModule.WithHooks], false)
          end)
        end)

      assert diagnostics == []
    end
  end

  describe "discovery" do
    test "never fails the host's compile" do
      # This runs while the host's router compiles. Whatever module discovery
      # finds, or fails to find, a warning is not worth taking a build down
      # for.
      assert Integration.warn_missing_js_compiler() == :ok
    end
  end
end
