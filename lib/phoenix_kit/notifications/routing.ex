defmodule PhoenixKit.Notifications.Routing do
  @moduledoc """
  Decides which external delivery channels a user's notification should go out
  on (the in-app inbox is handled separately, by the creation choke point).

  **External routing is FAIL-CLOSED.** Unlike the fail-open in-app inbox, an
  action that doesn't resolve to a known notification type, or a type the user
  hasn't explicitly opted a channel into, is NOT delivered externally. A channel
  is a target only when, for that specific type, the user has it `enabled`, has
  opted the type in (`types[type_key] == true`), and the channel reports
  `configured?/2`.
  """

  alias PhoenixKit.Notifications.ChannelConfig
  alias PhoenixKit.Notifications.Channels
  alias PhoenixKit.Notifications.Types

  @typedoc "A resolved delivery target: the channel module + the user's config for it."
  @type target :: {module(), map()}

  @doc """
  Delivery targets for an activity `action` string. Resolves the action to its
  notification type, then delegates to `targets_for_type/2`. Unknown/unmapped
  action ⇒ `[]` (fail-closed — standalone/untyped notifications never route out).
  """
  @spec targets_for_action(map(), String.t() | nil) :: [target()]
  def targets_for_action(user, action) when is_binary(action) do
    case Types.key_for_action(action) do
      nil -> []
      type_key -> targets_for_type(user, type_key)
    end
  end

  def targets_for_action(_user, _action), do: []

  @doc """
  Delivery targets for an explicit type key. `nil`/non-binary ⇒ `[]`.
  """
  @spec targets_for_type(map(), String.t() | nil) :: [target()]
  def targets_for_type(user, type_key) when is_binary(type_key) do
    configs = ChannelConfig.all_for(user)

    for channel <- Channels.list(),
        config = Map.get(configs, channel.key(), %{}),
        ChannelConfig.enabled?(config),
        ChannelConfig.type_enabled?(config, type_key),
        channel.configured?(user_uuid(user), config) do
      {channel, config}
    end
  end

  def targets_for_type(_user, _type_key), do: []

  @doc """
  Whether ANY external channel wants this action — the cheap check the creation
  choke point uses to decide whether to enqueue delivery even when the in-app
  inbox is muted for the type (Model B: independent destinations).
  """
  @spec any_target?(map(), String.t() | nil) :: boolean()
  def any_target?(user, action), do: targets_for_action(user, action) != []

  defp user_uuid(%{uuid: uuid}), do: uuid
  defp user_uuid(_), do: nil
end
