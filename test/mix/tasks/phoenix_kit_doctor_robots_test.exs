defmodule Mix.Tasks.PhoenixKit.DoctorRobotsTest do
  @moduledoc """
  The doctor's robots.txt hint: a host may serve robots.txt from a route
  instead of a file, and then "no robots.txt" is wrong.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.PhoenixKit.Doctor

  @moduletag :tmp_dir

  @route %{verb: :get, path: "/robots.txt", plug: MyAppWeb.RobotsController}

  test "no file and no route: suggest adding one", %{tmp_dir: dir} do
    assert Doctor.robots_hint([], Path.join(dir, "robots.txt")) =~ "No priv/static/robots.txt"
  end

  test "served by a route: name it, and don't say it is missing", %{tmp_dir: dir} do
    hint = Doctor.robots_hint([@route], Path.join(dir, "robots.txt"))

    assert hint =~ "MyAppWeb.RobotsController"
    assert hint =~ "Sitemap:"
    refute hint =~ "No priv/static/robots.txt"
  end

  test "a file with a Sitemap: line is enough", %{tmp_dir: dir} do
    path = Path.join(dir, "robots.txt")
    File.write!(path, "User-agent: *\nSitemap: https://example.test/sitemap.xml\n")

    assert Doctor.robots_hint([], path) == ""
  end

  test "a file without one gets the hint", %{tmp_dir: dir} do
    path = Path.join(dir, "robots.txt")
    File.write!(path, "User-agent: *\n")

    assert Doctor.robots_hint([], path) =~ "has no `Sitemap:` line"
  end
end
