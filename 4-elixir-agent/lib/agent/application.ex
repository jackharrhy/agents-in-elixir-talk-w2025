defmodule Agent.Application do
  use Application

  @impl true
  def start(_type, _args) do
    # Ensure data directories exist
    File.mkdir_p!("priv/data")
    File.mkdir_p!("priv/uploads")

    children = [
      # DETS persistence store - must start first
      Agent.Chat.Store,
      # Command executor for safe shell execution
      Agent.Command.Executor,
      # Registry for tracking chat processes by ID
      {Registry, keys: :unique, name: Agent.Chat.Registry},
      # Dynamic supervisor for chat GenServers
      {DynamicSupervisor, strategy: :one_for_one, name: Agent.Chat.Supervisor},
      # Phoenix endpoint
      AgentWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Agent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
