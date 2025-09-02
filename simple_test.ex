defmodule SimpleTest do
  def test_presence do
    IO.puts("Testing PhoenixKit.Admin.Presence...")

    # Test basic functions
    sessions = PhoenixKit.Admin.Presence.list_active_sessions()
    IO.puts("Active sessions: #{inspect(sessions)}")
    IO.puts("Count: #{length(sessions)}")

    stats = PhoenixKit.Admin.Presence.get_presence_stats()
    IO.puts("Stats: #{inspect(stats)}")
  end
end
