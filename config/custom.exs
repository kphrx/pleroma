use Mix.Config

config :pleroma, :instance,
  registrations_open: false,
  no_attachment_links: true,
  managed_config: false

# なんか知らんけどこれ無効化出来なくなってない？
#config :pleroma, :app_account_creation, enabled: false

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

config :pleroma_job_queue, :queues,
  background: 10

config :pleroma, Pleroma.Upload,
  link_name: false,
  filters: [
    Pleroma.Upload.Filter.Dedupe,
    Pleroma.Upload.Filter.AnonymizeFilename,
    Pleroma.Upload.Filter.Mogrify
  ]

config :pleroma, Pleroma.Upload.Filter.AnonymizeFilename,
  text: "media.{extension}"

config :pleroma, Pleroma.Upload.Filter.Mogrify,
  args: ["strip", "auto-orient", {"quality", 100}]
