use Mix.Config

config :pleroma, :instance,
  managed_config: false

config :pleroma, :frontend_configurations,
  pleroma_fe: false,
  masto_fe: %{
    showInstanceSpecificPanel: false
  }
