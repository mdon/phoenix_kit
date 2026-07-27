defmodule PhoenixKit.Install.Deprecations do
  @moduledoc """
  Advisory deprecation notices surfaced by the installer tasks.

  `mix phoenix_kit.install` and `mix phoenix_kit.update` print these so a host
  learns about upcoming changes while running a task they already run. Nothing
  here changes host code or behaviour — the deprecated features keep working
  exactly as before until they are actually removed in a later release.

  Keeping the wording in one place means the install and update tasks can't
  drift, and gives a single home to escalate a notice (or drop it) as a
  deprecation moves through its lifecycle.
  """

  @doc """
  Heads-up that the PhoenixKit **user dashboard** (`/dashboard`) is deprecated.

  It still works unchanged and needs no action now. Its functionality is
  moving into the unified admin panel (`/admin`), which surfaces different
  sections per the viewer's permissions. Printed as advisory only — there are
  no migration steps yet.
  """
  @spec user_dashboard_warning() :: String.t()
  def user_dashboard_warning do
    """
    ⚠️  Deprecation: the PhoenixKit user dashboard (/dashboard) is deprecated.
    It still works exactly as before and needs no action from you right now.
    In a future release it will be removed and its functionality folded into the
    unified admin panel (/admin), which shows different sections based on each
    user's permissions. This is an advance heads-up — no migration steps yet.
    """
  end
end
