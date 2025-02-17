# Migrating from Rebased

## Code migration

As Rebased only officially supported running from source code, we assume you're running it from source as well. To migrate source from upstream, you need to set the origin repository URL to upstream and pull the changes.

```bash
git remote set-url origin https://git.pleroma.social/pleroma/pleroma
git pull -r
```

Then, install the dependencies and compile as usual:

```bash
MIX_ENV=prod mix deps.get
MIX_ENV=prod mix compile
```

As Rebased recommends using [`asdf` version manager](https://asdf-vm.com/), you might want to either keep using it or switch to system Elixir installation. If you choose the latter, follow Pleroma installation instructions for your distribution and replace the Pleroma systemd service with one provided by Pleroma upstream.

```bash
sudo cp /opt/pleroma/installation/pleroma.service /etc/systemd/system/pleroma.service
sudo systemctl daemon-reload
```

Because Rebased doesn't come with a bundled frontend, you most likely have one installed in thhe `instance/static` directory. You can remove it, as Pleroma comes with a bundled frontend. Be sure not to remove other files you might have there, like custom emojis.

## Database migration

> Note: While it is not necessary to rollback Rebased-specific migrations because they don't include breaking changes, it is recommended to do so to keep the database clean. You will lose data related to Rebased-specific features, like the configured webhooks or user-defined location. Consider taking a backup.

To rollback Rebased-specific migrations:

```bash
MIX_ENV=prod mix ecto.rollback --migrations-path priv/repo/optional_migrations/rebased_rollbacks --all
```

Then, just

```bash
MIX_ENV=prod mix ecto.migrate
```

to apply Pleroma database migrations.
