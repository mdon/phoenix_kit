defmodule PhoenixKit.Email.Branding do
  @moduledoc """
  The site's branding as email variables: its logo and its accent colour.

  `PhoenixKit.Email.Content.resolve/5` binds both in every part of a message
  built from a file or a default — the body, `_layout`, `_header` and
  `_footer` — so a host's files and core's own layout read the same values.

  | placeholder | value |
  |---|---|
  | `{{logo_url}}` | an absolute URL of the project logo's `small` variant, or `""` |
  | `{{accent_color}}` | the `email_accent_color` setting as `#rrggbb`, or `#18181b` |

  Both are read on every send, so a change in the admin shows in the next
  email without a restart.

  ## The logo

  The logo is the one already set under Settings (`Settings.get_logo_uuid/0`:
  the project logo, else the site icon). Its URL carries the permanent
  signed token, so it keeps working in an email opened weeks later. A logo
  stored in a **private** library would need a time-window token that
  expires long before the email is read, so none is minted: `logo_url` is
  empty and core's header prints the site's name instead.

  The `small` variant is a JPEG (`Storage.reset_dimensions_to_defaults/0`),
  so a transparent PNG logo arrives on a white background. Core's header
  sits on white, so that only shows in a host layout with a coloured header.

  ## The accent colour

  A six-digit hex colour (`#1d4ed8`), checked on every read: anything else —
  unset, `red`, `#abc`, a value with a `;` in it — reads as the neutral
  default, so a bad value can never reach a `style` attribute.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  require Logger

  @accent_key "email_accent_color"
  @default_accent "#18181b"
  @logo_variant "small"

  @doc "The settings key that holds the accent colour."
  @spec accent_color_key() :: String.t()
  def accent_color_key, do: @accent_key

  @doc "The accent colour used when none (or no valid one) is set."
  @spec default_accent_color() :: String.t()
  def default_accent_color, do: @default_accent

  @doc """
  Both branding variables, keyed as the templates read them.
  """
  @spec variables() :: %{String.t() => String.t()}
  def variables do
    %{"logo_url" => logo_url(), "accent_color" => accent_color()}
  end

  @doc "The accent colour setting, normalised by `normalize_color/1`."
  @spec accent_color() :: String.t()
  def accent_color, do: @accent_key |> Settings.get_setting_cached(nil) |> normalize_color()

  @doc """
  `value` as a lower-case `#rrggbb` colour, or the default accent colour when
  it is not a six-digit hex colour.

      iex> PhoenixKit.Email.Branding.normalize_color(" #1D4ED8 ")
      "#1d4ed8"

      iex> PhoenixKit.Email.Branding.normalize_color("red;background:url(x)")
      "#18181b"
  """
  @spec normalize_color(term()) :: String.t()
  def normalize_color(value) when is_binary(value) do
    color = String.trim(value)

    if Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, color),
      do: String.downcase(color),
      else: @default_accent
  end

  def normalize_color(_value), do: @default_accent

  @doc """
  The text colour that reads on `background` (a colour as `normalize_color/1`
  returns it): white on a dark colour, near-black on a light one — whichever
  contrasts more, by WCAG relative luminance.
  """
  @spec text_color_on(String.t()) :: String.t()
  def text_color_on(background) do
    "#" <> hex = normalize_color(background)
    luminance = luminance(hex)

    # Contrast against white is 1.05 / (L + 0.05), against #18181b it is
    # (L + 0.05) / (L(#18181b) + 0.05); pick the larger.
    if 1.05 / (luminance + 0.05) >= (luminance + 0.05) / (luminance("18181b") + 0.05),
      do: "#ffffff",
      else: @default_accent
  end

  defp luminance(hex) do
    [r, g, b] =
      for <<pair::binary-size(2) <- hex>> do
        channel = String.to_integer(pair, 16) / 255

        if channel <= 0.03928,
          do: channel / 12.92,
          else: :math.pow((channel + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  @doc """
  An absolute URL of the project logo for an email, or `""` when there is no
  logo, it no longer exists, it sits in a private library, or the lookup
  fails.
  """
  @spec logo_url() :: String.t()
  def logo_url do
    case Settings.get_logo_uuid() do
      uuid when is_binary(uuid) and uuid != "" -> public_logo_url(uuid)
      _none -> ""
    end
  end

  # An email outlives every time-window token, so a private library's logo
  # gets no URL at all rather than one that stops working. A deleted file gets
  # none either: a broken image is worse than the site's name.
  defp public_logo_url(uuid) do
    case Storage.get_file(uuid) do
      nil ->
        ""

      file ->
        if Libraries.private_file?(file),
          do: "",
          else: Routes.base_url() <> URLSigner.signed_url(uuid, @logo_variant)
    end
  rescue
    error ->
      Logger.warning("Email logo lookup for #{inspect(uuid)} failed: #{inspect(error)}")
      ""
  catch
    :exit, reason ->
      Logger.warning("Email logo lookup for #{inspect(uuid)} exited: #{inspect(reason)}")
      ""
  end
end
