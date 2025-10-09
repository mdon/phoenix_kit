# Making Pages Live: Real-time Updates & Collaborative Editing

This guide explains how to add real-time functionality to LiveView pages in PhoenixKit, including PubSub events, presence tracking, and collaborative editing.

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Events System](#events-system)
4. [Presence Tracking](#presence-tracking)
5. [Collaborative State Storage](#collaborative-state-storage)
6. [On Mount Hooks](#on-mount-hooks)
7. [Common Patterns](#common-patterns)
8. [Troubleshooting](#troubleshooting)

---

## Overview

PhoenixKit provides three main systems for real-time functionality:

### 1. Events System (PubSub Broadcasting)
**Location:** `lib/phoenix_kit/entities/events.ex`

Broadcasts create/update/delete events across all LiveView sessions.

**Key Functions:**
- `subscribe_to_entities()` - Subscribe to all entity events
- `subscribe_to_entity_data(entity_id)` - Subscribe to specific entity's data events
- `broadcast_entity_created(entity_id)` - Notify about new entity
- `broadcast_entity_updated(entity_id)` - Notify about entity changes
- `broadcast_data_updated(entity_id, data_id)` - Notify about data changes

### 2. SimplePresence (Presence Tracking)
**Location:** `lib/phoenix_kit/admin/simple_presence.ex`

Unified presence tracking for sessions, collaborative editors, and any resource.

**Key Functions:**
- `track(key, metadata, pid)` - Track any resource (editors, viewers, etc.)
- `list_tracked(prefix)` - List all tracked items matching prefix
- `count_tracked(prefix)` - Count tracked items
- `untrack(key)` - Stop tracking

### 3. State Storage (Collaborative Editing)
**Location:** `lib/phoenix_kit/admin/simple_presence.ex`

Temporary state storage with 5-minute auto-expiration for collaborative editing.

**Key Functions:**
- `store_data(key, data)` - Store state (expires in 5 min)
- `get_data(key)` - Retrieve state (returns nil if expired)
- `clear_data(key)` - Manually clear state

---

## Quick Start

### Example 1: Add Real-time Updates to a List Page

```elixir
defmodule PhoenixKitWeb.Live.MyResourcesLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Entities.Events
  alias PhoenixKit.MyContext

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to events when connected
    if connected?(socket) do
      Events.subscribe_to_entities()
    end

    resources = MyContext.list_resources()

    {:ok, assign(socket, :resources, resources)}
  end

  # Handle real-time updates
  @impl true
  def handle_info({:entity_created, _entity_id}, socket) do
    # Reload and update the list
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:entity_updated, _entity_id}, socket) do
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:entity_deleted, _entity_id}, socket) do
    resources = MyContext.list_resources()
    {:noreply, assign(socket, :resources, resources)}
  end
end
```

### Example 2: Add Collaborative Editing to a Form

```elixir
defmodule PhoenixKitWeb.Live.MyResourceFormLive do
  use PhoenixKitWeb, :live_view

  alias PhoenixKit.Admin.SimplePresence, as: Presence
  alias PhoenixKit.Entities.Events

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)
    form_key = "resource:#{id}"

    socket = assign(socket,
      resource: resource,
      form_key: form_key,
      changeset: MyContext.change_resource(resource)
    )

    if connected?(socket) do
      # Track this editor
      Presence.track("editor:resource:#{id}:", %{
        user_email: socket.assigns.current_user.email
      })

      # Subscribe to form changes from other editors
      Events.subscribe_to_entities()

      # Load collaborative state if other editors are present
      editor_count = Presence.count_tracked("editor:resource:#{id}:")

      socket = if editor_count > 1 do
        case Presence.get_data("state:resource:#{id}") do
          %{changeset_params: params} ->
            changeset = MyContext.change_resource(resource, params)
            assign(socket, changeset: changeset, has_unsaved_changes: true)
          _ ->
            socket
        end
      else
        socket
      end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"resource" => params}, socket) do
    changeset = MyContext.change_resource(socket.assigns.resource, params)

    # Broadcast changes to other editors
    broadcast_changes(socket, params)

    {:noreply, assign(socket, changeset: changeset, has_unsaved_changes: true)}
  end

  # Receive changes from other editors
  @impl true
  def handle_info({:resource_form_change, %{params: params}}, socket) do
    changeset = MyContext.change_resource(socket.assigns.resource, params)
    {:noreply, assign(socket, changeset: changeset)}
  end

  # Cleanup on navigation away
  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:resource] do
      resource_id = socket.assigns.resource.id
      Presence.untrack("editor:resource:#{resource_id}:")

      # Clear state if last editor
      if Presence.count_tracked("editor:resource:#{resource_id}:") == 0 do
        Presence.clear_data("state:resource:#{resource_id}")
      end
    end
    :ok
  end

  defp broadcast_changes(socket, params) do
    resource_id = socket.assigns.resource.id
    editor_count = Presence.count_tracked("editor:resource:#{resource_id}:")

    # Always store state for late-joining editors
    Presence.store_data("state:resource:#{resource_id}", %{
      changeset_params: params
    })

    # Only broadcast when multiple editors present
    if editor_count > 1 do
      Events.broadcast_resource_form_change(socket.assigns.form_key, %{params: params})
    end
  end
end
```

---

## Events System

### Creating an Events Module

**File:** `lib/phoenix_kit/entities/events.ex`

```elixir
defmodule PhoenixKit.Entities.Events do
  @moduledoc """
  PubSub event broadcasting for entity lifecycle events.
  """

  alias PhoenixKit.PubSub.Manager

  @entity_topic "phoenix_kit:entities"
  @entity_data_topic_prefix "phoenix_kit:entity_data:"

  # Subscription functions
  def subscribe_to_entities do
    Manager.subscribe(@entity_topic)
  end

  def subscribe_to_entity_data(entity_id) do
    Manager.subscribe(@entity_data_topic_prefix <> to_string(entity_id))
  end

  # Broadcasting functions
  def broadcast_entity_created(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_created, entity_id})
  end

  def broadcast_entity_updated(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_updated, entity_id})
  end

  def broadcast_entity_deleted(entity_id) do
    Manager.broadcast(@entity_topic, {:entity_deleted, entity_id})
  end

  def broadcast_data_created(entity_id, data_id) do
    Manager.broadcast(@entity_data_topic_prefix <> to_string(entity_id),
      {:data_created, entity_id, data_id})
  end

  def broadcast_data_updated(entity_id, data_id) do
    Manager.broadcast(@entity_data_topic_prefix <> to_string(entity_id),
      {:data_updated, entity_id, data_id})
  end
end
```

### Adding Event Broadcasting to Context Functions

**Pattern:** Pipe the result through a notification function.

```elixir
defmodule PhoenixKit.Entities do
  alias PhoenixKit.Entities.Events

  def create_entity(attrs) do
    %Entity{}
    |> changeset(attrs)
    |> repo().insert()
    |> notify_entity_event(:created)
  end

  def update_entity(entity, attrs) do
    entity
    |> changeset(attrs)
    |> repo().update()
    |> notify_entity_event(:updated)
  end

  def delete_entity(entity) do
    entity
    |> repo().delete()
    |> notify_entity_event(:deleted)
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :created) do
    Events.broadcast_entity_created(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :updated) do
    Events.broadcast_entity_updated(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event({:ok, %Entity{} = entity}, :deleted) do
    Events.broadcast_entity_deleted(entity.id)
    {:ok, entity}
  end

  defp notify_entity_event(result, _event), do: result
end
```

---

## Presence Tracking

### Tracking Editors

**Key Pattern:** Use prefix-based keys for easy querying.

```elixir
# Track an editor
Presence.track("editor:entity:#{entity_id}:", %{
  user_email: current_user.email,
  connected_at: DateTime.utc_now()
})

# Count editors for this entity
editor_count = Presence.count_tracked("editor:entity:#{entity_id}:")

# List all editors
editors = Presence.list_tracked("editor:entity:#{entity_id}:")

# Untrack when done
Presence.untrack("editor:entity:#{entity_id}:")
```

### Tracking Multiple Resources

```elixir
# Track viewers of a page
Presence.track("viewer:page:/admin/dashboard:", %{
  user_email: current_user.email,
  ip_address: get_ip(socket)
})

# Track any custom resource
Presence.track("custom:my_resource:#{id}:", %{
  custom_field: "value"
})
```

### Presence in Templates

Show who else is editing:

```heex
<div class="flex items-center gap-2">
  <%= if @editor_count > 1 do %>
    <span class="text-sm text-gray-600">
      <%= @editor_count - 1 %> other <%= if @editor_count == 2, do: "person", else: "people" %> editing
    </span>
  <% end %>
</div>
```

```elixir
# In mount/3 or handle_info/2
editor_count = Presence.count_tracked("editor:entity:#{entity_id}:")
assign(socket, :editor_count, editor_count)
```

---

## Collaborative State Storage

### Storing Form State

**Important:** State auto-expires after 5 minutes to prevent persistence bugs.

```elixir
defp broadcast_form_state(socket, params) do
  entity_id = socket.assigns.entity.id
  editor_count = Presence.count_tracked("editor:entity:#{entity_id}:")

  payload = %{
    changeset_params: params,
    custom_field: socket.assigns.custom_field
  }

  # ALWAYS store state for late-joining editors
  Presence.store_data("state:entity:#{entity_id}", payload)

  # Only broadcast when multiple editors present (reduces PubSub overhead)
  if editor_count > 1 do
    Events.broadcast_entity_form_change(socket.assigns.form_key, payload)
  end
end
```

### Loading State on Mount

**Pattern:** Only load if other editors are present.

```elixir
if connected?(socket) do
  Presence.track("editor:entity:#{entity_id}:", %{...})

  editor_count = Presence.count_tracked("editor:entity:#{entity_id}:")

  socket = if editor_count > 1 do
    # Other editors present - load collaborative state
    case Presence.get_data("state:entity:#{entity_id}") do
      %{changeset_params: params} = state ->
        changeset = Entities.change_entity(entity, params)
        socket
        |> assign(:changeset, changeset)
        |> assign(:has_unsaved_changes, true)

      _ ->
        socket
    end
  else
    # No other editors - start fresh from database
    socket
  end

  {:ok, socket}
end
```

### Cleanup on Terminate

```elixir
@impl true
def terminate(_reason, socket) do
  if socket.assigns[:entity] && socket.assigns.entity.id do
    entity_id = socket.assigns.entity.id

    # Untrack this editor
    Presence.untrack("editor:entity:#{entity_id}:")

    # Clear state if last editor
    if Presence.count_tracked("editor:entity:#{entity_id}:") == 0 do
      Presence.clear_data("state:entity:#{entity_id}")
    end
  end

  :ok
end
```

---

## On Mount Hooks

### Creating Centralized Subscriptions

**File:** `lib/phoenix_kit_web/live/modules/entities/hooks.ex`

```elixir
defmodule PhoenixKitWeb.Live.Modules.Entities.Hooks do
  @moduledoc """
  LiveView hooks for entity module pages.
  Provides common setup and subscriptions for all entity-related LiveViews.
  """

  import Phoenix.LiveView
  alias PhoenixKit.Entities.Events

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_to_entities()
    end

    {:cont, socket}
  end
end
```

### Using Hooks in LiveViews

```elixir
defmodule PhoenixKitWeb.Live.Modules.Entities.EntitiesLive do
  use PhoenixKitWeb, :live_view

  # Add this line to use the hook
  on_mount PhoenixKitWeb.Live.Modules.Entities.Hooks

  # Now you don't need to call Events.subscribe_to_entities() in mount/3
  # It's handled automatically by the hook!

  @impl true
  def mount(_params, _session, socket) do
    entities = Entities.list_entities()
    {:ok, assign(socket, :entities, entities)}
  end

  # Still need handle_info callbacks
  @impl true
  def handle_info({:entity_created, _entity_id}, socket) do
    {:noreply, assign(socket, :entities, Entities.list_entities())}
  end
end
```

---

## Common Patterns

### Pattern 1: List Page with Real-time Updates

**Reference:** `lib/phoenix_kit_web/live/modules/entities/entities.ex`

```elixir
defmodule MyApp.MyResourcesLive do
  use MyAppWeb, :live_view
  on_mount MyAppWeb.Live.Hooks  # Centralized subscriptions

  @impl true
  def mount(_params, _session, socket) do
    resources = load_resources()
    {:ok, assign(socket, :resources, resources)}
  end

  @impl true
  def handle_info({:resource_created, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  @impl true
  def handle_info({:resource_updated, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  @impl true
  def handle_info({:resource_deleted, _id}, socket) do
    {:noreply, assign(socket, :resources, load_resources())}
  end

  defp load_resources do
    MyContext.list_resources()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
```

### Pattern 2: Detail Page with Remote Updates

**Reference:** `lib/phoenix_kit_web/live/modules/entities/data_navigator.ex`

```elixir
defmodule MyApp.MyResourceDetailLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)

    if connected?(socket) do
      Events.subscribe_to_resource(id)
    end

    {:ok, assign(socket, :resource, resource)}
  end

  @impl true
  def handle_info({:resource_updated, resource_id}, socket) do
    if resource_id == socket.assigns.resource.id do
      resource = MyContext.get_resource!(resource_id)

      # Check if resource was archived/deleted
      if resource.status == "archived" do
        {:noreply,
         socket
         |> put_flash(:warning, "Resource was archived in another session")
         |> redirect(to: ~p"/admin/resources")}
      else
        # Update with fresh data
        {:noreply, assign(socket, :resource, resource)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:resource_deleted, resource_id}, socket) do
    if resource_id == socket.assigns.resource.id do
      {:noreply,
       socket
       |> put_flash(:error, "Resource was deleted in another session")
       |> redirect(to: ~p"/admin/resources")}
    else
      {:noreply, socket}
    end
  end
end
```

### Pattern 3: Collaborative Form Editing

**Reference:** `lib/phoenix_kit_web/live/modules/entities/entity_form.ex`

```elixir
defmodule MyApp.MyResourceFormLive do
  use MyAppWeb, :live_view

  alias PhoenixKit.Admin.SimplePresence, as: Presence

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resource = MyContext.get_resource!(id)
    changeset = MyContext.change_resource(resource)
    form_key = "resource_form:#{id}"

    socket = assign(socket,
      resource: resource,
      changeset: changeset,
      form_key: form_key,
      has_unsaved_changes: false
    )

    if connected?(socket) do
      # Track this editor
      Presence.track("editor:resource:#{id}:", %{
        user_email: socket.assigns.current_user.email
      })

      # Subscribe to form changes
      Events.subscribe_to_resource_form(form_key)

      # Load collaborative state if others editing
      editor_count = Presence.count_tracked("editor:resource:#{id}:")

      socket = if editor_count > 1 do
        case Presence.get_data("state:resource:#{id}") do
          %{params: params} ->
            changeset = MyContext.change_resource(resource, params)
            assign(socket, changeset: changeset, has_unsaved_changes: true)
          _ ->
            socket
        end
      else
        socket
      end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  @impl true
  def handle_event("validate", %{"resource" => params}, socket) do
    changeset = MyContext.change_resource(socket.assigns.resource, params)

    broadcast_state(socket, params)

    {:noreply, assign(socket, changeset: changeset, has_unsaved_changes: true)}
  end

  @impl true
  def handle_event("save", %{"resource" => params}, socket) do
    case MyContext.update_resource(socket.assigns.resource, params) do
      {:ok, resource} ->
        # Clear collaborative state after save
        Presence.clear_data("state:resource:#{resource.id}")

        {:noreply,
         socket
         |> put_flash(:info, "Resource updated successfully")
         |> redirect(to: ~p"/admin/resources/#{resource.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end

  # Receive changes from other editors
  @impl true
  def handle_info({:resource_form_change, %{params: params}}, socket) do
    changeset = MyContext.change_resource(socket.assigns.resource, params)
    {:noreply, assign(socket, changeset: changeset)}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:resource] do
      resource_id = socket.assigns.resource.id
      Presence.untrack("editor:resource:#{resource_id}:")

      if Presence.count_tracked("editor:resource:#{resource_id}:") == 0 do
        Presence.clear_data("state:resource:#{resource_id}")
      end
    end
    :ok
  end

  defp broadcast_state(socket, params) do
    resource_id = socket.assigns.resource.id
    editor_count = Presence.count_tracked("editor:resource:#{resource_id}:")

    # Always store for late joiners
    Presence.store_data("state:resource:#{resource_id}", %{params: params})

    # Only broadcast when multiple editors
    if editor_count > 1 do
      Events.broadcast_resource_form_change(socket.assigns.form_key, %{params: params})
    end
  end
end
```

---

## Troubleshooting

### Issue: State Persists Across Sessions

**Symptom:** Users see old unsaved changes when returning to a form.

**Causes:**
1. State not being cleared when last editor leaves
2. Cleanup timing issues

**Solution:** SimplePresence auto-expires state after 5 minutes. If issue persists:
- Verify `terminate/2` is being called
- Check `Presence.count_tracked()` returns correct count
- Add logging to `terminate/2` to confirm cleanup runs

### Issue: Changes Not Appearing for Other Editors

**Symptom:** User A types but User B doesn't see updates.

**Causes:**
1. Not subscribed to the right topic
2. Broadcasting not happening
3. handle_info not implemented

**Solution:**
```elixir
# Verify subscription
if connected?(socket) do
  Events.subscribe_to_resource_form(form_key)
end

# Verify broadcasting
if editor_count > 1 do
  Events.broadcast_resource_form_change(form_key, payload)
end

# Verify handle_info
def handle_info({:resource_form_change, payload}, socket) do
  # Apply changes
  {:noreply, updated_socket}
end
```

### Issue: Editor Count Wrong

**Symptom:** `count_tracked()` returns incorrect numbers.

**Causes:**
1. Not using consistent key prefixes
2. Forgetting to untrack on terminate

**Solution:**
```elixir
# Use consistent keys with trailing colon
"editor:resource:#{id}:"  # ✅ Good - includes trailing colon
"editor:resource:#{id}"   # ❌ Bad - missing colon

# Always untrack in terminate
def terminate(_reason, socket) do
  Presence.untrack("editor:resource:#{socket.assigns.resource.id}:")
  :ok
end
```

### Issue: Race Condition with Late Joiners

**Symptom:** User B joins but doesn't see User A's changes until next keystroke.

**Expected Behavior:** This is normal! The pattern is:
1. User A makes changes → stored in state
2. User B joins → loads stored state ✅
3. User A types → User B sees via broadcast ✅

If User B isn't loading state on join:
```elixir
# Check this block runs
if editor_count > 1 do
  case Presence.get_data("state:resource:#{id}") do
    %{params: params} -> # Apply params
    _ -> # No state available
  end
end
```

### Issue: Broadcasts Continue After Navigation

**Symptom:** Console warnings about broadcasts to dead processes.

**Cause:** Not untracking editors in terminate.

**Solution:**
```elixir
@impl true
def terminate(_reason, socket) do
  if socket.assigns[:resource] do
    Presence.untrack("editor:resource:#{socket.assigns.resource.id}:")
  end
  :ok
end
```

---

## Best Practices

### 1. Always Use Trailing Colons in Presence Keys
```elixir
# Good - allows prefix matching
"editor:entity:5:"

# Bad - might match "editor:entity:5" AND "editor:entity:50"
"editor:entity:5"
```

### 2. Store State Unconditionally, Broadcast Conditionally
```elixir
# ALWAYS store (for late joiners)
Presence.store_data(key, payload)

# Only broadcast when needed (reduce PubSub load)
if editor_count > 1 do
  Events.broadcast(...)
end
```

### 3. Use on_mount Hooks for Repeated Subscriptions
```elixir
# Instead of repeating this in every LiveView:
if connected?(socket) do
  Events.subscribe_to_entities()
end

# Create a hook and use it once
on_mount MyAppWeb.Live.Hooks
```

### 4. Always Clean Up in terminate/2
```elixir
@impl true
def terminate(_reason, socket) do
  # Untrack presence
  # Clear state if last editor
  # Unsubscribe if needed (PubSub auto-unsubscribes on process death)
  :ok
end
```

### 5. Handle Resource Deletion in handle_info
```elixir
def handle_info({:resource_deleted, resource_id}, socket) do
  if resource_id == socket.assigns.resource.id do
    {:noreply,
     socket
     |> put_flash(:error, "Resource deleted in another session")
     |> redirect(to: ~p"/admin/resources")}
  else
    {:noreply, socket}
  end
end
```

### 6. Trust State Storage Expiration
```elixir
# State auto-expires after 5 minutes
# Don't worry about stale state - it's handled automatically
# Just follow the patterns above
```

---

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────┐
│  LiveView Page (entity_form.ex)                             │
│                                                              │
│  mount/3:                                                    │
│    - Track editor with Presence.track()                     │
│    - Subscribe to Events                                    │
│    - Load collaborative state if editor_count > 1           │
│                                                              │
│  handle_event("validate"):                                  │
│    - Update changeset                                       │
│    - Store state with Presence.store_data()                 │
│    - Broadcast if editor_count > 1                          │
│                                                              │
│  handle_info (receive broadcasts):                          │
│    - Apply remote changes to local state                    │
│                                                              │
│  terminate/2:                                               │
│    - Untrack editor                                         │
│    - Clear state if last editor                             │
└─────────────────────────────────────────────────────────────┘
                    ↓              ↑
                    ↓              ↑
        ┌───────────────────────────────────┐
        │  SimplePresence (GenServer + ETS)  │
        │                                    │
        │  - track/untrack editors           │
        │  - store/get/clear state           │
        │  - count_tracked                   │
        │  - Auto-expire (5 min)             │
        └───────────────────────────────────┘
                    ↓              ↑
                    ↓              ↑
        ┌───────────────────────────────────┐
        │  Events (PubSub)                   │
        │                                    │
        │  - subscribe_to_*()                │
        │  - broadcast_*()                   │
        └───────────────────────────────────┘
                    ↓              ↑
                    ↓              ↑
        ┌───────────────────────────────────┐
        │  Context (entities.ex)             │
        │                                    │
        │  - create/update/delete            │
        │  - notify_entity_event()           │
        └───────────────────────────────────┘
```

---

## Reference Files

- **Events:** `lib/phoenix_kit/entities/events.ex`
- **Presence:** `lib/phoenix_kit/admin/simple_presence.ex`
- **Hooks:** `lib/phoenix_kit_web/live/modules/entities/hooks.ex`
- **List Example:** `lib/phoenix_kit_web/live/modules/entities/entities.ex`
- **Detail Example:** `lib/phoenix_kit_web/live/modules/entities/data_navigator.ex`
- **Form Example:** `lib/phoenix_kit_web/live/modules/entities/entity_form.ex`
- **Data Form Example:** `lib/phoenix_kit_web/live/modules/entities/data_form.ex`

---

## Next Steps

1. Read the reference files to see real implementations
2. Copy patterns that match your use case
3. Test with multiple browser tabs to verify real-time updates
4. Check the troubleshooting section if issues arise
5. Follow best practices for clean, maintainable code
