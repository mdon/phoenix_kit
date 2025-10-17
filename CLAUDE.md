# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## MCP Memory Knowledge Base

⚠️ **IMPORTANT**: Always start working with the project by studying data in the MCP memory storage. Use the command:

```
mcp__memory__read_graph
```

This will help understand the current state of the project, implemented and planned components, architectural decisions.

Update data in memory when discovering new components or changes in project architecture. Use:

- `mcp__memory__create_entities` - for adding new modules/components
- `mcp__memory__create_relations` - for relationships between components
- `mcp__memory__add_observations` - for supplementing information about existing components

## Project Overview

This is **PhoenixKit** - PhoenixKit is a starter kit for building modern web applications with Elixir and Phoenix with PostgreSQL support and streamlined setup. As a start it provides a complete authentication system that can be integrated into any Phoenix application without circular dependencies.

**Key Characteristics:**

- Library-first architecture (no OTP application)
- Streamlined setup with automatic repository detection
- Complete authentication system with Magic Links
- Role-based access control (Owner/Admin/User)
- Built-in admin dashboard and user management
- Modern theme system with daisyUI 5 and 35+ themes support
- Professional versioned migration system
- Layout integration with parent applications
- Ready for production use

## Development Commands

### Setup and Dependencies

- `mix setup` - Complete project setup (installs deps, sets up database)
- `mix deps.get` - Install Elixir dependencies only

### Database Operations

- `mix ecto.create` - Create the database
- `mix ecto.migrate` - Run database migrations
- `mix ecto.reset` - Drop and recreate database with fresh data
- `mix ecto.setup` - Create database, run migrations, and seed data

### PhoenixKit Installation System

- `mix phoenix_kit.install` - Install PhoenixKit using igniter (for new projects)
- `mix phoenix_kit.install --help` - Show detailed installation help and options
- `mix phoenix_kit.update` - Update existing PhoenixKit installation to latest version
- `mix phoenix_kit.update --help` - Show detailed update help and options
- `mix phoenix_kit.update --status` - Check current version and available updates
- `mix phoenix_kit.gen.migration` - Generate custom migration files

**Key Features:**
- **Professional versioned migrations** - Oban-style migration system with version tracking
- **Prefix support** - Isolate PhoenixKit tables using PostgreSQL schemas
- **Idempotent operations** - Safe to run migrations multiple times
- **Multi-version upgrades** - Automatically handles upgrades across multiple versions
- **PostgreSQL Validation** - Automatic database adapter detection with warnings for non-PostgreSQL setups
- **Production Mailer Templates** - Auto-generated configuration examples for SMTP, SendGrid, Mailgun, Amazon SES
- **Interactive Migration Runner** - Optional automatic migration execution with smart CI detection
- **Built-in Help System** - Comprehensive help documentation accessible via `--help` flag

**Installation Help:**
```bash
# Show detailed installation options and examples
mix phoenix_kit.install --help

# Quick examples from help:
mix phoenix_kit.install                                    # Basic installation with auto-detection
mix phoenix_kit.install --repo MyApp.Repo                 # Specify repository
mix phoenix_kit.install --prefix auth                     # Custom schema prefix
mix phoenix_kit.install --theme-enabled                   # Enable daisyUI 5 theme system
```

**Update Help:**
```bash
# Show detailed update options and examples
mix phoenix_kit.update --help

# Quick examples from help:
mix phoenix_kit.update                                    # Update to latest version
mix phoenix_kit.update --status                           # Check current version
mix phoenix_kit.update --prefix auth                      # Update with custom prefix
mix phoenix_kit.update -y                                 # Skip confirmation prompts (CI/CD)
mix phoenix_kit.update --force -y                         # Force update with auto-migration
```

### Testing & Code Quality

- `mix test` - Run all tests (52 tests, no database required)
- `mix format` - Format code according to .formatter.exs
- `mix credo --strict` - Static code analysis
- `mix dialyzer` - Type checking (requires PLT setup)
- `mix quality` - Run all quality checks (format, credo, dialyzer, test)

⚠️ Ecto warnings are normal for library - tests focus on API validation

### ⚠️ IMPORTANT: Pre-commit Checklist

**ALWAYS run before git commit:**

```bash
mix format
git add -A  # Add formatted files
git commit -m "your message"
```

This ensures consistent code formatting across the project.

### 📝 Commit Message Rules

**ALWAYS start commit messages with action verbs:**

- `Add` - for new features, files, or functionality
- `Update` - for modifications to existing code or features
- `Merge` - for merge commits or combining changes
- `Fix` - for bug fixes
- `Remove` - for deletions

**Important commit message restrictions:**

- ❌ **NEVER mention Claude or AI assistance** in commit messages
- ❌ Avoid phrases like "Generated with Claude", "AI-assisted", etc.
- ✅ Focus on **what** was changed and **why**

**Examples:**

- ✅ `Add role system for user authorization management`
- ✅ `Update rollback logic to handle single version migrations`
- ✅ `Fix merge conflict markers in installation file`
- ❌ `Enhanced migration system` (no action verb)
- ❌ `migration fixes` (not descriptive enough)
- ❌ `Add new feature with Claude assistance` (mentions AI)

