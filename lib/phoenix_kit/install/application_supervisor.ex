defmodule PhoenixKit.Install.ApplicationSupervisor do
  def add_supervisor(igniter) do
    {igniter, endpoint} = Igniter.Libs.Phoenix.select_endpoint(igniter)

    igniter
    |> Igniter.Project.Application.add_new_child(PhoenixKit.Supervisor,
      after: [endpoint]
    )
  end
end
