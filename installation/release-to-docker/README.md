# Run OTP releases on older glibc using Docker

Pleroma OTP releases are built on specific distros and may require a newer `glibc`
than your host has. A typical failure looks like:

```
... /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found ...
```

If you don't want to upgrade your host OS, you can run the existing OTP release
from `/opt/pleroma` inside an Ubuntu 24.04 container while keeping your existing
host paths (`/etc/pleroma`, `/var/lib/pleroma`, etc.).

This folder provides a "shim" container + systemd unit. It is **not** the Pleroma
Docker image.

## What this does

- Builds a small Ubuntu 24.04 image with runtime libs (including newer `glibc`).
- Mounts your existing host release at `/opt/pleroma` into the container.
- Runs as the same UID/GID that owns `/opt/pleroma` on the host (via `gosu`).
- Optionally runs migrations automatically on container start.
- Uses `network_mode: host` so your existing config that talks to `localhost`
  keeps working.

## Setup (Debian/Ubuntu host)

1. Install Docker Engine + the Docker Compose plugin.
2. Copy these files to a stable location (example: `/etc/pleroma/container`):

   ```
   mkdir -p /etc/pleroma/container
   cp -a /opt/pleroma/installation/release-to-docker/* /etc/pleroma/container/
   ```

3. Build the shim image:

   ```
   cd /etc/pleroma/container
   docker compose build
   ```

4. Replace your systemd unit:

   ```
   cp /etc/pleroma/container/pleroma.service /etc/systemd/system/pleroma.service
   systemctl daemon-reload
   systemctl enable --now pleroma
   journalctl -u pleroma -f
   ```

## Running `pleroma_ctl`

Since the host binary may not run on older `glibc`, run admin commands inside the
container:

```
cd /etc/pleroma/container
docker compose exec pleroma /opt/pleroma/bin/pleroma_ctl status
docker compose run --rm --no-deps pleroma /opt/pleroma/bin/pleroma_ctl migrate
```

## Configuration notes

- Migrations run automatically by default.
  - Set `PLEROMA_RUN_MIGRATIONS=0` in `docker-compose.yml` to disable.
