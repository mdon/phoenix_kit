defmodule PhoenixKit.Install.DaisyUITest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Install.DaisyUI

  describe "installed_version/1" do
    @tag :tmp_dir
    test "parses the version marker out of a plugin bundle", %{tmp_dir: tmp} do
      path = Path.join(tmp, "daisyui.js")
      File.write!(path, ~s|/** daisyUI */\nvar version = "5.0.35";\nmodule.exports = {};|)

      assert DaisyUI.installed_version(path) == "5.0.35"
    end

    @tag :tmp_dir
    test "returns nil when the file has no version marker", %{tmp_dir: tmp} do
      path = Path.join(tmp, "daisyui.js")
      File.write!(path, "module.exports = {};")

      assert DaisyUI.installed_version(path) == nil
    end

    test "returns nil for a missing file" do
      assert DaisyUI.installed_version("/nonexistent/daisyui.js") == nil
    end
  end

  describe "outdated?/1" do
    test "versions below the minimum are outdated" do
      assert DaisyUI.outdated?("5.0.35")
      assert DaisyUI.outdated?("5.1.0")
    end

    test "the minimum and above are not outdated" do
      refute DaisyUI.outdated?(DaisyUI.minimum_version())
      refute DaisyUI.outdated?("5.6.17")
      # semver comparison, not string comparison
      refute DaisyUI.outdated?("5.10.0")
      refute DaisyUI.outdated?("6.0.0")
    end

    test "unparseable versions are not claimed outdated" do
      refute DaisyUI.outdated?("not-a-version")
    end
  end

  describe "minimum_version/0" do
    test "is a valid semver string" do
      assert {:ok, _} = Version.parse(DaisyUI.minimum_version())
    end
  end

  describe "outdated_warning/1" do
    test "names the installed and minimum versions and the upgrade path" do
      warning = DaisyUI.outdated_warning("5.0.35")

      assert warning =~ "5.0.35"
      assert warning =~ DaisyUI.minimum_version()
      assert warning =~ "assets/vendor"
      assert warning =~ "daisyui.js"
    end
  end
end
