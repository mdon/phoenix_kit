defmodule PhoenixKit.Install.DaisyUI do
  @moduledoc """
  Advisory check of the host's vendored daisyUI version.

  PhoenixKit's UI is styled by daisyUI, which lives in the HOST app
  (`assets/vendor/daisyui.js` + `daisyui-theme.js`, scaffolded by
  `mix phx.new` and loaded from the host's `app.css`). The host owns that
  file — PhoenixKit does not manage or replace it; it only **checks** it.
  `mix phoenix_kit.install`, `mix phoenix_kit.update`, and
  `mix phoenix_kit.doctor` warn when the vendored copy is older than
  `minimum_version/0`, with upgrade instructions.

  Why the minimum matters: daisyUI < 5.1 reserves the modal scrollbar gutter
  UNCONDITIONALLY while a modal/drawer is open, which either leaves a phantom
  right-edge strip on non-scrolling pages or (when countered) makes content
  reflow ~15px around every modal open/close on scrolling pages. daisyUI
  ≥ 5.1 reserves the gutter only when the page really has a scrollbar
  (`rootscrollgutter.css`), so PhoenixKit ships **no** scrollbar-gutter
  compensations of its own (removed 2026-07-12) and relies on a modern
  daisyUI instead. Hosts on an old copy see daisyUI's stock old behavior
  until they upgrade — that's what the warning is for.
  """

  # The oldest daisyUI whose modal scrollbar-gutter handling PhoenixKit's
  # modals rely on. The upstream fix matured across 5.1.0 → 5.6.x; PhoenixKit
  # is verified against 5.6.17, and 5.6.0 is the floor we recommend.
  @minimum_version "5.6.0"

  @doc "The minimum daisyUI version PhoenixKit's UI is designed against."
  @spec minimum_version() :: String.t()
  def minimum_version, do: @minimum_version

  @doc "The host-side path of the vendored daisyUI plugin."
  @spec host_path() :: Path.t()
  def host_path, do: Path.join([File.cwd!(), "assets", "vendor", "daisyui.js"])

  @doc """
  Parse the daisyUI version out of a plugin bundle, or `nil` when the file is
  missing or carries no `version = "x.y.z"` marker.
  """
  @spec installed_version(Path.t()) :: String.t() | nil
  def installed_version(path) do
    with {:ok, content} <- File.read(path),
         [_, version] <- Regex.run(~r/version = "([\d.]+)"/, content) do
      version
    else
      _ -> nil
    end
  end

  @doc """
  Check the host's vendored daisyUI against `minimum_version/0`.

  - `:ok` — present and at/above the minimum
  - `{:outdated, version}` — present but older than the minimum
  - `:unversioned` — present but carries no parseable version marker
  - `:missing` — no `assets/vendor/daisyui.js` (npm or custom setup)
  """
  @spec check() :: :ok | {:outdated, String.t()} | :unversioned | :missing
  def check do
    path = host_path()

    cond do
      not File.exists?(path) ->
        :missing

      version = installed_version(path) ->
        if outdated?(version), do: {:outdated, version}, else: :ok

      true ->
        :unversioned
    end
  end

  @doc "Whether a daisyUI version string is below `minimum_version/0`."
  @spec outdated?(String.t()) :: boolean()
  def outdated?(version) when is_binary(version) do
    case {Version.parse(version), Version.parse(@minimum_version)} do
      {{:ok, installed}, {:ok, minimum}} -> Version.compare(installed, minimum) == :lt
      # Unparseable → don't claim it's outdated; check/0 reports :unversioned.
      _ -> false
    end
  end

  @doc "Human warning for an outdated vendored daisyUI, with upgrade steps."
  @spec outdated_warning(String.t()) :: String.t()
  def outdated_warning(version) do
    """
    ⚠️  Your vendored daisyUI is #{version}; PhoenixKit is designed against #{@minimum_version}+.
    On daisyUI < 5.1, opening any modal/drawer mishandles the scrollbar gutter
    (a phantom right-edge strip, or content shifting ~15px on scrolling pages).
    Update the two files in assets/vendor/ and rebuild assets:

        cd assets/vendor
        curl -sLO https://github.com/saadeghi/daisyui/releases/latest/download/daisyui.js
        curl -sLO https://github.com/saadeghi/daisyui/releases/latest/download/daisyui-theme.js

    Changelog: https://daisyui.com/docs/changelog/
    """
  end
end
