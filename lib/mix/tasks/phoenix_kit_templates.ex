defmodule Mix.Tasks.PhoenixKitTemplates do
  @moduledoc """
  Template definitions for PhoenixKit demo pages.
  """

  @priv_dir :code.priv_dir(:phoenix_kit) |> Path.join("templates")

  def get_test_ensure_auth_live do
    read_template("test_ensure_auth_live.ex")
  end

  def get_test_redirect_if_auth_live do
    read_template("test_redirect_if_auth_live.ex")
  end

  def get_test_require_auth_live do
    read_template("test_require_auth_live.ex")
  end

  defp read_template(filename) do
    template_path = Path.join(@priv_dir, filename)
    File.read!(template_path)
  end
end
