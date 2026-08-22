# Migrating from Rebased

Rebased and Pleroma currently have compatible database schemas, so removing
Rebased-specific database objects is optional. The cleanup described below is
destructive and can take a long time on large databases.

This guide requires a Pleroma release that contains this document and native
webhook support. If you are reading the development version of this guide
before those changes reach `stable`, wait for the corresponding stable release.

## Prepare and back up

Plan a maintenance window and read the [backup guide](../administration/backup.md)
before starting.

Stop Rebased and confirm it is stopped before making the backup. Omit the
backup guide's final restart step and leave Rebased stopped:

```bash
sudo systemctl stop pleroma
sudo systemctl is-active pleroma
```

Make a verified database backup and a copy of the Rebased installation,
including its configuration, uploads, and `instance` directory. Also save the
current systemd unit if you plan to replace it.

## Install Pleroma

Do not use `git pull --rebase` to change an existing Rebased checkout into a
Pleroma checkout. The forks use different branches, and rebasing can replay
Rebased-specific commits over Pleroma. Move the old checkout aside and clone a
clean copy of Pleroma instead. The paths below assume the default source
installation in `/opt/pleroma`:

```bash
sudo mv /opt/pleroma /opt/pleroma.rebased
sudo mkdir /opt/pleroma
sudo chown pleroma:pleroma /opt/pleroma
sudo -Hu pleroma git clone -b stable https://git.pleroma.social/pleroma/pleroma /opt/pleroma
```

Restore the instance-specific files from the old checkout. This usually
includes `config/prod.secret.exs`, `config/prod.exported_from_db.secret.exs` if
present, `uploads`, and `instance`. Diff and restore any other non-stock
configuration files, preserve their ownership, and review them before starting
Pleroma.

Pleroma requires Elixir 1.15 or newer. Install supported Erlang and Elixir
versions as described in the installation guide for your distribution before
running any Mix command. Do not reuse Rebased's `.tool-versions`. If you keep
using [`asdf`](https://asdf-vm.com/), select supported versions in the
`pleroma` user's home and use the asdf Mix shim for every command below.

Set `MIX` to the appropriate binary, verify the selected runtime, then install
the dependencies and compile Pleroma:

```bash
cd /opt/pleroma
MIX=/usr/bin/mix
# If using asdf instead:
# MIX=/var/lib/pleroma/.asdf/shims/mix
sudo -Hu pleroma "$MIX" --version
sudo -Hu pleroma MIX_ENV=prod "$MIX" deps.get
sudo -Hu pleroma MIX_ENV=prod "$MIX" compile
```

Compare your existing systemd unit with `installation/pleroma.service`. If you
replace it, review its user, paths, and environment first. Reload systemd after
making changes:

```bash
sudo systemctl daemon-reload
```

Rebased does not bundle a frontend, so `instance/static` may contain an
installed frontend. Pleroma includes a bundled frontend. You can remove the
separately installed frontend after the migration, but do not remove other
instance files such as custom emojis.

## Database migration

Rebased's extra columns, index, and enum labels do not prevent Pleroma from
starting. Existing notifications with Rebased-only event types are not
supported by Pleroma, however, and can cause notification API errors. Run the
cleanup below, or archive and remove those notification rows separately before
starting Pleroma. Skipping the cleanup preserves them if you need to restore
Rebased.

Pleroma supports Rebased's webhook schema. The cleanup does not roll back the
shared webhook migrations, so webhook configuration is preserved.

To perform the optional cleanup, run the rollback while the service is stopped:

```bash
MIX=/usr/bin/mix
# If using asdf instead:
# MIX=/var/lib/pleroma/.asdf/shims/mix
sudo -Hu pleroma MIX_ENV=prod "$MIX" ecto.rollback --migrations-path priv/repo/optional_migrations/rebased_rollbacks --all
```

This deletes the Rebased-only `accepts_email_list`, `location`, and
`last_move_at` user fields and the `pleroma:participation_accepted`,
`pleroma:participation_request`, `pleroma:event_reminder`, and
`pleroma:event_update` notifications. It also rewrites the notifications table
and can require substantial time, free disk space, and write-ahead log capacity
on a large instance.

Apply all pending Pleroma migrations:

```bash
sudo -Hu pleroma MIX_ENV=prod "$MIX" ecto.migrate
```

## Start and verify Pleroma

Start Pleroma and inspect its status and logs:

```bash
sudo systemctl start pleroma
sudo systemctl status pleroma
sudo journalctl -u pleroma -n 100 --no-pager
```

Verify that the instance, uploads, frontend, and webhook configuration work as
expected before deleting `/opt/pleroma.rebased` or the database backup. If the
migration fails, keep the service stopped and restore both the database backup
and the previous checkout before restarting Rebased. If you changed the
systemd unit or runtime setup, restore those too and run
`systemctl daemon-reload` before restarting the service.
