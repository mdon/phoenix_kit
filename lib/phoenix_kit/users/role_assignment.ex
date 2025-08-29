defmodule PhoenixKit.Users.RoleAssignment do
  @moduledoc """
  Role assignment schema for PhoenixKit authorization system.

  This schema represents the many-to-many relationship between users and roles,
  with additional metadata about when and by whom the role was assigned.

  ## Fields

  - `user_id`: Reference to the user who has the role
  - `role_id`: Reference to the role being assigned
  - `assigned_by`: Reference to the user who assigned this role (can be nil for system assignments)
  - `assigned_at`: Timestamp when the role was assigned
  - `is_active`: Whether this role assignment is currently active

  ## Features

  - Tracks role assignment history
  - Supports bulk role management
  - Audit trail for security purposes
  - Soft deactivation instead of deletion
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer(),
          role_id: integer(),
          assigned_by: integer() | nil,
          assigned_at: NaiveDateTime.t(),
          is_active: boolean(),
          inserted_at: NaiveDateTime.t()
        }

  schema "phoenix_kit_user_role_assignments" do
    belongs_to :user, PhoenixKit.Users.Auth.User
    belongs_to :role, PhoenixKit.Users.Role
    belongs_to :assigned_by_user, PhoenixKit.Users.Auth.User, foreign_key: :assigned_by

    field :assigned_at, :naive_datetime
    field :is_active, :boolean, default: true

    timestamps(updated_at: false)
  end

  @doc """
  A role assignment changeset for creating role assignments.

  ## Parameters

  - `role_assignment`: The role assignment struct to modify
  - `attrs`: Attributes to update

  ## Examples

      iex> changeset(%RoleAssignment{}, %{user_id: 1, role_id: 2})
      %Ecto.Changeset{valid?: true}

      iex> changeset(%RoleAssignment{}, %{})
      %Ecto.Changeset{valid?: false}
  """
  def changeset(role_assignment, attrs) do
    role_assignment
    |> cast(attrs, [:user_id, :role_id, :assigned_by, :assigned_at, :is_active])
    |> validate_required([:user_id, :role_id])
    |> put_assigned_at()
    |> unique_constraint([:user_id, :role_id],
      name: :phoenix_kit_user_role_assignments_user_id_role_id_index,
      message: "user already has this role"
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:role_id)
    |> foreign_key_constraint(:assigned_by)
  end

  @doc """
  A role assignment changeset for updating active status.

  ## Parameters

  - `role_assignment`: The role assignment struct to modify
  - `attrs`: Attributes to update (typically just is_active)

  ## Examples

      iex> update_changeset(%RoleAssignment{}, %{is_active: false})
      %Ecto.Changeset{valid?: true}
  """
  def update_changeset(role_assignment, attrs) do
    role_assignment
    |> cast(attrs, [:is_active])
    |> validate_inclusion(:is_active, [true, false])
  end

  # Set assigned_at to current time if not provided
  defp put_assigned_at(changeset) do
    case get_field(changeset, :assigned_at) do
      nil ->
        put_change(
          changeset,
          :assigned_at,
          NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        )

      _ ->
        changeset
    end
  end
end
