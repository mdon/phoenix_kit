# PhoenixKit - The Elixir Phoenix Starter Kit

Let's not reinvent the wheel every time we create apps, let's create Elixir/Phoenix-powered apps much faster.

## Overview

PhoenixKit is a starter kit for building modern web applications with Elixir and Phoenix. It provides a foundation, patterns, and configurations so you can focus on building your product rather than re-implementing common setup tasks.

## 📦 Current PhoenixKit Features/Modules:
- Users
  - [x] Registration, Login, Logout, Email confirmation, Password reset
  - [x] User roles
- Backend admin
  - [x] User management
  - [x] Role management

## 🛣️ Roadmap
- Users
  - Magic link
  - OAuth
  - 2FA
  - Locale / Timezone
  - Referral Program
- Backend admin
  - Modules manager
  - Settings
    - General
    - Languages
  - Sessions
  - Content publishing
    - Static pages
    - Blog
    - Blocks
      - Sliders
  - Notifications
  - Email
  - Billing system
    - Invoices
    - Integration
      - Stripe
      - PayPal
      - Crypto
  - Newsletter
  - Media / Gallery (with s3 backend)
  - E-commerce
  - Membership
  - SEO
  - AI
  - What’s New
  - Customer service
  - Feedback
  - Roadmap / Ideas
  - Analytics
  
Send your ideas and suggestions about any existing modules and features our way.

### Key Features

- **Igniter installation** - Simplified installation 
- **Authentication** - Registration, login, logout, email confirmation, password reset
- **Role-Based Access Control** - Built-in Owner/Admin/User roles with management interface
- **Layout integration** - Versioned migrations with Oban-style architecture
- **Developer Friendly** - Single command installation with automatic setup

Start building your apps today!

## Installation

PhoenixKit provides multiple installation methods to suit different project needs and developer preferences.

### Semi-Automatic Installation

**Recommended for most projects**

Add both `phoenix_kit` and `igniter` to your project dependencies:

```elixir
# mix.exs
def deps do
  [
    {:phoenix_kit, "~> 1.1"},
    {:igniter, "~> 0.6.0", only: [:dev]}
  ]
end
```

Then run the PhoenixKit installer:

```bash
mix deps.get
mix phoenix_kit.install
```

This will automatically:
- ✅ Auto-detect your Ecto repository
- ✅ **Validate PostgreSQL compatibility** with adapter detection
- ✅ Generate migration files for authentication tables
- ✅ **Optionally run migrations interactively** for instant setup
- ✅ Add PhoenixKit configuration to `config/config.exs`
- ✅ Configure mailer settings for development
- ✅ **Create production mailer templates** in `config/prod.exs`
- ✅ Add authentication routes to your router
- ✅ Provide detailed setup instructions

**Optional parameters:**

```bash
# Specify custom repository
mix phoenix_kit.install --repo MyApp.Repo

# Use PostgreSQL schema prefix for table isolation
mix phoenix_kit.install --prefix "auth" --create-schema

# Specify custom router file path
mix phoenix_kit.install --router-path lib/my_app_web/router.ex
```

### Manual Installation

1. Add `{:phoenix_kit, "~> 1.1"}` to `mix.exs`
2. Run `mix deps.get && mix phoenix_kit.gen.migration`
3. Configure repository: `config :phoenix_kit, repo: MyApp.Repo`
4. Add `phoenix_kit_routes()` to your router
5. Run `mix ecto.migrate`

## Quick Start

Visit these URLs after installation:
- `http://localhost:4000/phoenix_kit/users/register` - User registration
- `http://localhost:4000/phoenix_kit/users/log-in` - User login

## Configuration

### Basic Setup
```elixir
# config/config.exs (automatically added by installer)
config :phoenix_kit, repo: YourApp.Repo

# Production mailer
config :phoenix_kit, PhoenixKit.Mailer,
  adapter: Swoosh.Adapters.SMTP,
  relay: "smtp.your-provider.com",
  username: System.get_env("SMTP_USERNAME"),
  password: System.get_env("SMTP_PASSWORD"),
  port: 587
```

### Layout Integration
```elixir
# Use your app's layout (optional)
config :phoenix_kit,
  layout: {YourAppWeb.Layouts, :app},
  root_layout: {YourAppWeb.Layouts, :root}
```

**Note:** Run `mix deps.compile phoenix_kit --force` after changing configuration.

### Advanced Options
- Custom URL prefix: `phoenix_kit_routes("/authentication")`
- PostgreSQL schemas: `mix phoenix_kit.install --prefix "auth" --create-schema`
- Custom repository: `mix phoenix_kit.install --repo MyApp.CustomRepo`

## Routes

### Public Routes
- `GET /phoenix_kit/users/register` - Registration form
- `GET /phoenix_kit/users/log-in` - Login form
- `GET /phoenix_kit/users/reset-password` - Password reset
- `GET /phoenix_kit/users/confirm/:token` - Email confirmation

### Authenticated Routes
- `GET /phoenix_kit/users/settings` - User settings

### Admin Routes (Owner/Admin only)
- `GET /phoenix_kit/admin/dashboard` - Admin dashboard
- `GET /phoenix_kit/admin/users` - User management

## API Usage

### Current User Access
```elixir
# In your controller or LiveView
user = conn.assigns[:phoenix_kit_current_user]

# Or using Scope system
scope = socket.assigns[:phoenix_kit_current_scope]
PhoenixKit.Users.Auth.Scope.authenticated?(scope)
```

### Role-Based Access
```elixir
# Check user roles
PhoenixKit.Users.Roles.user_has_role?(user, "Admin")

# Promote user to admin
{:ok, _} = PhoenixKit.Users.Roles.promote_to_admin(user)

# Use in LiveView sessions
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_admin}]
```

### Authentication Helpers
```elixir
# In your LiveView sessions
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_mount_current_scope}]
on_mount: [{PhoenixKitWeb.Users.Auth, :phoenix_kit_ensure_authenticated_scope}]
```

## Database Schema

PhoenixKit creates these PostgreSQL tables:
- `phoenix_kit_users` - User accounts with email, names, status
- `phoenix_kit_users_tokens` - Authentication tokens (session, reset, confirm)
- `phoenix_kit_user_roles` - System and custom roles
- `phoenix_kit_user_role_assignments` - User-role mappings with audit trail
- `phoenix_kit_schema_versions` - Migration version tracking

## Role-Based Access Control

### System Roles
- **Owner** - Full system access (first user)
- **Admin** - Management privileges  
- **User** - Standard access (default)

### Role Management
```elixir
# Check roles
PhoenixKit.Users.Roles.get_user_roles(user)
# => ["Admin", "User"]

# Role promotion/demotion
PhoenixKit.Users.Roles.promote_to_admin(user)
PhoenixKit.Users.Roles.demote_to_user(user)

# Create custom roles
PhoenixKit.Users.Roles.create_role(%{name: "Manager", description: "Team lead"})
```

### Built-in Admin Interface
- `/phoenix_kit/admin/dashboard` - System statistics
- `/phoenix_kit/admin/users` - User management with role controls

## Architecture

PhoenixKit follows professional library patterns:
- **Library-First**: No OTP application, minimal dependencies
- **Dynamic Repository**: Uses your existing Ecto repo
- **Versioned Migrations**: Oban-style schema management
- **PostgreSQL Only**: Optimized for production databases

## Contributing

1. Fork and create feature branch
2. Add tests: `mix test`
3. Run quality checks: `mix quality`
4. Submit pull request

## License

MIT License - see [CHANGELOG.md](CHANGELOG.md) for version history.

---

Built with ❤️ for the Elixir Phoenix community