### 🏷️ Version Management Protocol

**Current Version**: 1.2.15 (in mix.exs)
**Version Strategy**: Semantic versioning (MAJOR.MINOR.PATCH)
**Migration Version**: V17 (latest migration version with entities system and plural display names)

**MANDATORY steps for version updates:**

#### 1. Version Update Requirements

```bash
# Current version locations to update:
# - mix.exs (@version constant)
# - CHANGELOG.md (new version entry)
# - README.md (if version mentioned in examples)
```

#### 2. Version Number Schema

- **MAJOR**: Breaking changes, backward incompatibility
- **MINOR**: New features, backward compatible
- **PATCH**: Bug fixes, backward compatible

#### 3. Update Process Checklist

**Step 1: Update mix.exs**
```elixir
@version "1.0.1"  # Increment from current version
```

**Step 2: Update CHANGELOG.md**
```markdown
## [1.0.1] - 2025-08-20

### Added
- Description of new features

### Changed  
- Description of modifications

### Fixed
- Description of bug fixes

### Removed
- Description of deletions
```

**Step 3: Commit Version Changes**
```bash
git add mix.exs CHANGELOG.md README.md
git commit -m "Update version to 1.0.1 with comprehensive changelog"
```

#### 4. Version Validation

**Before committing version changes:**
- ✅ Mix compiles without errors: `mix compile`
- ✅ Tests pass: `mix test`
- ✅ Code formatted: `mix format`
- ✅ CHANGELOG.md includes current date
- ✅ Version number incremented correctly

**⚠️ Critical Notes:**
- **NEVER ship without updating CHANGELOG.md**
- **ALWAYS validate version number increments**  
- **NEVER reference old version in new documentation**

### Publishing

- `mix hex.build` - Build package for Hex.pm
- `mix hex.publish` - Publish to Hex.pm (requires auth)
- `mix docs` - Generate documentation with ExDoc

## Code Style Guidelines

### Template Comments

**ALWAYS use EEx comments in Phoenix templates and components:**

```heex
<%!-- EEx comments (CORRECT) --%>
<div class="container">
  <%!-- This is the preferred way to comment in .heex templates --%>
  <h1>My App</h1>
</div>

<!-- HTML comments (AVOID) -->
<div class="container">
  <!-- This should be avoided in Phoenix templates -->
  <h1>My App</h1>
</div>
```

**Why EEx comments are preferred:**

- ✅ **Server-side processing** - EEx comments (`<%!-- --%>`) are processed server-side and never sent to the client
- ✅ **Performance** - Reduces HTML payload size since comments don't appear in browser
- ✅ **Security** - Internal comments and notes remain private on the server
- ✅ **Consistency** - Matches Phoenix LiveView and EEx template conventions

**When to use:**

- ✅ All `.heex` template files
- ✅ LiveView components
- ✅ Phoenix templates and layouts
- ✅ Documentation and section dividers in templates
- ✅ Temporary code comments during development

**Template Comment Examples:**

```heex
<%!-- Header Section --%>
<header class="w-full relative mb-6">
  <%!-- Back Button (Left aligned) --%>
  <.link navigate="/dashboard" class="btn btn-outline">
    Back to Dashboard
  </.link>

  <%!-- Title Section --%>
  <div class="text-center">
    <h1>Page Title</h1>
  </div>
</header>

<%!-- Main Content Area --%>
<main class="container mx-auto">
  <%!-- TODO: Add pagination controls --%>
  <div class="content">
    <!-- This HTML comment will appear in browser source -->
    <%!-- This EEx comment stays on the server --%>
  </div>
</main>
```

**Code Comments in Elixir Files:**

For regular Elixir code (`.ex` files), continue using standard Elixir comments:

```elixir
# Standard Elixir comment for code documentation
def my_function do
  # Inline comment explaining logic
  :ok
end
```

### Helper Functions: Use Components, Not Private Functions

**CRITICAL RULE**: Never create private helper functions (`defp`) that are called directly from HEEX templates.

**❌ WRONG - Compiler Cannot See Usage:**

```elixir
# lib/my_app_web/live/users_live.ex
defmodule MyAppWeb.UsersLive do
  use MyAppWeb, :live_view

  # ❌ BAD: Compiler shows "function format_date/1 is unused"
  defp format_date(date) do
    Calendar.strftime(date, "%B %d, %Y")
  end
end
```

```heex
<!-- lib/my_app_web/live/users_live.html.heex -->
{format_date(user.created_at)}  <%!-- ❌ Compiler doesn't see this call --%>
```

**✅ CORRECT - Use Phoenix Components:**

```elixir
# lib/phoenix_kit_web/components/core/time_display.ex
defmodule PhoenixKitWeb.Components.Core.TimeDisplay do
  use Phoenix.Component

  @doc """
  Displays formatted date.

  ## Examples
      <.formatted_date date={user.created_at} />
  """
  attr :date, :any, required: true
  attr :format, :string, default: "%B %d, %Y"

  def formatted_date(assigns) do
    ~H"""
    <span>{Calendar.strftime(@date, @format)}</span>
    """
  end

  # ✅ GOOD: Private helper INSIDE component
  defp format_time(time), do: ...
end
```

