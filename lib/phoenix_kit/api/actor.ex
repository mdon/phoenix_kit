defmodule PhoenixKit.API.Actor do
  @moduledoc """
  Who is calling the API: a key (with its owner and effective scopes) or an anonymous public
  caller.

    * `kind` - `:key` for a verified bearer key, `:anonymous` for a public caller.
    * `key_uuid`, `key_prefix` - the key, when there is one.
    * `user_uuid` - the key's owner.
    * `scopes` - the key's effective scopes (its own, filtered by the owner's live permissions).
    * `requires_approval` - the key's dangerous operations wait for a human.
    * `cart_token_hash` - the hashed cart token of an anonymous public caller.
    * `ip` - the address the request came from, as a string.

  The default is the least-privileged value: anonymous, no scopes, no approval.
  """

  defstruct kind: :anonymous,
            key_uuid: nil,
            key_prefix: nil,
            user_uuid: nil,
            scopes: [],
            requires_approval: false,
            cart_token_hash: nil,
            ip: nil

  @type t :: %__MODULE__{
          kind: :key | :anonymous,
          key_uuid: String.t() | nil,
          key_prefix: String.t() | nil,
          user_uuid: String.t() | nil,
          scopes: [String.t()],
          requires_approval: boolean(),
          cart_token_hash: String.t() | nil,
          ip: String.t() | nil
        }
end
