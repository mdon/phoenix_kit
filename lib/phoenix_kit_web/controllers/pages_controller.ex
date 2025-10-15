defmodule PhoenixKitWeb.PagesController do
  use PhoenixKitWeb, :controller

  alias PhoenixKit.Pages
  alias PhoenixKit.Pages.Renderer

  @doc """
  Renders a public page from the pages directory.

  Only renders pages with status "published". Draft and archived pages return 404.

  Path examples:
    /pages/test2 -> renders test2.md (if published)
    /pages/blog/hello -> renders blog/hello.md (if published)
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

      case Renderer.render_file_with_metadata(file_path) do
        {:ok, html_content, metadata} ->
          # Check if page is published
          if metadata.status == "published" do
            # Use metadata title or fallback to filename
            page_title = metadata.title || Path.basename(file_path, ".md")

            conn
            |> assign(:page_title, page_title)
            |> assign(:html_content, html_content)
            |> assign(:metadata, metadata)
            |> render(:show)
          else
            # Draft or archived - return 404
            conn
            |> put_status(:not_found)
            |> put_view(html: PhoenixKitWeb.ErrorHTML)
            |> render(:"404")
          end

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