```heex
<!-- lib/my_app_web/live/users_live.html.heex -->
<.formatted_date date={user.created_at} />  <%!-- ✅ Compiler sees component usage --%>
```

**Why This Matters:**

1. **Compiler Visibility**: Component calls (`<.component />`) are visible to Elixir compiler, function calls in templates are not
2. **Type Safety**: Components use `attr` macros for compile-time validation
3. **Reusability**: Components work across all LiveView modules without duplication
4. **Documentation**: Components have structured `@doc` with examples
5. **No Warnings**: Prevents false-positive "unused function" warnings

**Where to Put Components:**

- **New helper component**: `lib/phoenix_kit_web/components/core/[category].ex`
- **Import in**: `lib/phoenix_kit_web.ex` → `core_components()` function
- **Available everywhere**: Automatically imported in all LiveViews

**Existing Core Component Categories:**

- `badge.ex` - Role badges, status badges, code status badges
- `time_display.ex` - Relative time, expiration dates, age badges
- `user_info.ex` - User roles, user counts, user statistics
- `button.ex`, `input.ex`, `select.ex`, etc. - Form components

**Adding New Component Category:**

1. Create file: `lib/phoenix_kit_web/components/core/my_category.ex`
2. Add import: `lib/phoenix_kit_web.ex` → `import PhoenixKitWeb.Components.Core.MyCategory`
3. Use in templates: `<.my_component attr={value} />`

**Example: Adding New Helper Component:**

```elixir
# 1. Create component file
# lib/phoenix_kit_web/components/core/currency.ex
defmodule PhoenixKitWeb.Components.Core.Currency do
  use Phoenix.Component

  attr :amount, :integer, required: true
  attr :currency, :string, default: "USD"

  def price(assigns) do
    ~H"""
    <span class="font-semibold">{format_price(@amount, @currency)}</span>
    """
  end

  defp format_price(amount, "USD"), do: "$#{amount / 100}"
  defp format_price(amount, "EUR"), do: "€#{amount / 100}"
end

# 2. Add import to lib/phoenix_kit_web.ex
def core_components do
  quote do
    # ... existing imports ...
    import PhoenixKitWeb.Components.Core.Currency  # ← Add this
  end
end

# 3. Use in any LiveView template
# <.price amount={product.price_cents} currency="USD" />
```

**Component Best Practices:**

1. **One category per file**: Group related helpers (time, currency, badges, etc.)
2. **Document everything**: Use `@doc`, `attr`, examples
3. **Private helpers OK**: Use `defp` INSIDE components for internal logic
4. **Validation**: Use `attr` with `:required`, `:default`, `:values`
5. **Naming**: Use clear, semantic names (`<.time_ago />` not `<.format_t />`)

**Migration Pattern:**

```elixir
# BEFORE (helper function)
defp format_time_ago(datetime) do
  # logic...
end

# Template: {format_time_ago(session.connected_at)}

# AFTER (component)
# Move to lib/phoenix_kit_web/components/core/time_display.ex
attr :datetime, :any, required: true
def time_ago(assigns) do
  ~H"""
  <span>{format_time_ago(@datetime)}</span>
  """
end
defp format_time_ago(datetime), do: # logic...

# Template: <.time_ago datetime={session.connected_at} />
```

## Architecture

### Authentication Structure

- **PhoenixKit.Users.Auth** - Main authentication context with public interface
- **PhoenixKit.Users.Auth.User** - User schema with validations, authentication, and role helpers
- **PhoenixKit.Users.Auth.UserToken** - Token management for email confirmation and password reset
- **PhoenixKit.Users.MagicLink** - Magic link authentication system
- **PhoenixKit.Users.Auth.Scope** - Authentication scope management with role integration

### Role System Architecture

- **PhoenixKit.Users.Role** - Role schema with system role protection
- **PhoenixKit.Users.RoleAssignment** - Many-to-many role assignments with audit trail
- **PhoenixKit.Users.Roles** - Role management API and business logic
- **PhoenixKitWeb.Live.Dashboard** - Admin dashboard with system statistics
- **PhoenixKitWeb.Live.Users** - User management interface with role controls
- **PhoenixKit.Users.Auth.register_user/1** - User registration with integrated role assignment

**Key Features:**
- **Three System Roles** - Owner, Admin, User with automatic assignment
- **Elixir Logic** - First user automatically becomes Owner
- **Admin Dashboard** - Built-in dashboard at `{prefix}/admin/dashboard` for system statistics
- **User Management** - Complete user management interface at `{prefix}/admin/users`
- **Role API** - Comprehensive role management with `PhoenixKit.Users.Roles`
- **Security Features** - Owner protection, audit trail, self-modification prevention
- **Scope Integration** - Role checks via `PhoenixKit.Users.Auth.Scope`

### Settings System Architecture

- **PhoenixKit.Settings** - Settings context for system-wide configuration management
- **PhoenixKit.Settings.Setting** - Settings schema with key/value storage and timestamps
- **PhoenixKitWeb.Live.Settings** - Settings management interface at `{prefix}/admin/settings`

