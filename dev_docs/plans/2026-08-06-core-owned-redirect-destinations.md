# Core-owned redirect destinations

**Date:** 2026-08-06
**Repo:** phoenix_kit (core)
**Status:** design, approved for planning

## Problem

Core sends users "home" by calling `Routes.path("/")`. That function prefixes
the active locale, so the redirect arrives as `/en`. The route that would serve
it belongs to the host application, and core has no way to know whether the host
declared one. When it hasn't, every such redirect 404s.

Measured in andi before the host-side workaround: `/` answered 200 while `/en`,
`/et` and `/ru` all returned 404.

This is not one bug in one flow. `Routes.path("/")` is hardcoded at **nine**
call sites across five files:

| Site | Anonymous possible? |
|---|---|
| `maintenance_page_live.ex:54,65,87` (3) | yes |
| `oauth.ex:260` | yes — the root session can expire mid-flow |
| `oauth.ex:354` | no |
| `session.ex:110` (logout → account switch) | no |
| `session.ex:132` (multi-session gate refusal) | yes |
| `session.ex:140` | no |
| `qr_login_confirm.ex:33` | no |

A **tenth** site behaves the same way with a literal string: `auth.ex:683`, the
admin-area guard, which ejects a non-admin to `"/"` with the flash "You do not
have permission to access this section". An **eleventh**, `auth.ex:321`, is full
logout, also hardcoding `"/"` — so the two logout branches send users to
differently-shaped URLs for the same logical destination.

Scope of exposure: any PhoenixKit application with the Languages module enabled.
With `default_language_no_prefix` off — core's default — the prefix is applied to
*every* locale including the default, so all of them break. With it on, only the
non-default locales break. A single-language install never notices.

The requirement is not documented anywhere a host author would look: not in the
installer, not in `doctor`, only in a CHANGELOG entry for 1.7.150 which states
"the parent app declares a `/:locale` landing".

## What core already owns

Core's own routing is locale-complete — 272 admin paths and 272 locale-prefixed
twins, verified by enumerating the router. `/dashboard`, `/admin` and
`/users/log-in` each have a `/:locale` twin. The single asymmetry in the whole
system is `/`, which belongs to the host and which core cannot declare: the home
*page* is host-owned, and claiming the path would overwrite it.

`/users/log-in` answers 200 in every locale, so redirecting there preserves the
visitor's language instead of switching it, and it exists in every install.

Core also already has the resolver. `Routes.post_auth_path/1` takes ordered
candidates and returns the first that is `local_path?/1` and not `auth_page?/1`,
falling back to the `after_login_path` setting. Its open-redirect guard rejects
protocol-relative URLs, absolute URLs and control-character tricks. **None of the
eleven sites calls it**, it is role-agnostic, and its final fallback is `"/"` —
the unowned path.

## Design

### One resolver

`Routes.safe_destination/2` replaces every hardcoded destination. No call site
decides where to send anyone.

Authenticated:

1. explicit `return_to`, when local and not an auth page
2. `/admin` when `Scope.can_access_admin_area?/1`
3. `/dashboard` otherwise
4. the `after_login_path` setting

Anonymous:

1. the configured site main page, when set and still resolvable
2. `/users/log-in`

Every link is core-owned and locale-complete. **The chain never terminates at
`/`.** That is the invariant the work exists to establish.

The `/admin` versus `/dashboard` fork uses core's own vocabulary and needs no
knowledge of a host's domain. Verified against live accounts: Owner and Admin
reach `/admin`; a Client also passes `can_access_admin_area?` because they hold
`client_portal`, and the host redirects them onward from `/admin` to their own
area; a plain `User` fails the predicate and gets no usable admin page, which is
why the `/dashboard` branch is required rather than decorative.

`auth.ex:683` is the one exception: it must skip step 2, or rejecting a user from
`/admin` would send them back to `/admin`.

### Candidate validation

A candidate is used only when it is (a) a local path, (b) not an auth page, and
(c) **actually routable**. Every call site holds a `conn` or `socket`, and the
router module is available on both (`conn.private.phoenix_router`), so
`Phoenix.Router.route_info/4` can confirm a route exists before anyone is sent
there.

This is what lets `/` stay a legitimate candidate — it is simply not selected
where it does not exist — and it is what makes the configurable main page safe:
if the chosen page is renamed, the stored path stops resolving and the chain
falls through instead of serving a broken link.

### Configurable main page

A new setting, `main_page_path`, in core's **general site settings** — beside
Project Title and Site Address. Not in the Sitemap section.

It is a validated free-text path, following `after_login_path` exactly: a field
on the `SettingsForm` embedded schema, a `get_defaults/0` entry, and a
`validate_local_path` call reusing the existing open-redirect guard.

A page-picker sourced from `sitemap_sources` was considered and **rejected**.
That registry is the only cross-module list of public URLs, and its per-locale
grouping by `canonical_path` is the right shape — but it exposes no stable
identifier, only path strings recomputed from live data, so a renamed page
silently breaks the reference; `collect/1` is uncached and hits the database per
source; and the Sitemap module is *disabled* in the very application this work
is for, which would leave the picker empty exactly where it is needed. A typed
path plus routability validation gives the same safety with none of that.

### Locale canonicalisation

`Routes.path("/", locale: L)` is the authority on whether a prefixed root is a
distinct URL. When core would emit `/` for a locale — the default language when
configured prefixless, or any locale with the Languages module disabled — the
prefixed form is a duplicate of `/` and must redirect to it rather than serve.

Locale comparison is by **base code on both sides**, via
`DialectMapper.extract_base/1`. This is load-bearing: with the Languages module
disabled, `enabled_locale_codes/0` falls back to the dialect `"en-US"` while
`Routes.path/1` emits the base `"en"`, and a raw string comparison rejects core's
own redirect. Normalising also makes `/en-GB` and `/EN` behave like every other
PhoenixKit surface instead of 404ing.

### Host affordance

Core should stop leaving each host to rediscover the "declare the wildcard last,
then validate the segment" invariant. Two options, to be decided during planning:

- a macro that emits the validated `/:locale` → host-home route with the correct
  ordering held inside core; the host passes its `{Controller, :action}`
- `config :phoenix_kit, home_path: {Mod, :fun}`, resolved at runtime by the
  redirect sites

The second is preferred: it removes the assumption rather than packaging it.

Independently of the resolver, `doctor` should warn when a host has more than one
language enabled and no locale-prefixed root route.

## Testing

None of the eleven sites has any test coverage today, which is why this survived
to production.

1. **Resolver unit tests** — a table of (who, what is configured) → destination.
   Anonymous with and without a main page; a main page pointing at a
   non-resolving path; Owner, Admin, Client, plain User; an external URL and a
   control-character path, asserting the open-redirect guard holds.
2. **The invariant** — for every one of the eleven sites, under every input,
   the result is never `"/"` and never a path outside core. This is the point of
   the work and must be asserted, not assumed.
3. **Locale matrix** — each enabled locale × `default_language_no_prefix` on/off
   × Languages module on/off, asserting serve versus canonical-redirect versus
   404, and that the emitted path always resolves in the router.
4. **Integration** — logout with an account switch, and a non-admin reaching
   `/admin`, both walked through their full redirect chains.

## Out of scope

- The role→path mapping table considered earlier. The host does its own
  role-specific routing from the core-owned landing page, so core needs no such
  table.
- Removing `page_action`/`:action` from `LayoutWrapper`, now unused.
- The fail-open audit wrapper around `Activity.log/1`.
