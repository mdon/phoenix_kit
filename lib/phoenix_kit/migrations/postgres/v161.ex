defmodule PhoenixKit.Migrations.Postgres.V161 do
  @moduledoc """
  V161: First-class payment-option linkage on billing orders.

  An order records HOW it is to be paid via `payment_method`, a small closed
  vocabulary (`bank`, `stripe`, `paypal`, …). What the customer actually
  chose at checkout is a `phoenix_kit_payment_options` row — an
  operator-configured method with its own name, instructions, provider and
  billing-profile requirement. The two are not the same thing: several
  options can share one `payment_method` ("Bank transfer (EU)" and "Bank
  transfer (UK)" are both `bank`), and an option can be renamed or
  deactivated after the order is placed.

  Without a link, the choice was simply lost at conversion: nothing on the
  order said which option the customer picked, so an operator processing a
  bank transfer could not tell which instructions the customer had been
  shown, and payment reconciliation had to guess.

  `ON DELETE SET NULL` rather than restrict: deactivating and deleting a
  payment option is an ordinary operator action, and it must not be blocked
  by — or destroy — historical orders. The order keeps `payment_method` and
  its metadata snapshot regardless, so a deleted option degrades to "we know
  it was a bank transfer" rather than to nothing.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    alter table(:phoenix_kit_orders, prefix: prefix) do
      add_if_not_exists(
        :payment_option_uuid,
        references(:phoenix_kit_payment_options,
          column: :uuid,
          type: :uuid,
          prefix: prefix,
          on_delete: :nilify_all
        )
      )
    end

    # FK columns get an index: the payment-options admin needs "orders using
    # this option" and, without it, that is a sequential scan of every order.
    create_if_not_exists(
      index(:phoenix_kit_orders, [:payment_option_uuid], prefix: prefix)
    )

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '161'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    drop_if_exists(index(:phoenix_kit_orders, [:payment_option_uuid], prefix: prefix))

    alter table(:phoenix_kit_orders, prefix: prefix) do
      remove_if_exists(:payment_option_uuid)
    end

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '160'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