**Core Settings:**
- **time_zone** - System timezone offset (UTC-12 to UTC+12)
- **date_format** - Date display format (Y-m-d, m/d/Y, d/m/Y, d.m.Y, d-m-Y, F j, Y)
- **time_format** - Time display format (H:i for 24-hour, h:i A for 12-hour)

**Email Settings:**
- **email_enabled** - Enable/disable email system (default: false)
- **email_save_body** - Save full email content vs preview only (default: false)
- **email_ses_events** - Enable AWS SES event processing (default: false)
- **email_retention_days** - Data retention period (default: 90 days)
- **email_sampling_rate** - Percentage of emails to fully track (default: 100%)

**Key Features:**
- **Database Storage** - Settings persisted in phoenix_kit_settings table
- **Admin Interface** - Complete settings management at `{prefix}/admin/settings`
- **Default Values** - Fallback defaults for all settings (UTC+0, Y-m-d, H:i)
- **Validation** - Form validation with real-time preview examples
- **Integration** - Automatic integration with date formatting utilities
- **Email System UI** - Dedicated section for email system configuration

### Date Formatting Architecture

- **PhoenixKit.Utils.Date** - Date and time formatting utilities using Timex
- **Settings Integration** - Automatic user preference loading from Settings system
- **Template Integration** - Direct usage in LiveView templates with UtilsDate alias

**Core Functions:**
- **format_date/2** - Format dates with PHP-style format codes
- **format_time/2** - Format times with PHP-style format codes
- **format_datetime/2** - Format datetime values with date formats
- **format_datetime_with_user_format/1** - Auto-load user's date_format setting
- **format_date_with_user_format/1** - Auto-load user's date_format setting
- **format_time_with_user_format/1** - Auto-load user's time_format setting

**Supported Formats:**
- **Date Formats** - Y-m-d (ISO), m/d/Y (US), d/m/Y (European), d.m.Y (German), d-m-Y, F j, Y (Long)
- **Time Formats** - H:i (24-hour), h:i A (12-hour with AM/PM)
- **Examples** - Dynamic format preview with current date/time examples
- **Timex Integration** - Robust internationalized formatting with extensive format support

**Template Usage:**
```heex
<!-- Settings-aware formatting (recommended) -->
{UtilsDate.format_datetime_with_user_format(user.inserted_at)}
{UtilsDate.format_date_with_user_format(user.confirmed_at)}
{UtilsDate.format_time_with_user_format(Time.utc_now())}

<!-- Manual formatting -->
{UtilsDate.format_date(Date.utc_today(), "F j, Y")}
{UtilsDate.format_time(Time.utc_now(), "h:i A")}
```

### Emails Architecture

- **PhoenixKit.Emails** - Main API module for email functionality
- **PhoenixKit.Emails.EmailLog** - Core email logging schema with analytics
- **PhoenixKit.Emails.EmailEvent** - Event management (delivery, bounce, click, open)
- **PhoenixKit.Emails.EmailInterceptor** - Swoosh integration for automatic logging
- **PhoenixKit.Emails.SQSWorker** - AWS SQS polling for real-time events
- **PhoenixKit.Emails.SQSProcessor** - Message parsing and event handling
- **PhoenixKit.Emails.RateLimiter** - Anti-spam and rate limiting
- **PhoenixKit.Emails.Archiver** - Data lifecycle and S3 archival
- **PhoenixKit.Emails.Metrics** - Local database analytics and dashboard data

**Core Features:**
- **Comprehensive Logging** - All outgoing emails logged with metadata
- **Event Management** - Real-time delivery, bounce, complaint, open, click events
- **AWS SES Integration** - Deep integration with SES webhooks for event tracking
- **Analytics Dashboard** - Engagement metrics, campaign analysis, geographic data
- **Rate Limiting** - Multi-layer protection against abuse and spam patterns
- **Data Lifecycle** - Automatic archival, compression, and cleanup
- **Settings Integration** - Configurable via admin settings interface

**Database Tables:**
- **phoenix_kit_email_logs** - Main email logging with extended metadata
- **phoenix_kit_email_events** - Event management (delivery, engagement)
- **phoenix_kit_email_blocklist** - Blocked addresses for rate limiting
- **phoenix_kit_email_templates** - Email template storage and management

**LiveView Interfaces:**
- **Emails** - Email log browsing and management at `{prefix}/admin/emails`
- **Details** - Individual email details at `{prefix}/admin/emails/email/:id`
- **Metrics** - Analytics dashboard at `{prefix}/admin/emails/dashboard`
- **Queue** - Queue management at `{prefix}/admin/emails/queue`
- **Blocklist** - Blocklist management at `{prefix}/admin/emails/blocklist`
- **Templates** - Email templates management at `{prefix}/admin/emails/templates`
- **Template Editor** - Template creation/editing at `{prefix}/admin/emails/templates/new` and `{prefix}/admin/emails/templates/:id/edit`
- **Settings** - Email system configuration at `{prefix}/admin/settings/emails`

**Mailer Integration:**
```elixir
# PhoenixKit.Mailer automatically intercepts emails
email = new()
  |> to("user@example.com")
  |> from("app@example.com")
  |> subject("Welcome!")
  |> html_body("<h1>Welcome!</h1>")

# Emails are automatically logged when sent
PhoenixKit.Mailer.deliver_email(email,
  user_id: user.id,
  template_name: "welcome",
  campaign_id: "onboarding"
)
```

