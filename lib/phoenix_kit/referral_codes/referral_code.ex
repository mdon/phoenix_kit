defmodule PhoenixKit.ReferralCodes.ReferralCode do
  @moduledoc """
  Schema and domain logic for referral codes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "phoenix_kit_referral_codes" do
    field :code, :string
    field :description, :string
    field :status, :boolean, default: true
    field :number_of_uses, :integer, default: 0
    field :max_uses, :integer
    field :created_by, :integer
    field :date_created, :utc_datetime_usec
    field :expiration_date, :utc_datetime_usec

    has_many :usage_records, PhoenixKit.ReferralCodes.ReferralCodeUsage, foreign_key: :code_id
  end

  @doc """
  Changeset for creating/updating referral codes.

  - Ensures required fields and lengths
  - Enforces unique `code`
  - Validates expiration (if present) is in the future
  - Auto-sets `date_created` for new records
  - Defaults `expiration_date` to 1 week from now for new records if not supplied
  """
  def changeset(referral_code, attrs) do
    referral_code
    |> cast(attrs, [
      :code,
      :description,
      :status,
      :number_of_uses,
      :max_uses,
      :created_by,
      :date_created,
      :expiration_date
    ])
    |> validate_required([:code, :description, :max_uses])
    |> validate_length(:code, min: 3, max: 50)
    |> validate_length(:description, min: 1, max: 255)
    |> validate_number(:max_uses, greater_than: 0)
    |> validate_number(:number_of_uses, greater_than_or_equal_to: 0)
    |> unique_constraint(:code)
    |> validate_expiration_date()
    |> maybe_set_date_created()
    |> maybe_set_default_expiration()
  end

  @doc """
  Generates a random 5-character alphanumeric referral code.

  Excludes confusing characters: 0, O, I, 1.
  """
  def generate_random_code do
    chars = ~w(A B C D E F G H J K L M N P Q R S T U V W X Y Z 2 3 4 5 6 7 8 9)
    chars |> Enum.take_random(5) |> Enum.join()
  end

  @doc """
  Returns true if the code is active, not expired, and under its usage limit.
  """
  def valid_for_use?(%__MODULE__{} = code) do
    code.status &&
      code.number_of_uses < code.max_uses &&
      DateTime.compare(DateTime.utc_now(), code.expiration_date) == :lt
  end

  @doc """
  Returns true if the code is expired.
  """
  def expired?(%__MODULE__{} = code) do
    DateTime.compare(DateTime.utc_now(), code.expiration_date) != :lt
  end

  @doc """
  Returns true if the usage limit has been reached.
  """
  def usage_limit_reached?(%__MODULE__{} = code) do
    code.number_of_uses >= code.max_uses
  end

  # --- private helpers ---

  defp validate_expiration_date(changeset) do
    case get_field(changeset, :expiration_date) do
      nil ->
        changeset

      expiration_date ->
        if DateTime.compare(expiration_date, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, :expiration_date, "must be in the future")
        end
    end
  end

  defp maybe_set_date_created(changeset) do
    case get_field(changeset, :id) do
      nil -> put_change(changeset, :date_created, DateTime.utc_now())
      _id -> changeset
    end
  end

  defp maybe_set_default_expiration(changeset) do
    case get_field(changeset, :expiration_date) do
      nil ->
        case get_field(changeset, :id) do
          nil ->
            one_week_from_now = DateTime.utc_now() |> DateTime.add(7, :day)
            put_change(changeset, :expiration_date, one_week_from_now)

          _id ->
            changeset
        end

      _existing_date ->
        changeset
    end
  end
end

defmodule PhoenixKit.ReferralCodes do
  @moduledoc """
  Context for managing the referral code system in PhoenixKit.

  Provides CRUD for codes, usage tracking helpers, and system settings access.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.ReferralCodes.{ReferralCode, ReferralCodeUsage}
  alias PhoenixKit.Settings

  # Central repo accessor (respects your RepoHelper indirection)
  defp repo, do: PhoenixKit.RepoHelper.repo()

  ## --- Code Management ---

  @doc """
  List all referral codes, newest first.
  """
  def list_codes do
    ReferralCode
    |> order_by([r], desc: r.date_created)
    |> repo().all()
  end

  @doc """
  Fetch a referral code by ID (bang).
  """
  def get_code!(id), do: repo().get!(ReferralCode, id)

  @doc """
  Fetch a referral code by its code string. Returns `nil` if not found.
  """
  def get_code_by_string(code_string) when is_binary(code_string) do
    repo().get_by(ReferralCode, code: code_string)
  end

  @doc """
  Create a referral code.
  """
  def create_code(attrs \\ %{}) do
    %ReferralCode{}
    |> ReferralCode.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Update a referral code.
  """
  def update_code(%ReferralCode{} = referral_code, attrs) do
    referral_code
    |> ReferralCode.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Delete a referral code.
  """
  def delete_code(%ReferralCode{} = referral_code) do
    repo().delete(referral_code)
  end

  @doc """
  Return a changeset for a referral code with optional attributes applied.
  """
  def change_code(%ReferralCode{} = referral_code, attrs \\ %{}) do
    ReferralCode.changeset(referral_code, attrs)
  end

  @doc """
  Generate a random referral code string.
  """
  def generate_random_code, do: ReferralCode.generate_random_code()

  ## --- Usage Tracking ---

  @doc """
  Attempt to use a referral code for `user_id`.

  - Validates code status/expiry/limits
  - Inserts usage record
  - Increments code `number_of_uses` atomically in a transaction

  Returns `{:ok, %ReferralCodeUsage{}}` on success, or `{:error, reason}`.
  """
  def use_code(code_string, user_id) when is_binary(code_string) and is_integer(user_id) do
    case get_code_by_string(code_string) do
      nil ->
        {:error, :code_not_found}

      code ->
        if ReferralCode.valid_for_use?(code) do
          repo().transaction(fn ->
            usage_result =
              %ReferralCodeUsage{}
              |> ReferralCodeUsage.changeset(%{code_id: code.id, used_by: user_id})
              |> repo().insert()

            case usage_result do
              {:ok, usage} ->
                {:ok, _updated_code} =
                  update_code(code, %{number_of_uses: code.number_of_uses + 1})

                usage

              {:error, changeset} ->
                repo().rollback(changeset)
            end
          end)
        else
          cond do
            ReferralCode.expired?(code) -> {:error, :code_expired}
            ReferralCode.usage_limit_reached?(code) -> {:error, :usage_limit_reached}
            !code.status -> {:error, :code_inactive}
            true -> {:error, :code_invalid}
          end
        end
    end
  end

  @doc """
  Return usage stats for a given code ID (delegates to `ReferralCodeUsage`).
  """
  def get_usage_stats(code_id) when is_integer(code_id) do
    ReferralCodeUsage.get_usage_stats(code_id)
  end

  @doc """
  List usage records for a given code ID.
  """
  def list_usage_for_code(code_id) when is_integer(code_id) do
    ReferralCodeUsage.for_code(code_id)
    |> repo().all()
  end

  @doc """
  Check if a user already used a specific code.
  """
  def user_used_code?(user_id, code_id) when is_integer(user_id) and is_integer(code_id) do
    ReferralCodeUsage.user_used_code?(user_id, code_id)
  end

  ## --- System Settings ---

  @doc """
  Is the referral code system enabled?
  """
  def enabled? do
    Settings.get_boolean_setting("referral_codes_enabled", false)
  end

  @doc """
  Are referral codes required on registration?
  """
  def required? do
    Settings.get_boolean_setting("referral_codes_required", false)
  end

  @doc """
  Enable the referral code system.
  """
  def enable_system do
    Settings.update_boolean_setting_with_module(
      "referral_codes_enabled",
      true,
      "referral_codes"
    )
  end

  @doc """
  Disable the referral code system.
  """
  def disable_system do
    Settings.update_boolean_setting_with_module(
      "referral_codes_enabled",
      false,
      "referral_codes"
    )
  end

  @doc """
  Set whether referral codes are required.
  """
  def set_required(required) when is_boolean(required) do
    Settings.update_boolean_setting_with_module(
      "referral_codes_required",
      required,
      "referral_codes"
    )
  end

  @doc """
  Fetch current referral code configuration.
  """
  def get_config do
    %{
      enabled: enabled?(),
      required: required?()
    }
  end

  @doc """
  List codes that are currently valid for use.
  """
  def list_valid_codes do
    now = DateTime.utc_now()

    from(r in ReferralCode,
      where: r.status == true,
      where: r.expiration_date > ^now,
      where: r.number_of_uses < r.max_uses,
      order_by: [desc: r.date_created]
    )
    |> repo().all()
  end

  @doc """
  Summary statistics for admin dashboards.
  """
  def get_system_stats do
    codes_query = from(r in ReferralCode)
    usage_query = from(u in ReferralCodeUsage)

    total_codes = repo().aggregate(codes_query, :count)
    active_codes = repo().aggregate(from(r in codes_query, where: r.status == true), :count)
    total_usage = repo().aggregate(usage_query, :count)

    codes_with_usage =
      repo().aggregate(from(r in codes_query, where: r.number_of_uses > 0), :count)

    %{
      total_codes: total_codes,
      active_codes: active_codes,
      total_usage: total_usage,
      codes_with_usage: codes_with_usage
    }
  end
end
