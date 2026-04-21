defmodule Pleroma.Repo.Migrations.CleanupStaleDigestEmailJobs do
  use Ecto.Migration

  def up do
    execute(
      "DELETE from oban_jobs WHERE queue = 'mailer' AND worker = 'Pleroma.Workers.Cron.DigestEmailsWorker'"
    )
  end
end
