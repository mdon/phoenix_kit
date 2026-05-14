defmodule PhoenixKitWeb.CommentsGettextManifest do
  @moduledoc false

  # Lists translatable strings used by `phoenix_kit_comments` that route via
  # the shared `PhoenixKitWeb.Gettext` backend. Mirrors the
  # `legal_gettext_manifest.ex` + `projects_gettext_manifest.ex` pattern —
  # `mix gettext.extract` only walks core's `lib/`, never deps, so any string
  # called from `phoenix_kit_comments` via `gettext(...)` against
  # `PhoenixKitWeb.Gettext` would be missing from `priv/gettext/default.pot`
  # without this manifest.
  #
  # Scope: end-user-facing strings rendered by the public
  # `CommentsComponent` LiveComponent (the comment thread that mounts on
  # post/project pages) plus the `data-confirm` shown to commenters on
  # delete. Admin-settings UI strings under
  # `lib/phoenix_kit_comments/web/settings*` are intentionally excluded —
  # the admin panel runs in English.
  #
  # ## Refreshing the list
  #
  # When `phoenix_kit_comments` adds or renames a translatable string, run
  # from the comments checkout:
  #
  #     grep -hEo 'gettext\("[^"]+' \
  #       lib/phoenix_kit_comments/web/comments_component.ex \
  #       lib/phoenix_kit_comments/web/comments_component.html.heex \
  #     | sort -u
  #
  # Then mirror new entries here and run `mix gettext.extract --merge` from
  # core.
  #
  # This module is never called at runtime.

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc false
  def __extract__ do
    [
      # comments_component.html.heex
      gettext("Replying to comment"),
      gettext("Cancel"),
      gettext("Write a comment..."),
      gettext("GIF"),
      gettext("Remove GIF"),
      gettext("Remove %{name}", name: ""),
      gettext("Stop recording"),
      gettext("Attach media"),
      gettext("Attach media options"),
      gettext("Image"),
      gettext("Record"),
      gettext("Up to %{count} files, max %{size}MB each", count: 0, size: 0),
      gettext("Giphy picker"),
      gettext("Search GIFs"),
      gettext("Search GIFs..."),
      gettext("GIF results"),
      gettext("Select GIF %{id}", id: ""),
      gettext("Type a search term to find GIFs."),
      gettext("No results."),
      gettext("Post Comment"),
      gettext("Sign in to post a comment."),
      gettext("No comments yet. Be the first to comment!"),
      # comments_component.ex render_comment
      gettext("[removed]"),
      gettext("Unknown"),
      gettext("Reply"),
      gettext("Are you sure you want to delete this comment?"),
      gettext("Save")
    ]
  end
end
