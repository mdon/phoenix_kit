defmodule PhoenixKit.Email.Branding do
  @moduledoc """
  The site's branding as email variables: its logo and its accent colour.

  `PhoenixKit.Email.Content.resolve/5` binds both in every part of a message
  built from a file or a default — the body, `_layout`, `_header` and
  `_footer` — so a host's files and core's own layout read the same values.

  | placeholder | value |
  |---|---|
  | `{{logo_url}}` | an absolute URL of the project logo, or `""` |
  | `{{accent_color}}` | the `email_accent_color` setting as `#rrggbb`, or `#18181b` |

  Both are read on every send, so a changed setting shows in the next email
  without a restart.

  A caller may bind either variable itself; `merge/2` keeps its value only
  when it is valid — a `#rrggbb` colour, an empty or `http(s)://` logo URL —
  and uses the site's otherwise, on every path a template can read it.

  ## The logo

  The logo is the one already set under Settings (`Settings.get_logo_uuid/0`:
  the project logo, else the site icon). Its URL carries the permanent
  signed token, so it keeps working in an email opened weeks later. A logo
  stored in a **private** library would need a time-window token that
  expires long before the email is read, so none is minted: `logo_url` is
  empty and core's header prints the site's name instead.

  A logo in the trash, or one that no longer exists, gives no URL either.

  ### Which file of the logo

  The first finished one, in this order, that every email client shows —
  PNG, JPEG or GIF:

      small  →  medium  →  large  →  original

  A transparent logo's JPEG-configured sizes are written as PNG
  (`VariantGenerator.output_format/3`), or as WebP when the host sets
  `config :phoenix_kit, :variant_alpha_format, "webp"`. Outlook for Windows
  shows no WebP, so a WebP size is passed over — usually for the original,
  when that is a PNG. A logo with no such file (an SVG with WebP sizes, or
  sizes still being made) gives no URL, and core's header prints the site's
  name. Sizes made before transparent images were written as PNG are JPEG,
  so such a logo arrives on a white background until its sizes are
  regenerated. The URL carries the file's version, so a mail client may
  cache it for good.

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

  # Sizes tried for the logo, smallest first, and the types every mail client
  # shows. WebP is not one of them (Outlook for Windows), nor is SVG.
  @logo_variants ~w(small medium large original)
  @email_image_types ~w(image/png image/jpeg image/gif)

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

  @doc """
  `variables` (string keys) with the branding variables added: a caller's own
  `logo_url` or `accent_color` is kept only when valid (see `valid_color?/1`
  and `valid_logo_url?/1`), otherwise `branding`'s value is used. A kept
  colour is normalised.
  """
  @spec merge(%{String.t() => term()}, %{String.t() => String.t()}) :: %{String.t() => term()}
  def merge(variables, branding) do
    Map.merge(variables, branding, fn
      "accent_color", own, site -> if valid_color?(own), do: normalize_color(own), else: site
      "logo_url", own, site -> if valid_logo_url?(own), do: String.trim(own), else: site
      _key, own, _site -> own
    end)
  end

  @doc "The accent colour setting, normalised by `normalize_color/1`."
  @spec accent_color() :: String.t()
  def accent_color, do: configured_accent_color() || @default_accent

  @doc """
  The accent colour setting as `#rrggbb`, or `nil` when it is unset or not a
  valid colour — the "has the site chosen a colour?" question core's layout
  asks before drawing its accent bar.
  """
  @spec configured_accent_color() :: String.t() | nil
  def configured_accent_color do
    color = Settings.get_setting_cached(@accent_key, nil)
    if valid_color?(color), do: normalize_color(color)
  end

  @doc """
  Whether `value` is a six-digit hex colour (surrounding whitespace allowed).

      iex> PhoenixKit.Email.Branding.valid_color?("#1d4ed8")
      true

      iex> PhoenixKit.Email.Branding.valid_color?("#1d4ed8;x:y")
      false
  """
  @spec valid_color?(term()) :: boolean()
  def valid_color?(value) when is_binary(value),
    do: Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, String.trim(value))

  def valid_color?(_value), do: false

  @doc """
  Whether `value` can stand as a logo URL: empty (no logo), or an absolute
  `http(s)://` address.
  """
  @spec valid_logo_url?(term()) :: boolean()
  def valid_logo_url?(value) when is_binary(value) do
    url = String.trim(value)
    url == "" or Regex.match?(~r/\Ahttps?:\/\/[^\s]+\z/i, url)
  end

  def valid_logo_url?(_value), do: false

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
    if valid_color?(value),
      do: value |> String.trim() |> String.downcase(),
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
  logo, it is in the trash or no longer exists, it sits in a private library,
  it has no file every mail client shows (see "Which file of the logo"), or
  the lookup fails.
  """
  @spec logo_url() :: String.t()
  def logo_url do
    case Settings.get_logo_uuid() do
      uuid when is_binary(uuid) and uuid != "" -> public_logo_url(uuid)
      _none -> ""
    end
  end

  # An email outlives every time-window token, so a private library's logo
  # gets no URL at all rather than one that stops working. A deleted or
  # trashed file gets none either: a broken image is worse than the name.
  defp public_logo_url(uuid) do
    with %{trashed_at: nil} = file <- Storage.get_file(uuid),
         false <- Libraries.private_file?(file),
         %{variant_name: variant} = instance <- email_instance(uuid) do
      Routes.base_url() <> URLSigner.signed_url(uuid, variant, version: instance)
    else
      _no_logo -> ""
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

  defp email_instance(uuid) do
    instances =
      uuid
      |> Storage.list_file_instances()
      |> Enum.filter(
        &(&1.processing_status == "completed" and &1.mime_type in @email_image_types)
      )
      |> Map.new(&{&1.variant_name, &1})

    Enum.find_value(@logo_variants, &Map.get(instances, &1))
  end
end