**AWS SES Configuration:**
 Setup configure AWS infrastructure

 Creates:
 - SES configuration set with event publishing
 - SNS topic for SES events
 - SQS queue with proper permissions
 - IAM policies and roles
 - Saves configuration to PhoenixKit settings

**Key Settings:**
- **email_enabled** - Master toggle for the entire system
- **email_save_body** - Store full email content (increases storage)
- **email_ses_events** - Enable AWS SES event processing
- **email_retention_days** - Data retention period (30-365 days)
- **email_sampling_rate** - Percentage of emails to fully log

**Security Features:**
- **Sampling Rate** - Reduce storage load by logging percentage of emails
- **Rate Limiting** - Per-recipient, per-sender, and global limits
- **Automatic Blocklist** - Dynamic blocking of suspicious patterns
- **Data Compression** - Automatic compression of old email bodies
- **S3 Archival** - Long-term storage with automatic cleanup

**Analytics Capabilities:**
- **Engagement Metrics** - Open rates, click rates, bounce rates
- **Campaign Analysis** - Performance by template and campaign
- **Geographic Data** - Engagement by country and region
- **Provider Performance** - Deliverability by email provider
- **Real-time Dashboards** - Live statistics and trending data

**Production Deployment:**

Email system configuration is managed via **Settings Database** (Web UI) or **Environment Variables**.

**Recommended Approach** (Settings DB via Web UI):
1. Navigate to: `{prefix}/admin/settings/emails`
2. Enable email system (`email_enabled = true`)
3. Configure AWS SES settings (region, configuration set)
4. Set retention (`email_retention_days = 90`)
5. Set sampling rate (`email_sampling_rate = 100`)
6. Configure body saving (`email_save_body = false` recommended for efficiency)

**Alternative Approach** (Environment Variables for credentials):
```bash
# In production environment, set:
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="eu-north-1"  # Optional, can be set via Settings DB
```

**Alternative Approach** (CLI via mix task):
```bash
# Configure AWS SES settings
mix phoenix_kit.configure_aws_ses --config-set "my-app-tracking"
mix phoenix_kit.configure_aws_ses --region "eu-north-1"
mix phoenix_kit.configure_aws_ses --status  # Check current config
```

**⚠️ DO NOT configure email settings in config/config.exs!**
Email system settings are runtime-configurable via Settings Database.
Use `config/config.exs` ONLY for basic PhoenixKit integration (repo, mailer module).

### Migration Architecture

- **PhoenixKit.Migrations.Postgres** - PostgreSQL-specific migrator with Oban-style versioning
- **PhoenixKit.Migrations.Postgres.V01** - Version 1: Basic authentication tables with role system
- **Mix.Tasks.PhoenixKit.Install** - Igniter-based installation for new projects
- **Mix.Tasks.PhoenixKit.Update** - Versioned updates for existing installations
- **Mix.Tasks.PhoenixKit.Gen.Migration** - Custom migration generator
- **Mix.Tasks.PhoenixKit.MigrateToDaisyui5** - Migration tool for daisyUI 5 upgrade

### Key Design Principles

- **No Circular Dependencies** - Optional Phoenix deps prevent import cycles
- **Library-First Architecture** - No OTP application, no supervision tree, can be used as dependency
  - No `Application.start/2` callback
  - No Telemetry supervisor (uses `Plug.Telemetry` in endpoint)
  - No dev-only routes (PageController removed)
  - Parent apps provide their own home pages and layouts
- **Professional Testing** - DataCase pattern with database sandbox
- **Production Ready** - Complete authentication system with security best practices
- **Clean Codebase** - Removed standard Phoenix template boilerplate (telemetry.ex, page controllers, API pipeline)

### Database Integration

- **PostgreSQL** - Primary database with Ecto integration
- **Repository Pattern** - Auto-detection or explicit configuration
- **Migration Support** - V01 migration with authentication, role, and settings tables
- **Role System Tables** - phoenix_kit_user_roles, phoenix_kit_user_role_assignments
- **Settings Table** - phoenix_kit_settings with key/value/timestamp storage
- **Race Condition Protection** - FOR UPDATE locking in Ecto transactions
- **Test Database** - Separate test database with sandbox

### Professional Features

- **Hex Publishing** - Complete package.exs configuration
- **Documentation** - ExDoc ready with comprehensive docs
- **Quality Tools** - Credo, Dialyzer, code formatting configured
- **Testing Framework** - Complete test suite with fixtures

## PhoenixKit Integration

### Setup Steps

1. **Install PhoenixKit**: Run `mix phoenix_kit.install --repo YourApp.Repo`
2. **Run Migrations**: Database tables created automatically (V16 includes OAuth providers and magic link registration)
3. **Add Routes**: Use `phoenix_kit_routes()` macro in your router
4. **Configure Mailer**: PhoenixKit auto-detects and uses your app's mailer, or set up email delivery in `config/config.exs`
5. **Configure Layout** (Optional): Set custom layouts in `config/config.exs`
6. **Theme Support** (Optional): Enable with `--theme-enabled` flag during installation
7. **Settings Management**: Access admin settings at `{prefix}/admin/settings`
8. **Email System** (Optional): Enable email system and AWS SES integration

