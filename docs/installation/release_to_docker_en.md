# Running OTP releases via Docker (glibc shim)

Pleroma OTP releases are built on specific distros. If your host OS is older than
the build environment, you may hit runtime linker errors such as:

```
/lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

If you don't want to upgrade your host OS, you can run the existing OTP release
from `/opt/pleroma` inside an Ubuntu 24.04 container while keeping your existing
host config and data directories.

This approach uses a small "shim" container image to provide a newer `glibc`.
It is **not** the official Pleroma Docker image.

## Requirements

- Docker Engine + the Docker Compose plugin on the host
- Root access (or equivalent access to the Docker socket)
- Existing OTP release in `/opt/pleroma`
- Existing config in `/etc/pleroma` and data in `/var/lib/pleroma`

## Setup

1. Copy the provided templates:

   ```sh
   mkdir -p /etc/pleroma/container
   cp -a /opt/pleroma/installation/release-to-docker/* /etc/pleroma/container/
   ```

2. Build the shim image:

   ```sh
   cd /etc/pleroma/container
   docker compose build
   ```

3. Replace your systemd unit:

   ```sh
   cp /etc/pleroma/container/pleroma.service /etc/systemd/system/pleroma.service
   systemctl daemon-reload
   systemctl enable --now pleroma
   journalctl -u pleroma -f
   ```

## Running migrations / `pleroma_ctl`

Migrations are run automatically by default when the container starts. You can
disable this by setting `PLEROMA_RUN_MIGRATIONS=0` in
`/etc/pleroma/container/docker-compose.yml`.

To run admin commands inside the container:

```sh
cd /etc/pleroma/container
docker compose exec pleroma /opt/pleroma/bin/pleroma_ctl status
docker compose run --rm --no-deps pleroma /opt/pleroma/bin/pleroma_ctl migrate
```
