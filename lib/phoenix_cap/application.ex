defmodule PhoenixCap.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PhoenixCap.Store.ETS
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PhoenixCap.Supervisor)
  end
end