> **Note**: `{prefix}` represents your configured PhoenixKit URL prefix (default: `/phoenix_kit`).
> This can be customized via `config :phoenix_kit, url_prefix: "/your_custom_prefix"`.

### Integration Pattern

```elixir
# In your Phoenix app's config/config.exs
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer  # Optional: Use your app's mailer (auto-detected by installer)

# Configure your app's mailer (PhoenixKit will use it automatically if mailer is set)
config :my_app, MyApp.Mailer, adapter: Swoosh.Adapters.Local

# Alternative: Configure PhoenixKit's built-in mailer (legacy approach)
# config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Local

# Configure Layout Integration (optional - defaults to PhoenixKit layouts)
config :phoenix_kit,
  layout: {MyAppWeb.Layouts, :app},        # Use your app's layout
  root_layout: {MyAppWeb.Layouts, :root},  # Optional: custom root layout
  page_title_prefix: "Auth"                # Optional: page title prefix

# Configure DaisyUI 5 Theme System (optional)
config :phoenix_kit,
  theme_enabled: true,
  theme: %{
    theme: "auto",                   # Any of 35+ daisyUI themes or "auto"
    primary_color: "#3b82f6",       # Primary brand color (OKLCH format supported)
    storage: :local_storage,        # :local_storage, :session, :cookie
    theme_controller: true,         # Enable theme-controller integration
    categories: [:light, :dark, :colorful]  # Theme categories to show in switcher
  }

# Migrate existing installations to daisyUI 5
# Run: mix phoenix_kit.migrate_to_daisyui5

# Settings System Configuration (optional defaults)
config :phoenix_kit,
  default_settings: %{
    time_zone: "0",          # UTC+0 (GMT)
    date_format: "Y-m-d",    # ISO format: 2025-09-03
    time_format: "H:i"       # 24-hour format: 15:30
  }

# In your Phoenix app's mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.2"}
  ]
end

# Date Formatting in Templates
# Use Settings-aware functions for automatic user preference integration:
{UtilsDate.format_datetime_with_user_format(user.inserted_at)}
{UtilsDate.format_date_with_user_format(user.confirmed_at)}
{UtilsDate.format_time_with_user_format(Time.utc_now())}

# Manual formatting for specific use cases:
{UtilsDate.format_date(Date.utc_today(), "F j, Y")}  # "September 3, 2025"
{UtilsDate.format_time(Time.utc_now(), "h:i A")}     # "3:30 PM"

# Email Configuration Strategy

## Configuration Priority and Storage

PhoenixKit uses **Settings Database** as the primary source for email configuration,
with Environment Variables as fallback for sensitive credentials.

### 📊 Configuration Sources (by priority, highest to lowest):

1. **Settings Database** (runtime, managed via Web UI at `{prefix}/admin/settings/emails`)
   - All non-sensitive configuration (queue URLs, regions, retention, etc.)
   - Can be updated at runtime without restarting the application
   - Persisted in `phoenix_kit_settings` table

2. **Environment Variables** (production secrets, fallback)
   - `AWS_ACCESS_KEY_ID` - AWS credentials for SES
   - `AWS_SECRET_ACCESS_KEY` - AWS secret key
   - `AWS_REGION` - AWS region (fallback if not in Settings)

3. **config/config.exs** (compile-time, basic app config only)
   - **NOT used for AWS settings or email configuration**
   - Only for basic PhoenixKit integration (repo, mailer module)

### 🔐 Security Best Practices:

- ✅ Store AWS credentials in **Environment Variables** (production)
- ✅ Use **Settings Database** for non-sensitive config (queue URLs, regions, etc.)
- ❌ **NEVER hardcode credentials** in config files

### 📝 Configuration Methods:

#### Method 1: Web UI (Recommended)
Navigate to: `{prefix}/admin/settings/emails`
- Configure AWS SES, SNS, SQS settings
- Enable/disable email system
- Set retention, sampling rate, etc.
- All changes take effect immediately (no restart required)

#### Method 2: Mix Task (CLI)
```bash
mix phoenix_kit.configure_aws_ses --config-set "my-app-tracking"
mix phoenix_kit.configure_aws_ses --region "us-east-1"
mix phoenix_kit.configure_aws_ses --status  # Check current config
```

#### Method 3: AWS Setup Script (Full Automation)
```bash
cd /app/scripts
./aws_ses_sqs_setup.sh  # Creates AWS infrastructure + saves to Settings DB
```

#### Method 4: Environment Variables (Secrets Only)
```bash
export AWS_ACCESS_KEY_ID="your-key-id"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="eu-north-1"  # Optional, can be set via Settings
```

### ⚙️ What Gets Stored Where:

**Settings Database** (via Web UI or mix tasks):
- `aws_region` (default: "eu-north-1")
- `aws_sqs_queue_url`
- `aws_sqs_dlq_url`
- `aws_sqs_queue_arn`
- `aws_sns_topic_arn`
- `aws_ses_configuration_set` (default: "phoenixkit-tracking")
- `email_enabled` (default: false)
- `email_save_body` (default: false)
- `email_ses_events` (default: false)
- `email_retention_days` (default: 90)
- `email_sampling_rate` (default: 100)
- `sqs_polling_enabled` (default: false)
- `sqs_polling_interval_ms` (default: 5000)
- ...all other email settings

**Environment Variables** (production secrets, fallback):
- `AWS_ACCESS_KEY_ID` - Used only if not set in Settings DB
- `AWS_SECRET_ACCESS_KEY` - Used only if not set in Settings DB
- `AWS_REGION` - Optional fallback

**config/config.exs** (basic app settings only):
- `repo:` - database repository (required)
- `mailer:` - override to use parent app's mailer (optional)
- **DO NOT configure AWS credentials or email settings here**

### 🔑 AWS Credentials Priority:

PhoenixKit uses a **smart fallback system** for AWS credentials:

```
1. Settings Database (Primary)
   └─> If aws_access_key_id exists and not empty: USE IT
   └─> If aws_access_key_id is empty/nil: ↓ fallback

