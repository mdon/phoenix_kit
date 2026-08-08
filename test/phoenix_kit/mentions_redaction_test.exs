defmodule PhoenixKit.MentionsRedactionTest do
  @moduledoc """
  The extra-security mode, in its own file and NOT async.

  It flips a real site setting, and settings are ETS-cached rather than
  transactional — a value written inside a sandbox transaction survives the
  rollback in the cache and would leak into whatever async test ran next.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Mentions
  alias PhoenixKit.Settings

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"

  defp set_redaction(value) do
    {:ok, _} = Settings.update_setting("mentions_redact_titles", value)
    :ok
  end

  test "off by default: a record's name is rarely the secret, the access is" do
    set_redaction("false")
    refute Mentions.redact_titles?()
  end

  test "on, a forbidden mention shows the label the author stored" do
    set_redaction("true")

    try do
      assert Mentions.redact_titles?()

      # `post` is registered but declares no visibility check, so it is
      # forbidden for everyone. With redaction on, nothing is resolved for
      # it — the title can only be the author's stored label.
      assert %{state: :forbidden, title: "Name At Write Time"} =
               Mentions.context("see #[post:#{@uuid}|Name At Write Time]")
               |> Map.fetch!({"post", @uuid})
    after
      set_redaction("false")
    end
  end
end
