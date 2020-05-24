#!/bin/ash

set -e

usermod -u ${UID:-$(id -u pleroma)} pleroma
groupmod -g ${GID:-$(id -g pleroma)} pleroma

chown -R pleroma: /var/lib/pleroma
chown -R pleroma: /etc/pleroma

echo "-- Waiting for database..."
while ! pg_isready -U ${DB_USER:-pleroma} -d postgres://${DB_HOST:-db}:5432/${DB_NAME:-pleroma} -t 1; do
    sleep 1s
done

echo "-- Running migrations..."
sudo -u pleroma $HOME/bin/pleroma_ctl migrate

echo "-- Starting!"
exec sudo -u pleroma $HOME/bin/pleroma start