2. Environment Variables (Fallback)
   └─> Use AWS_ACCESS_KEY_ID from environment
```

**This means:**
- ✅ If you configure credentials via Web UI → they take **priority**
- ✅ If Settings DB is empty → system falls back to **ENV variables**
- ✅ Both methods work → you choose what's convenient
- ✅ Settings DB overrides ENV → gives you runtime control

### Sender Configuration (from_email, from_name)

**Priority**: Settings DB → Config → Defaults ("noreply@localhost", "PhoenixKit")

Configure via Web UI: `{prefix}/admin/settings/emails` → "Sender Configuration"
- Runtime updates, no restart needed
- All emails use `{from_name} <{from_email}>` format

## Email Configuration (Example - NOT for AWS settings)

**IMPORTANT**: The example below is for understanding the email system architecture.
**AWS credentials and email configuration are managed via Settings Database and Environment Variables.**
**DO NOT put AWS settings in config/config.exs - use Web UI or mix tasks instead.**

```elixir
# config/config.exs - ONLY basic app configuration
config :phoenix_kit,
  repo: MyApp.Repo,
  mailer: MyApp.Mailer  # Optional: delegate to parent app's mailer

# Configure your app's mailer for development
config :my_app, MyApp.Mailer,
  adapter: Swoosh.Adapters.AmazonSES,
  region: "eu-north-1"
  # AWS credentials are provided by PhoenixKit from Settings Database
  # Configure credentials via Web UI at: {prefix}/admin/settings/emails
