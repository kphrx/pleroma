use Mix.Config

config :pleroma, :instance,
  registrations_open: false,
  managed_config: false

config :pleroma, :app_account_creation, enabled: false

config :pleroma, :frontend_configurations,
  pleroma_fe: false,
  masto_fe: %{
    showInstanceSpecificPanel: false
  }

config :pleroma, :chat, enabled: false

config :pleroma, Pleroma.Upload,
  uploader: Pleroma.Uploaders.S3

config :pleroma, Pleroma.Uploaders.S3,
  bucket: "pleroma-kpherox",
  public_endpoint: "https://media.pl.kpherox.dev",
  truncated_namespace: ""

config :pleroma, Pleroma.Web.Federator.RetryQueue,
  enabled: true
