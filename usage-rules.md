# PhoenixKit Usage Rules

PhoenixKit is a comprehensive SaaS starter kit for Phoenix applications that provides authentication, authorization, admin interfaces, and email tracking out of the box.

## What PhoenixKit Provides

### User Authentication & Authorization
- Complete user registration, login, and logout flows
- Password and magic link (passwordless) authentication
- Email confirmation workflow
- Password reset functionality
- Session management with secure tokens
- Role-based access control with Owner, Admin, and User roles
- Custom role creation and management

### Database Tables
- Uses `phoenix_kit_users` table (not `users`) for all user data
- Manages `phoenix_kit_users_tokens` for authentication tokens
- Provides `phoenix_kit_user_roles` and `phoenix_kit_user_role_assignments` for RBAC
- Includes `phoenix_kit_referral_codes` and related tables for referral programs
- Handles email tracking with `phoenix_kit_email_logs` and `phoenix_kit_email_events`

### Admin Backend
- Built-in admin dashboard at `/phoenix_kit/admin`
- User management interface with role assignment
- Session management and monitoring
- Global settings configuration (app title, timezone, time format)
- Modules manager for feature management
- Referral program management

### Emails
- Email tracking with delivery status and events
- Rate limiting and archival capabilities
- Support for multiple email providers (AWS SES, SendGrid, Mailgun, SMTP)
- Email interception for development/testing
- Comprehensive email metrics and logging

### Settings Management
- Global application settings storage
- Timezone and time format configuration
- Extensible key-value settings system

### Authentication Scopes
PhoenixKit provides three authentication levels via `on_mount` hooks:
- `:phoenix_kit_mount_current_scope` - Loads user if authenticated, allows anonymous
- `:phoenix_kit_redirect_if_authenticated_scope` - Redirects authenticated users away
- `:phoenix_kit_ensure_authenticated_scope` - Requires authentication, redirects to login if not authenticated
- `:phoenix_kit_ensure_admin` - Requires admin role
- `:phoenix_kit_ensure_owner` - Requires owner role

### Integration Points
- Uses your existing Ecto repository
- Integrates with Phoenix router via `phoenix_kit_routes()`
- Optional layout integration with your app's layouts
- Configurable URL prefix for all routes

### Caching System
- Built-in caching functionality for frequently accessed data
- Module-based cache organization

### Utilities
- Repository helpers for common database operations
- Location tracking for user registrations (IP, country, region, city)
- Referral code generation and tracking
- PubSub integration for real-time updates

## Important Conventions

### Database References
- Always reference `phoenix_kit_users` when creating foreign keys to users
- Use `references(:phoenix_kit_users, on_delete: :delete_all)` in migrations

### User Access
- Access current user via `@phoenix_kit_current_scope` assign in LiveViews
- Use `PhoenixKit.Users.Auth.Scope` module for scope queries
- Never create custom authentication - always use PhoenixKit

### Role Management
- Check roles with `PhoenixKit.Users.Roles.user_has_role?/2`
- Assign roles with `PhoenixKit.Users.Roles.promote_to_admin/1` and similar functions
- First registered user automatically becomes Owner

### Protected Routes
- Wrap protected LiveView routes in `live_session` with appropriate `on_mount` hooks
- Use scope-based authentication for fine-grained access control

## Installation
PhoenixKit uses Igniter for semi-automatic installation, handling migration generation, configuration, and router integration automatically.

## Architecture
- Library-first design (not an OTP application)
- PostgreSQL-only for production optimization
- Versioned schema migrations with forward compatibility
- Minimal dependencies, uses your existing infrastructure