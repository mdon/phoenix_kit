defmodule PhoenixKit.Utils.RecipientLocale do
  @moduledoc """
  Resolves which locale a message should be rendered in for a given recipient.

  Outbound messages (email, and the external notification channels) render on
  a background or request process that has no meaningful Gettext locale of its
  own — the sender's locale is not the recipient's. This module is the single
  answer to "whose language is this message in".

  ## Where the preference lives

  A user's dialect preference is stored full ("en-GB", "pt-BR") in
  `custom_fields["preferred_locale"]`, written by
  `PhoenixKit.Users.Auth.update_user_locale_preference/2` from the language
  switcher. Absent means the user never chose one.

  ## Two consumers, two shapes

  - `for_rendering/1` — for **template lookup**. Returns the full dialect and
    never `nil`, falling back to the site's content language and then `"en"`.
    Template resolution does its own dialect→base narrowing ("en-GB" is tried
    before "en"), so handing it the dialect strictly beats pre-truncating.
  - `base/1` — for **Gettext**, which keys on base codes and treats `nil` as
    "leave the current locale alone".

  ## Installing it

  `in_locale/2` runs a function with a locale installed on the process, which is
  how a Gettext-backed default reaches the right language: these render on a
  background worker or on behalf of another user, so the locale arrives as a
  value rather than being ambient. `nil` means "leave the current locale alone"
  — what a screen rendering for its own viewer wants.

  ## Failure

  `for_rendering/1` is total. The site default is read through
  `PhoenixKit.Settings`, which can raise on an unowned checkout *or exit* on a
  dead pool; both are caught and answered with `"en"`. An unreachable database
  must degrade a message to English, never fail the send — this is the path
  `PhoenixKit.Users.LoginAlerts` calls during sign-in.
  """

  alias PhoenixKit.Settings

  @fallback "en"

  @doc """
  The recipient's stored dialect preference, or `nil` when they have none.

  Accepts anything: a `%User{}`, a plain map, or a bare email string (used by
  the magic-link registration path, where no account exists yet).

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.preferred(%{custom_fields: %{"preferred_locale" => "en-GB"}})
      "en-GB"
      iex> RecipientLocale.preferred("someone@example.com")
      nil
  """
  @spec preferred(term()) :: String.t() | nil
  def preferred(%{custom_fields: fields}) when is_map(fields) do
    case Map.get(fields, "preferred_locale") do
      locale when is_binary(locale) and locale != "" -> locale
      _ -> nil
    end
  end

  def preferred(_recipient), do: nil

  @doc """
  The recipient's preference as a base language code, or `nil`.

  For Gettext, which keys on base codes; `nil` means "no preference, leave the
  current locale alone".

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.base(%{custom_fields: %{"preferred_locale" => "pt-BR"}})
      "pt"
  """
  @spec base(term()) :: String.t() | nil
  def base(recipient) do
    with locale when is_binary(locale) <- preferred(recipient) do
      locale |> String.split("-") |> hd()
    end
  end

  @doc """
  The locale to render a template in for `recipient`. Never `nil`.

  Preference → the site's content language → `"en"`.

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.for_rendering(%{custom_fields: %{"preferred_locale" => "uk"}})
      "uk"
  """
  @spec for_rendering(term()) :: String.t()
  def for_rendering(recipient) do
    preferred(recipient) || site_default()
  end

  @doc """
  Runs `fun` with `locale` installed on the process, restoring it afterwards.

  A `nil` locale runs `fun` untouched, so a caller with no recipient preference
  keeps whatever locale is already in force.

      iex> alias PhoenixKit.Utils.RecipientLocale
      iex> RecipientLocale.in_locale(nil, fn -> :ran end)
      :ran
  """
  @spec in_locale(String.t() | nil, (-> result)) :: result when result: term()
  def in_locale(nil, fun), do: fun.()

  def in_locale(locale, fun) when is_binary(locale) do
    Gettext.with_locale(PhoenixKitWeb.Gettext, locale, fun)
  end

  defp site_default do
    case Settings.get_content_language() do
      language when is_binary(language) and language != "" -> language
      _ -> @fallback
    end
  rescue
    _ -> @fallback
  catch
    :exit, _ -> @fallback
  end
end
