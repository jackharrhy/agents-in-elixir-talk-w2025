import Config

config :agent, AgentWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: "super_secret_key_base_for_dev_only_change_in_prod_1234567890abcdef",
  server: true

config :agent,
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  uploads_dir: "priv/uploads",
  dets_path: "priv/data/chats.dets"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason
