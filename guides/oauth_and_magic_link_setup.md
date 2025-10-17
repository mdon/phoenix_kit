# OAuth & Magic Link Setup

PhoenixKit ships optional authentication modules that integrate with the core user system. This
guide captures the configuration steps that used to live in `CLAUDE.md`.

## OAuth Authentication (V16+)

PhoenixKit bundles the required Ueberauth dependencies enabling Google, Apple, and GitHub login.
To enable OAuth in a host application:

1. **Configure providers** in `config/config.exs`:

   ```elixir
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
   ```

2. **Provide credentials** via environment variables (examples):

   ```bash
   export GOOGLE_CLIENT_ID="your-google-client-id"
   export GOOGLE_CLIENT_SECRET="your-google-client-secret"
   export APPLE_CLIENT_ID="com.yourapp.service"
   export APPLE_TEAM_ID="your-apple-team-id"
   export APPLE_KEY_ID="your-apple-key-id"
   export APPLE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n..."
   export GITHUB_CLIENT_ID="your-github-client-id"
   export GITHUB_CLIENT_SECRET="your-github-client-secret"
   ```

3. **Enable OAuth** at runtime from the PhoenixKit admin UI: navigate to
   `{prefix}/admin/settings` and toggle “Enable OAuth authentication”.

4. **Run migrations** (`mix ecto.migrate`) to ensure the `oauth_providers` tables are created.

### OAuth Features

- Runtime enable/disable via settings (`oauth_enabled`)
- Google, Apple, and GitHub sign-in out of the box
- Automatic account linking by email
- Provider management per user with audit trail
- Routes exposed at `{prefix}/users/auth/:provider`
- Referral code passthrough (`?referral_code=ABC123`)
- Buttons automatically hide when OAuth is disabled

## Magic Link Registration (V16+)

Magic Link registration provides a two-step passwordless onboarding flow.

1. Configure the expiry window in `config/config.exs`:

   ```elixir
   config :phoenix_kit, PhoenixKit.Users.MagicLinkRegistration,
     expiry_minutes: 30
   ```

2. Ensure email delivery is configured (see `lib/phoenix_kit_web/live/modules/emails/README.md`).

### Magic Link Features

- Two-phase registration with email verification
- Referral code support end-to-end
- Completion routes at `{prefix}/users/register/complete/:token`
- Fully integrated with PhoenixKit’s authentication contexts
