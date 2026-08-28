defmodule PhoenixKit.Install.BootHookTest do
  @moduledoc """
  I103, finding 1 (CRITICAL): `add_boot_hook/1` used to read
  `lib/<app>/application.ex` straight off disk and unconditionally overwrite
  the Igniter buffer with a candidate built from that stale read. Igniter
  never flushes a step's writes to disk before the next step runs, so on a
  fresh install — where an EARLIER step in the same run
  (`ApplicationSupervisor.add_supervisor/2`) stages `PhoenixKit.Supervisor`
  into the same file's `children` list — that earlier edit was silently
  discarded: the host got a boot pipe with no supervisor in it, and the
  installer reported success.

  Reproduced here with an Igniter "probe": two `Igniter.update_file/3` calls
  against the SAME file in the SAME pipeline run, the second one being
  `add_boot_hook/1` itself. No real Mix task or disk I/O involved — this is
  exactly what `PhoenixKit.Install.Common.ensure_compilers_registered/2`'s
  own tests already do via `Igniter.Test`.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixKit.Install.BootHook

  @app_file "lib/my_app/application.ex"

  @initial_content """
  defmodule MyApp.Application do
    use Application

    @impl true
    def start(_type, _args) do
      children = [
        MyApp.Repo,
        MyAppWeb.Endpoint
      ]

      opts = [strategy: :one_for_one, name: MyApp.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end
  """

  defp app_content(igniter) do
    igniter.rewrite |> Rewrite.source!(@app_file) |> Rewrite.Source.get(:content)
  end

  # Stands in for `ApplicationSupervisor.add_supervisor/2`: an earlier step
  # in the SAME pipeline run staging an edit to the SAME file, via the same
  # `Igniter.update_file/3` + `Rewrite.Source` mechanism the real helper
  # uses. Nothing about this reproduction depends on that helper's own
  # (separately tested) logic for FINDING the right insertion point — only
  # on the fact that Igniter buffers the result rather than writing it to
  # disk immediately.
  defp stage_supervisor_addition(igniter) do
    Igniter.update_file(igniter, @app_file, fn source ->
      content = Rewrite.Source.get(source, :content)

      updated =
        String.replace(content, "MyApp.Repo,", "MyApp.Repo,\n        PhoenixKit.Supervisor,")

      Rewrite.Source.update(source, :content, updated)
    end)
  end

  test "the boot hook does not discard an earlier step's edit to the same file" do
    igniter =
      test_project(app_name: :my_app, files: %{@app_file => @initial_content})
      |> stage_supervisor_addition()
      |> BootHook.add_boot_hook()
      |> apply_igniter!()

    content = app_content(igniter)

    assert content =~ "PhoenixKit.Supervisor",
           "the earlier step's supervisor edit was discarded:\n#{content}"

    assert content =~ "|> PhoenixKit.boot()",
           "the boot hook itself did not land:\n#{content}"
  end

  test "is idempotent — already-wired content is left alone" do
    already_wired =
      String.replace(
        @initial_content,
        "Supervisor.start_link(children, opts)",
        "Supervisor.start_link(children, opts) |> PhoenixKit.boot()"
      )

    igniter =
      test_project(app_name: :my_app, files: %{@app_file => already_wired})
      |> BootHook.add_boot_hook()
      |> apply_igniter!()

    assert app_content(igniter) == already_wired
  end

  test "a non-standard Supervisor.start_link call is left untouched, with a warning" do
    # `@standard_call`'s pattern has no leading anchor, so a DIFFERENTLY
    # NAMED supervisor module (e.g. "MySupervisor.start_link(...)") still
    # matches it — it merely needs "Supervisor.start_link(children, opts)" as
    # a substring, which "MySupervisor..." still contains. The genuinely
    # non-standard shape changes the `opts` VARIABLE name, which the pattern
    # requires verbatim.
    non_standard =
      String.replace(
        @initial_content,
        "Supervisor.start_link(children, opts)",
        "Supervisor.start_link(children, supervisor_opts)"
      )

    igniter =
      test_project(app_name: :my_app, files: %{@app_file => non_standard})
      |> BootHook.add_boot_hook()

    assert igniter.warnings != [], "expected a warning about the non-standard form"

    applied = apply_igniter!(igniter)
    assert app_content(applied) == non_standard
  end
end
