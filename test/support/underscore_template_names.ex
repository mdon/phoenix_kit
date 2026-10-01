defmodule PhoenixKit.Test.UnderscoreTemplateNames do
  @moduledoc """
  Whether the loaded `phoenix_kit_templates` finds a name starting with `_`.

  Finding the email layout's `_layout` override needs 0.2.1, which lets a name
  start with one underscore. Until core's pin requires it, the host `_layout`
  tests run only against a build that has it — a release at 0.2.1 or later, or
  a local checkout through `PHOENIX_KIT_TEMPLATES_PATH` (still versioned 0.2.0
  until the release, hence the probe rather than a version check alone). A
  release at 0.2.1 or later is never skipped, so a regression in the package
  cannot hide behind the probe.

  Remove this, and the `@tag skip:` using it, when the pin moves to `~> 0.2.1`.
  """

  @doc "`false` when the host `_layout` tests can run, else the skip reason."
  @spec skip_reason() :: false | String.t()
  def skip_reason do
    if supported?(), do: false, else: "needs phoenix_kit_templates >= 0.2.1 (underscore names)"
  end

  defp supported? do
    vsn = to_string(Application.spec(:phoenix_kit_templates, :vsn) || "0.0.0")
    Version.compare(vsn, "0.2.1") != :lt or probe()
  end

  defp probe do
    root = Path.join(System.tmp_dir!(), "pk_layout_probe_#{System.unique_integer([:positive])}")

    try do
      File.mkdir_p!(Path.join(root, "_probe"))
      File.write!(Path.join([root, "_probe", "html.html"]), "found")
      PhoenixKit.Templates.render("_probe", %{}, %{}, paths: [root]).html == "found"
    after
      File.rm_rf!(root)
    end
  end
end
