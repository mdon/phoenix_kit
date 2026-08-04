defmodule PhoenixKit.Install.IgniterCompat do
  @moduledoc false

  @igniter_modules [
    Igniter,
    Igniter.Libs.Ecto,
    Igniter.Libs.Phoenix,
    Igniter.Project.Application,
    Igniter.Project.Config,
    Igniter.Project.Deps,
    Igniter.Project.Module,
    Igniter.Project.MixProject,
    Igniter.Code.Common,
    Igniter.Code.Function,
    Igniter.Code.List
  ]

  @rewrite_modules [
    Rewrite.Source
  ]

  @modules @igniter_modules ++ @rewrite_modules

  defmacro __using__(_opts) do
    quote do
      @compile {:no_warn_undefined, unquote(@modules)}
    end
  end
end
