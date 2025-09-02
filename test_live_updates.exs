# Test script for live updates in PhoenixKit admin panels
# 
# This script demonstrates how live updates work by simulating
# user and role changes in the system.

# Our Manager will start its own PubSub automatically
# No manual setup needed

# Test the Events module
alias PhoenixKit.Admin.Events

# Test subscription
IO.puts("Starting live updates test...")

# Subscribe to all events
Events.subscribe_to_all_admin_events()

# Function to listen for events
listen_for_events = fn ->
  receive do
    {:user_created, user} ->
      IO.puts("✅ Received user_created event for user ID: #{user.id}")

    {:user_updated, user} ->
      IO.puts("✅ Received user_updated event for user ID: #{user.id}")

    {:user_role_assigned, user, role_name} ->
      IO.puts("✅ Received user_role_assigned event: User #{user.id} assigned role #{role_name}")

    {:user_role_removed, user, role_name} ->
      IO.puts(
        "✅ Received user_role_removed event: User #{user.id} removed from role #{role_name}"
      )

    {:user_roles_synced, user, new_roles} ->
      IO.puts(
        "✅ Received user_roles_synced event: User #{user.id} synced to roles #{inspect(new_roles)}"
      )

    {:role_created, role} ->
      IO.puts("✅ Received role_created event for role: #{role.name}")

    {:role_updated, role} ->
      IO.puts("✅ Received role_updated event for role: #{role.name}")

    {:role_deleted, role} ->
      IO.puts("✅ Received role_deleted event for role: #{role.name}")

    {:stats_updated, stats} ->
      IO.puts("✅ Received stats_updated event - Total users: #{stats.total_users}")

    other ->
      IO.puts("Received other message: #{inspect(other)}")
  after
    1000 ->
      IO.puts("No events received in the last second")
  end
end

# Listen for events in the current process
IO.puts("Listening for events...")

IO.puts("Broadcasting test events...")

# Test broadcasting events with mock data
mock_user = %{id: 123, email: "test@example.com"}
mock_role = %{id: 1, name: "TestRole"}

mock_stats = %{
  total_users: 10,
  owner_count: 1,
  admin_count: 2,
  user_count: 7,
  active_users: 8,
  inactive_users: 2,
  confirmed_users: 9,
  pending_users: 1
}

# Test each event type using Events API
IO.puts("Testing user created event...")
Events.broadcast_user_created(mock_user)
listen_for_events.()

IO.puts("\nTesting user updated event...")
Events.broadcast_user_updated(mock_user)
listen_for_events.()

IO.puts("\nTesting user role assigned event...")
Events.broadcast_user_role_assigned(mock_user, "Admin")
listen_for_events.()

IO.puts("\nTesting user role removed event...")
Events.broadcast_user_role_removed(mock_user, "User")
listen_for_events.()

IO.puts("\nTesting user roles synced event...")
Events.broadcast_user_roles_synced(mock_user, ["Admin", "Manager"])
listen_for_events.()

IO.puts("\nTesting role created event...")
Events.broadcast_role_created(mock_role)
listen_for_events.()

IO.puts("\nTesting role updated event...")
Events.broadcast_role_updated(mock_role)
listen_for_events.()

IO.puts("\nTesting role deleted event...")
Events.broadcast_role_deleted(mock_role)
listen_for_events.()

IO.puts("\nTesting stats updated event...")
# Manual stats broadcast without database dependency
PhoenixKit.PubSub.Manager.broadcast("phoenix_kit:admin:stats", {:stats_updated, mock_stats})
listen_for_events.()

IO.puts("Test completed! ✨")
IO.puts("\nIf you saw ✅ messages above, the live update system is working correctly!")

IO.puts(
  "In a real application, these events would automatically update all connected admin panels."
)
