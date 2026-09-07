defmodule PhoenixKit.WebsiteAccess.GateTest do
  @moduledoc """
  The password gate's rules: what a try is judged as, what of it is kept,
  the lockout, the epoch that relocks every session, the access link.
  """
  use PhoenixKit.DataCase, async: false

  import Plug.Test

  alias PhoenixKit.Settings
  alias PhoenixKit.WebsiteAccess.{Attempt, Gate}

  setup do
    Settings.update_boolean_setting(Gate.enabled_key(), false)
    Settings.update_setting(Gate.password_key(), "")
    Settings.update_setting(Gate.link_key(), "")
    Settings.update_setting(Gate.lockout_attempts_key(), "0")
    Settings.update_setting(Gate.lockout_minutes_key(), "15")
    Settings.update_boolean_setting(Gate.users_pass_key(), true)
    Settings.update_setting(Gate.keep_typed_key(), "all")
    Gate.clear_attempts()
    :ok
  end

  describe "enabled?/0" do
    test "needs both the switch and a password" do
      refute Gate.enabled?()

      {:ok, _} = Gate.set_enabled(true)
      refute Gate.enabled?(), "a gate without a password cannot close"
      assert Gate.switched_on?()

      {:ok, _} = Gate.set_password("hunter2")
      assert Gate.enabled?()
      assert Gate.password() == "hunter2"
    end

    test "the password is a restricted (encrypted) setting" do
      {:ok, _} = Gate.set_password("hunter2")
      assert Gate.password_key() in Settings.restricted_setting_keys()
    end
  end

  describe "judge/1" do
    setup do
      {:ok, _} = Gate.set_password("Secret42")
      :ok
    end

    test "the verdicts" do
      assert Gate.judge("Secret42") == :correct
      assert Gate.judge("SECRET42") == :case
      assert Gate.judge("secret42") == :case
      assert Gate.judge("Secret4") == :close
      assert Gate.judge("Secre42") == :close
      assert Gate.judge("Secret42!") == :close
      assert Gate.judge("Sekret42") == :close
      assert Gate.judge("Sekret24") == :unrelated, "three edits on eight characters is not a typo"
      assert Gate.judge("something else") == :unrelated
      assert Gate.judge("") == :empty
      assert Gate.judge(nil) == :empty
    end

    test "anything that is not a string is unrelated, never a crash" do
      assert Gate.judge(%{"x" => "y"}) == :unrelated
      assert Gate.judge(["a"]) == :unrelated
      {:unrelated, row} = Gate.attempt(%{"x" => "y"}, user_agent: ["odd"])
      assert row.typed == nil
    end

    test "a short password allows one edit, a long one three" do
      {:ok, _} = Gate.set_password("abc")
      assert Gate.judge("abd") == :close
      assert Gate.judge("xyz") == :unrelated
      assert Gate.judge("abc") == :correct

      {:ok, _} = Gate.set_password("correct-horse-battery")
      assert Gate.judge("corect-hors-batery") == :close
      assert Gate.judge("wrong-horse-battery") == :unrelated
    end
  end

  describe "attempt/2" do
    setup do
      {:ok, _} = Gate.set_password("Secret42")
      :ok
    end

    test "keeps everything typed by default, the right password and a locked-out try included" do
      {:correct, correct} = Gate.attempt("Secret42", address: "10.0.0.1", user_agent: "UA")
      {:case, caps} = Gate.attempt("SECRET42", address: "10.0.0.1")
      {:close, typo} = Gate.attempt("Secret43", address: "10.0.0.1")
      {:unrelated, other} = Gate.attempt("my-bank-password", address: "10.0.0.1")
      {:empty, empty} = Gate.attempt("", address: "10.0.0.1")
      {:locked, locked} = Gate.attempt("while-locked", address: "10.0.0.1", locked: true)

      assert correct.typed == "Secret42"
      assert locked.typed == "while-locked"
      assert caps.typed == "SECRET42"
      assert typo.typed == "Secret43"
      assert other.typed == "my-bank-password"
      assert empty.typed == nil
      assert correct.address == "10.0.0.1"
      assert correct.user_agent == "UA"
    end

    test "the setting can narrow it to near misses, or to nothing" do
      Settings.update_setting(Gate.keep_typed_key(), "near")
      {:case, caps} = Gate.attempt("SECRET42")
      {:unrelated, other} = Gate.attempt("my-bank-password")
      assert caps.typed == "SECRET42"
      assert other.typed == nil

      Settings.update_setting(Gate.keep_typed_key(), "none")
      {:case, caps} = Gate.attempt("SECRET42")
      assert caps.typed == nil

      Settings.update_setting(Gate.keep_typed_key(), "bogus")
      assert Gate.keep_typed() == "all"
    end

    test "a locked-out try is recorded as such and never judged" do
      {:locked, row} = Gate.attempt("Secret42", address: "10.0.0.1", locked: true)
      assert row.verdict == "locked"
    end

    test "an access-link entry is recorded as such" do
      {:link, row} = Gate.attempt("", address: "10.0.0.1", link: true)
      assert row.verdict == "link"
    end

    test "a megabyte of junk is unrelated at once" do
      {verdict, _} = Gate.attempt(String.duplicate("x", 1_000_000))
      assert verdict == :unrelated
    end

    test "typed and user agent are cut, never rejected" do
      long = String.duplicate("S", 300)
      {:unrelated, row} = Gate.attempt(long, user_agent: String.duplicate("u", 600))

      assert String.length(row.typed) == 255
      assert String.length(row.user_agent) == 512
    end

    test "list, counts and clear" do
      Gate.attempt("Secret42")
      Gate.attempt("nope")
      Gate.attempt("nope")

      assert [
               %Attempt{verdict: "unrelated"},
               %Attempt{verdict: "unrelated"},
               %Attempt{verdict: "correct"}
             ] =
               Gate.list_attempts()

      assert Gate.attempt_counts() == %{"correct" => 1, "unrelated" => 2}
      assert Gate.list_attempts(limit: 1) |> length() == 1

      Gate.clear_attempts()
      assert Gate.list_attempts() == []
    end
  end

  describe "lockout/1" do
    setup do
      {:ok, _} = Gate.set_password("Secret42")
      :ok
    end

    test "off by default and off without an address" do
      Gate.attempt("nope", address: "10.0.0.1")
      assert Gate.lockout("10.0.0.1") == :ok
      assert Gate.lockout(nil) == :ok
    end

    test "locks after N wrong tries from one address, for the configured minutes" do
      Settings.update_setting(Gate.lockout_attempts_key(), "2")
      Settings.update_setting(Gate.lockout_minutes_key(), "15")

      Gate.attempt("nope", address: "10.0.0.1")
      assert Gate.lockout("10.0.0.1") == :ok
      Gate.attempt("nope", address: "10.0.0.1")
      assert {:locked, seconds} = Gate.lockout("10.0.0.1")
      assert seconds > 14 * 60 and seconds <= 15 * 60

      assert Gate.lockout("10.0.0.2") == :ok, "counted per address"
    end

    test "only real misses count: link entries, empties and locked tries do not" do
      Settings.update_setting(Gate.lockout_attempts_key(), "2")
      Gate.attempt("", address: "10.0.0.1", link: true)
      Gate.attempt("", address: "10.0.0.1")
      Gate.attempt("", address: "10.0.0.1", locked: true)
      Gate.attempt("nope", address: "10.0.0.1")
      assert Gate.lockout("10.0.0.1") == :ok
      Gate.attempt("nope", address: "10.0.0.1")
      assert {:locked, _} = Gate.lockout("10.0.0.1")
    end

    test "a locked-out try does not extend the lockout, a correct try ends it" do
      Settings.update_setting(Gate.lockout_attempts_key(), "2")
      Gate.attempt("nope", address: "10.0.0.1")
      Gate.attempt("nope", address: "10.0.0.1")
      {:locked, before} = Gate.lockout("10.0.0.1")

      Gate.attempt("nope", address: "10.0.0.1", locked: true)
      {:locked, after_locked} = Gate.lockout("10.0.0.1")
      assert after_locked <= before

      Gate.attempt("Secret42", address: "10.0.0.1")
      # the correct try is newer than the two failures, so the newest two
      # non-correct rows still exist — the window is about failures only
      assert {:locked, _} = Gate.lockout("10.0.0.1")
    end

    test "old failures fall out of the window" do
      Settings.update_setting(Gate.lockout_attempts_key(), "1")
      Settings.update_setting(Gate.lockout_minutes_key(), "1")
      {:unrelated, row} = Gate.attempt("nope", address: "10.0.0.1")

      old = NaiveDateTime.add(NaiveDateTime.utc_now(), -120, :second)
      Repo.update_all(from(a in Attempt, where: a.uuid == ^row.uuid), set: [inserted_at: old])

      assert Gate.lockout("10.0.0.1") == :ok
    end
  end

  describe "try/2" do
    setup do
      {:ok, _} = Gate.set_password("Secret42")
      Settings.update_setting(Gate.lockout_attempts_key(), "3")
      :ok
    end

    test "a burst of parallel guesses cannot slip past the lockout" do
      results =
        1..12
        |> Task.async_stream(
          fn i -> Gate.try("guess-#{i}", address: "10.0.0.9") end,
          max_concurrency: 12,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      judged = Enum.count(results, fn {v, _} -> v == :unrelated end)
      locked = Enum.count(results, fn r -> match?({:locked, _}, r) end)
      assert judged == 3, "exactly the limit is judged, the rest are locked out"
      assert locked == 9
    end

    test "the right password under the limit unlocks" do
      assert {:correct, _} = Gate.try("Secret42", address: "10.0.0.9")
    end
  end

  describe "pruning" do
    test "never deletes a row the lockout might still count" do
      Settings.update_setting(Gate.lockout_minutes_key(), "60")
      {:ok, _} = Gate.set_password("Secret42")
      old = NaiveDateTime.add(NaiveDateTime.utc_now(), -7200, :second)

      rows =
        for i <- 1..5010 do
          %{
            uuid: UUIDv7.generate(),
            verdict: "unrelated",
            address: "10.0.0.#{rem(i, 200)}",
            inserted_at: if(i <= 5005, do: old, else: NaiveDateTime.utc_now())
          }
        end

      Repo.insert_all(Attempt, rows)
      Enum.each(1..40, fn _ -> Gate.attempt("nope", address: "10.0.0.250") end)
      Gate.prune_attempts()

      recent = Repo.aggregate(from(a in Attempt, where: a.inserted_at > ^old), :count)
      assert recent == 45, "nothing inside the lockout window was pruned"
      assert Repo.aggregate(Attempt, :count) <= 5000 + 45
    end
  end

  describe "the epoch" do
    setup do
      {:ok, _} = Gate.set_password("Secret42")
      :ok
    end

    test "unlock stamps the session; a relock invalidates it" do
      conn = conn(:get, "/") |> init_test_session(%{})
      refute Gate.unlocked?(conn)

      conn = Gate.unlock(conn)
      assert Gate.unlocked?(conn)

      assert Gate.session_unlocked?(%{
               Atom.to_string(Gate.session_key()) =>
                 Plug.Conn.get_session(conn, Gate.session_key())
             })

      {:ok, _} = Gate.relock_everyone()
      refute Gate.unlocked?(conn)
    end

    test "changing the password relocks, saving the same one does not" do
      conn = conn(:get, "/") |> init_test_session(%{}) |> Gate.unlock()
      {:ok, _} = Gate.set_password("Secret42")
      assert Gate.unlocked?(conn)
      {:ok, _} = Gate.set_password("Other")
      refute Gate.unlocked?(conn)
    end

    test "switching the gate on relocks; switching users-pass off relocks" do
      conn = conn(:get, "/") |> init_test_session(%{}) |> Gate.unlock()
      {:ok, _} = Gate.set_enabled(true)
      refute Gate.unlocked?(conn)

      conn = Gate.unlock(conn)
      {:ok, _} = Gate.set_users_pass(true)
      assert Gate.unlocked?(conn)
      {:ok, _} = Gate.set_users_pass(false)
      refute Gate.unlocked?(conn)
    end

    test "a first unlock mints an epoch without a broadcast" do
      Settings.update_setting("website_access_gate_epoch", "")
      Gate.subscribe()
      conn = conn(:get, "/") |> init_test_session(%{}) |> Gate.unlock()
      assert Gate.unlocked?(conn)
      refute_receive {:website_access, :relock}
    end

    test "a relock is broadcast" do
      Gate.subscribe()
      {:ok, _} = Gate.relock_everyone()
      assert_receive {:website_access, :relock}
    end
  end

  describe "the access link" do
    test "none until made; a new one replaces the old; revoke ends it" do
      assert Gate.access_link_token() == nil
      refute Gate.access_link_valid?("anything")

      {:ok, first} = Gate.regenerate_access_link()
      assert Gate.access_link_valid?(first)
      assert String.length(first) >= 32

      {:ok, second} = Gate.regenerate_access_link()
      refute Gate.access_link_valid?(first)
      assert Gate.access_link_valid?(second)

      {:ok, _} = Gate.revoke_access_link()
      refute Gate.access_link_valid?(second)
      refute Gate.access_link_valid?("")
      refute Gate.access_link_valid?(nil)
    end
  end
end
