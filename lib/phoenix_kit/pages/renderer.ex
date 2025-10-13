defmodule PhoenixKit.Pages.Renderer do
  @moduledoc """
  Simple markdown rendering for Pages module.

  Converts markdown files to HTML.
  """

  @doc """
  Renders a markdown file to HTML.

  ## Examples

      iex> Renderer.render_file("/test.md")
      {:ok, "<h1>Hello World</h1>"}

      iex> Renderer.render_file("/missing.md")
      {:error, :enoent}
  """
  def render_file(relative_path) do
    alias PhoenixKit.Pages.FileOperations

    case FileOperations.read_file(relative_path) do
      {:ok, content} ->
        html = render_markdown(content)
        {:ok, html}

      error ->
        error
    end
  end

  @doc """
  Converts markdown content to HTML.

  ## Examples

      iex> Renderer.render_markdown("# Hello")
      "<h1>Hello</h1>"
  """
  def render_markdown(content) do
    case Earmark.as_html(content) do
      {:ok, html, _warnings} -> html
      {:error, _html, errors} -> raise "Markdown parsing failed: #{inspect(errors)}"
    end
  end
end
