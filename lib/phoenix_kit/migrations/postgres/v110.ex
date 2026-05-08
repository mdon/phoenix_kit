defmodule PhoenixKit.Migrations.Postgres.V110 do
  @moduledoc """
  V110: Add `language` column to `phoenix_kit_doc_templates`.

  Each Document Creator template represents a single Google Doc, which is
  inherently single-language (translations live in separate templates).
  Storing the locale on the template lets parent apps fill template variables
  in the matching language regardless of the admin's UI locale.

  - `language` (VARCHAR(10), nullable) — full locale code (`"en-US"`,
    `"et-EE"`, `"ja"`, etc.) sourced from `PhoenixKit.Modules.Languages`.
    Nullable so existing rows survive without a backfill; the form
    pre-selects the project's primary language for new templates and
    callers can update the value at any time.

  Documents intentionally do not get a language column — they inherit
  language from `template_uuid → templates.language`.

  All operations are idempotent.
  """

  use Ecto.Migration

  def up(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)
    schema = if prefix == "public", do: "public", else: prefix

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'phoenix_kit_doc_templates'
          AND column_name = 'language'
      ) THEN
        ALTER TABLE #{p}phoenix_kit_doc_templates
          ADD COLUMN language VARCHAR(10);
      END IF;
    END $$;
    """)

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '110'")
  end

  def down(opts) do
    prefix = Map.get(opts, :prefix, "public")
    p = prefix_str(prefix)

    execute("ALTER TABLE #{p}phoenix_kit_doc_templates DROP COLUMN IF EXISTS language")

    execute("COMMENT ON TABLE #{p}phoenix_kit IS '109'")
  end

  defp prefix_str("public"), do: "public."
  defp prefix_str(prefix), do: "#{prefix}."
end