```

## Email System Features

The PhoenixKit email system provides:
- Comprehensive email logging and analytics
- Real-time delivery, bounce, and engagement management
- Anti-spam and rate limiting features
- Admin interfaces at `{prefix}/admin/emails/*`
- Automatic integration with PhoenixKit.Mailer
- AWS SES event tracking via SNS/SQS pipeline

# OAuth Authentication Configuration (V16+)
#
# OAuth authentication is built-in to PhoenixKit with all required dependencies included.
# To enable OAuth functionality, follow these configuration steps:
#
# Step 1: Configure providers in your app's config/config.exs
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, []},
    apple: {Ueberauth.Strategy.Apple, []},
    github: {Ueberauth.Strategy.Github, []}
  ]

config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: System.get_env("GOOGLE_CLIENT_ID"),
  client_secret: System.get_env("GOOGLE_CLIENT_SECRET")

config :ueberauth, Ueberauth.Strategy.Apple.OAuth,
  client_id: System.get_env("APPLE_CLIENT_ID"),
  team_id: System.get_env("APPLE_TEAM_ID"),
  key_id: System.get_env("APPLE_KEY_ID"),
  private_key: System.get_env("APPLE_PRIVATE_KEY")

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_CLIENT_SECRET")

# Step 2: Set environment variables
# Make sure to set the required environment variables for your chosen providers.
# For development, you can use .env file or export them:
#
# export GOOGLE_CLIENT_ID="your-google-client-id"
# export GOOGLE_CLIENT_SECRET="your-google-client-secret"
# export APPLE_CLIENT_ID="com.yourapp.service"
# export APPLE_TEAM_ID="your-apple-team-id"
# export APPLE_KEY_ID="your-apple-key-id"
# export APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n..."
# export GITHUB_CLIENT_ID="your-github-client-id"
# export GITHUB_CLIENT_SECRET="your-github-client-secret"
#
# Step 3: Enable OAuth in PhoenixKit admin settings
# Navigate to {prefix}/admin/settings and check "Enable OAuth authentication"
# This setting is stored in the database and can be toggled at runtime.
#
# Step 4: Run migrations (if not already done)
# mix ecto.migrate  # V16 migration includes oauth_providers table
#
# OAuth features:
# - All OAuth dependencies included automatically with PhoenixKit
# - Runtime control via admin settings (oauth_enabled)
# - Google, Apple, and GitHub Sign-In support
# - Automatic account linking by email
# - OAuth provider management per user
# - Access at {prefix}/users/auth/:provider
# - Token storage for future API calls
# - Referral code support via query params: {prefix}/users/auth/google?referral_code=ABC123
# - OAuth buttons automatically hide when disabled in settings

# Magic Link Registration Configuration (V16+)
config :phoenix_kit, PhoenixKit.Users.MagicLinkRegistration,
  expiry_minutes: 30  # Default: 30 minutes

# Magic Link Registration features:
# - Two-step passwordless registration
# - Email verification built-in
# - Referral code support
# - Registration completion at {prefix}/users/register/complete/:token
```

## Troubleshooting

For detailed troubleshooting guides and solutions, see your local `CLAUDE.local.md` file.

### Common Issues

Common issues and their solutions are documented in the local configuration file:

- **Email system issues** - Configuration problems, delivery failures, AWS SES integration
- **Database configuration** - Repository setup, migration issues
- **Performance optimization** - Slow email sending, database load optimization
- **Testing strategies** - Unit tests, integration tests, mocking

### Quick Reference

If you encounter issues:

1. Check your local `CLAUDE.local.md` for detailed troubleshooting steps
2. Check logs: `tail -f log/dev.log`
3. Enable debug mode: `Logger.configure(level: :debug)`
4. Run tests: `mix test`
5. Check GitHub issues: https://github.com/phoenixkit/phoenix_kit/issues

---

## Key File Structure

### Core Files

- `lib/phoenix_kit.ex` - Main API module
- `lib/phoenix_kit/users/auth.ex` - Authentication context
- `lib/phoenix_kit/users/auth/user.ex` - User schema
- `lib/phoenix_kit/users/auth/user_token.ex` - Token management
- `lib/phoenix_kit/users/magic_link.ex` - Magic link authentication
- `lib/phoenix_kit/users/magic_link_registration.ex` - Magic link registration (V16+)
- `lib/phoenix_kit/users/oauth.ex` - OAuth authentication context (V16+)
- `lib/phoenix_kit/users/oauth_provider.ex` - OAuth provider schema (V16+)
- `lib/phoenix_kit/users/role*.ex` - Role system (Role, RoleAssignment, Roles)
- `lib/phoenix_kit/settings.ex` - Settings context and management
- `lib/phoenix_kit/utils/date.ex` - Date formatting utilities with Settings integration
- `lib/phoenix_kit/emails/*.ex` - Email system modules
- `lib/phoenix_kit/mailer.ex` - Mailer with automatic email system integration

### Web Integration

- `lib/phoenix_kit_web/router.ex` - Library router (dev/test only, parent apps use `phoenix_kit_routes()`)
- `lib/phoenix_kit_web/integration.ex` - Router integration macro for parent applications
- `lib/phoenix_kit_web/endpoint.ex` - Phoenix endpoint (uses `Plug.Telemetry`, no custom supervisor)
- `lib/phoenix_kit_web/users/oauth_controller.ex` - OAuth authentication controller (V16+)
- `lib/phoenix_kit_web/users/magic_link_registration_controller.ex` - Magic link registration controller (V16+)
- `lib/phoenix_kit_web/users/magic_link_registration.ex` - Registration completion LiveView (V16+)
- `lib/phoenix_kit_web/users/auth.ex` - Web authentication plugs
- `lib/phoenix_kit_web/users/*.ex` - LiveView components (login, registration, settings, etc.)
- `lib/phoenix_kit_web/live/*.ex` - Admin interfaces (dashboard, users, sessions, settings, modules)
- `lib/phoenix_kit_web/live/settings.ex` - Settings management interface
- `lib/phoenix_kit_web/live/modules/emails/*.ex` - Email system LiveView interfaces
- `lib/phoenix_kit_web/components/core_components.ex` - UI components
- `lib/phoenix_kit_web/components/layouts.ex` - Layout module (fallback for parent apps)
- `lib/phoenix_kit_web/controllers/error_html.ex` - HTML error rendering
- `lib/phoenix_kit_web/controllers/error_json.ex` - JSON error rendering

### Migration & Config

- `lib/phoenix_kit/migrations/postgres/v01.ex` - V01 migration (basic auth)
- `lib/phoenix_kit/migrations/postgres/v07.ex` - V07 migration (email system tables)
- `lib/phoenix_kit/migrations/postgres/v09.ex` - V09 migration (email blocklist)
- `lib/phoenix_kit/migrations/postgres/v16.ex` - V16 migration (OAuth providers table)
- `lib/mix/tasks/phoenix_kit.migrate_to_daisyui5.ex` - DaisyUI 5 migration tool
- `config/config.exs` - Library configuration
- `mix.exs` - Project and package configuration
- `scripts/aws_ses_sqs_setup.sh` - AWS SES infrastructure automation

### DaisyUI 5 Assets

- `priv/static/assets/phoenix_kit_daisyui5.css` - Modern CSS with @plugin directives
- `priv/static/assets/phoenix_kit_daisyui5.js` - Enhanced theme system with controller integration
- `priv/static/examples/tailwind_config_daisyui5.js` - Tailwind CSS 3 example config
- `priv/static/examples/tailwind_css4_config.css` - Tailwind CSS 4 example config

## Development Workflow

PhoenixKit supports a complete professional development workflow:

1. **Development** - Local development with PostgreSQL
2. **Testing** - Comprehensive test suite with database integration
3. **Quality** - Static analysis and type checking
4. **Documentation** - Generated docs with usage examples
5. **Publishing** - Ready for Hex.pm with proper versioning