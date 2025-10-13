defmodule PhoenixKitWeb.PagesController do
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.Renderer

  @doc """
  Renders a public page from the pages directory.

  Path examples:
    /pages/test2 -> renders test2.md
    /pages/blog/hello -> renders blog/hello.md
  """
  def show(conn, %{"path" => path}) do
    # Check if Pages module is enabled
    unless Pages.enabled?() do
      conn
      |> put_status(:not_found)
      |> put_view(html: PhoenixKitWeb.ErrorHTML)
      |> render(:"404")
    else
      # Add .md extension to path
      file_path = build_file_path(path)

      case Renderer.render_file(file_path) do
        {:ok, html_content} ->
          # Get filename for title
          filename = Path.basename(file_path, ".md")

          conn
          |> assign(:page_title, filename)
          |> assign(:html_content, html_content)
          |> render(:show)

        {:error, _reason} ->
          conn
          |> put_status(:not_found)
          |> put_view(html: PhoenixKitWeb.ErrorHTML)
          |> render(:"404")
      end
    end
  end

  # Private helpers

  defp build_file_path(path) when is_list(path) do
    # Handle catch-all route: ["blog", "post-1"] -> "/blog/post-1.md"
    "/" <> Path.join(path) <> ".md"
  end

  defp build_file_path(path) when is_binary(path) do
    # Handle single path segment: "test2" -> "/test2.md"
    "/" <> path <> ".md"
  end
end
