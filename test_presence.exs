#!/usr/bin/env elixir

# Simpler test script for presence system
Mix.install([
  {:phoenix_kit, path: "."}
])

IO.puts("Testing PhoenixKit.Admin.Presence...")

# Test 1: List active sessions (should be empty initially)
sessions = PhoenixKit.Admin.Presence.list_active_sessions()
IO.puts("Initial active sessions: #{inspect(sessions)}")
IO.puts("Count: #{length(sessions)}")

# Test 2: Try to track an anonymous session  
case PhoenixKit.Admin.Presence.track_anonymous("test-session-1", %{
       ip_address: "127.0.0.1",
       user_agent: "Test Browser",
       current_page: "/test"
     }) do
  :ok ->
    IO.puts("✓ Successfully tracked anonymous session")

  error ->
    IO.puts("✗ Failed to track anonymous session: #{inspect(error)}")
end

# Give it a moment to process
Process.sleep(500)

# Test 3: List sessions again
sessions = PhoenixKit.Admin.Presence.list_active_sessions()
IO.puts("Active sessions after tracking: #{inspect(sessions)}")
IO.puts("Count: #{length(sessions)}")

# Test 4: Get presence stats
stats = PhoenixKit.Admin.Presence.get_presence_stats()
IO.puts("Presence stats: #{inspect(stats)}")

IO.puts("Test completed!")
