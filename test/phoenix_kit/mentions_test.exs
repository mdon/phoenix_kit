defmodule PhoenixKit.MentionsTest do
  @moduledoc """
  The token grammar and the index/notify lifecycle.

  The grammar tests are the load-bearing ones: the format is what every
  other half depends on, and getting it wrong silently turns prose into
  links or links into prose.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Mentions
  alias PhoenixKit.Mentions.Token

  @uuid "018e3c4a-9f6b-7890-abcd-ef1234567890"
  @other "018e3c4a-9f6b-7890-abcd-ef1234567891"

  describe "Token.parse/1" do
    test "finds both kinds and keeps their labels" do
      text = "Hi @[user:#{@uuid}|Alice Smith], see #[project:#{@other}|Q3 Launch]"

      assert [user, project] = Token.parse(text)
      assert user.kind == :user
      assert user.type == "user"
      assert user.label == "Alice Smith"
      assert project.kind == :resource
      assert project.type == "project"
      assert project.label == "Q3 Launch"
    end

    test "bare @name and #tag are prose, not mentions" do
      # Publishing's hashtags share the trigger character; only the closed
      # form is a mention, which is what keeps the two from colliding.
      assert Token.parse("ping @alice about #launch and email a@b.com") == []
    end

    test "a backslash escapes a complete token" do
      assert Token.parse("literally \\@[user:#{@uuid}|Alice]") == []
    end

    test "an incomplete token stays text" do
      # Mid-typing, or a truncated paste. Neither should become a link.
      assert Token.parse("@[user:#{@uuid}|Alice") == []
      assert Token.parse("@[user:not-a-uuid|Alice]") == []
      assert Token.parse("@[user:#{@uuid}|]") == []
    end

    test "nil and non-binaries yield nothing rather than raising" do
      assert Token.parse(nil) == []
      assert Token.parse(123) == []
    end
  end

  describe "Token.to_string/4" do
    test "builds the canonical form" do
      assert {:ok, token} = Token.to_string(:resource, "project", @uuid, "Q3 Launch")
      assert token == "#[project:#{@uuid}|Q3 Launch]"
      assert [parsed] = Token.parse(token)
      assert parsed.uuid == @uuid
    end

    test "refuses a label that would break the grammar" do
      # The picker is the only thing that builds tokens, so it can simply
      # not produce these rather than the format carrying escape rules.
      assert Token.to_string(:user, "user", @uuid, "bad|label") == :error
      assert Token.to_string(:user, "user", @uuid, "bad]label") == :error
      assert Token.to_string(:user, "user", @uuid, "   ") == :error
    end

    test "refuses a bad uuid or type" do
      assert Token.to_string(:user, "user", "nope", "Alice") == :error
      assert Token.to_string(:user, "Bad Type", @uuid, "Alice") == :error
    end
  end

  describe "Token.split/1" do
    test "keeps the surrounding text in order" do
      text = "a @[user:#{@uuid}|Alice] b"
      assert [before, %Token{} = token, rest] = Token.split(text)
      assert before == "a "
      assert token.label == "Alice"
      assert rest == " b"
    end

    test "an escaped token comes back as text with the backslash gone" do
      assert ["@[user:#{@uuid}|Alice]"] == Token.split("\\@[user:#{@uuid}|Alice]")
    end
  end

  describe "Token.to_plain_text/1" do
    test "reduces mentions to readable words" do
      text = "Hi @[user:#{@uuid}|Alice], see #[project:#{@other}|Q3 Launch]"
      assert Token.to_plain_text(text) == "Hi @Alice, see Q3 Launch"
    end
  end

  describe "sync/4" do
    setup do
      {:ok, source: Ecto.UUID.generate()}
    end

    test "indexes what the text mentions", %{source: source} do
      text = "see #[project:#{@uuid}|Q3] and #[project:#{@other}|Q4]"

      assert {:ok, new} = Mentions.sync("comment", source, text)
      assert length(new) == 2
      assert length(Mentions.list_for_source("comment", source)) == 2
    end

    test "re-saving the same text reports nothing new", %{source: source} do
      text = "see #[project:#{@uuid}|Q3]"

      assert {:ok, [_]} = Mentions.sync("comment", source, text)
      assert {:ok, []} = Mentions.sync("comment", source, text)
    end

    test "removing a mention removes its row", %{source: source} do
      assert {:ok, [_]} = Mentions.sync("comment", source, "#[project:#{@uuid}|Q3]")
      assert {:ok, []} = Mentions.sync("comment", source, "nothing here now")
      assert Mentions.list_for_source("comment", source) == []
    end

    test "the same target twice in one field is one mention", %{source: source} do
      text = "#[project:#{@uuid}|Q3] and again #[project:#{@uuid}|Q3]"

      assert {:ok, [_only_one]} = Mentions.sync("comment", source, text)
    end

    test "fields are independent", %{source: source} do
      # A record with a description AND a summary must not have one field's
      # save wipe the other's mentions.
      assert {:ok, [_]} =
               Mentions.sync("task", source, "#[project:#{@uuid}|Q3]", field: "description")

      assert {:ok, [_]} =
               Mentions.sync("task", source, "#[project:#{@other}|Q4]", field: "summary")

      assert length(Mentions.list_for_source("task", source, "description")) == 1
      assert length(Mentions.list_for_source("task", source, "summary")) == 1
    end

    test "backlinks find the source", %{source: source} do
      assert {:ok, _} = Mentions.sync("comment", source, "#[project:#{@uuid}|Q3]")

      assert [backlink] = Mentions.list_backlinks("project", @uuid)
      assert backlink.source_uuid == source
      assert backlink.label == "Q3"
    end

    test "empty text is not an error", %{source: source} do
      assert {:ok, []} = Mentions.sync("comment", source, nil)
      assert {:ok, []} = Mentions.sync("comment", source, "")
    end
  end

  describe "context/2" do
    test "an unresolvable type is missing, not forbidden" do
      # No handler for "nonesuch": nothing can resolve it, but nothing is
      # hiding it either — the reader should get the author's words.
      text = "see #[nonesuch:#{@uuid}|Some Thing]"

      assert %{{"nonesuch", @uuid} => %{state: :missing}} = Mentions.context(text)
    end

    test "text without mentions costs nothing" do
      assert Mentions.context("just words") == %{}
      assert Mentions.context(nil) == %{}
    end
  end
end
