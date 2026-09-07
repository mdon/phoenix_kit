# Module-owned tables: extracting them from core

Core's baseline (V135) still creates tables that belong to modules
(`phoenix_kit_shop_*`, `phoenix_kit_cat_*`, `phoenix_kit_entities*`, …).
The protocol for a module to take ownership without a breaking core release
is written once, in the Hello World template module:

* `phoenix_kit_hello_world` README → `## Database conventions` →
  `### Versioned migrations` → `#### Adopting a table core already creates (extraction)`
* template coordinator: `lib/phoenix_kit_hello_world/migrations.ex`
* live examples: `phoenix_kit_legal` (`phoenix_kit_consent_logs`,
  `dev_docs/reports/2026-08-10-consent-logs-extraction.md`),
  `phoenix_kit_billing` (`phoenix_kit_payment_provider_configs`),
  and since 2026-09: `phoenix_kit_catalogue` (`pkc_schema`),
  `phoenix_kit_entities` (`pkn_schema`), `phoenix_kit_ecommerce` (`pke_schema`).

The three phases, in one paragraph each:

**Phase 0 — adopt.** The module ships V1 whose every statement is
`CREATE … IF NOT EXISTS` / guarded `DO $$ … $$`, shape- and name-identical
to core's objects, and stamps a namespaced `COMMENT ON TABLE` marker
(`<ns>_schema:1`) on one designated table. `down/1` only unstamps. Core
keeps creating the same tables; nothing changes for hosts.

**Phase 1 — first shape change.** Before releasing a module V2 that alters
one of these tables: add the changed objects to `@excluded_exact` in
`dev_docs/squash/generate_baseline.exs`, regenerate `ExpectedSchema`, and
raise the module's core version floor — otherwise `mix phoenix_kit.repair`
reverts the change on every run.

**Phase 2 — core stops creating.** Only at core's next baseline squash does
core drop its copy of the DDL. The module's V1 must already be able to
create the tables from scratch. Core never drops module tables
conditionally ("if the module is absent") — uninstall is a documented
manual step in the module README.

Tables that a module has stopped using but that core still creates (for
example `phoenix_kit_shop_products` once the shop reads products from
`phoenix_kit_catalogue`) are marked with a `COMMENT ON TABLE … 'deprecated
<date>: …'` by the host app, never dropped by anyone in this cycle; the
squash of Phase 2 decides their fate.

## Inventory: which core-baseline tables are already module-owned

Each module below is at Phase 0 (adopted, `down/1` only unstamps) or
already past it. Core's baseline still creates every table listed — this
inventory is what a future baseline squash removes from core once all
hosts have adopted the owning module's V1, not something this PR drops or
migrates. Only the module's designated version table carries the
`COMMENT ON TABLE … '<ns>_schema:<N>'` marker; the rest of a module's
tables are recognized by ownership (this list), not by a per-table
comment.

**`phoenix_kit_ecommerce`** — marker `pke_schema:<N>` on
`phoenix_kit_shop_config` (`PhoenixKitEcommerce.Migrations.version_table/0`).
Ten tables, all `phoenix_kit_shop_*`:

* `phoenix_kit_shop_config`
* `phoenix_kit_shop_shipping_methods`
* `phoenix_kit_shop_categories`
* `phoenix_kit_shop_products`
* `phoenix_kit_shop_product_slugs`
* `phoenix_kit_shop_category_slugs`
* `phoenix_kit_shop_carts`
* `phoenix_kit_shop_cart_items`
* `phoenix_kit_shop_import_configs`
* `phoenix_kit_shop_import_logs`

**`phoenix_kit_catalogue`** — marker `pkc_schema:<N>` on
`phoenix_kit_cat_catalogues` (`PhoenixKitCatalogue.Migrations.version_table/0`).
Eighteen tables, all `phoenix_kit_cat_*`:

* `phoenix_kit_cat_catalogues`
* `phoenix_kit_cat_folders`
* `phoenix_kit_cat_categories`
* `phoenix_kit_cat_manufacturers`
* `phoenix_kit_cat_suppliers`
* `phoenix_kit_cat_manufacturer_suppliers`
* `phoenix_kit_cat_items`
* `phoenix_kit_cat_item_catalogue_rules`
* `phoenix_kit_cat_item_supplier_info`
* `phoenix_kit_cat_pdfs`
* `phoenix_kit_cat_pdf_pages`
* `phoenix_kit_cat_pdf_page_contents`
* `phoenix_kit_cat_pdf_extractions`
* `phoenix_kit_cat_attribute_groups`
* `phoenix_kit_cat_attributes`
* `phoenix_kit_cat_attribute_values`
* `phoenix_kit_cat_item_attribute_groups`
* `phoenix_kit_cat_item_attribute_sets`

**`phoenix_kit_entities`** — marker `pkn_schema:<N>` on
`phoenix_kit_entities` itself (`PhoenixKitEntities.Migrations.version_table/0`).
Two tables:

* `phoenix_kit_entities`
* `phoenix_kit_entity_data`

Storage's orphaned-file check and doctor's NULL-uuid check are the two
places that have historically hardcoded a table list next to this kind of
inventory; see their own comments for why each one currently does or does
not need the catalogue tables added — the answer is not the same for both.
