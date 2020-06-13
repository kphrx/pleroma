#!/bin/ash

set -e

usermod -u ${USER_ID:-1000} pleroma
groupmod -g ${GROUP_ID:-1000} pleroma

chown -R pleroma: /var/lib/pleroma
chown -R pleroma: /etc/pleroma

echo "-- Waiting for database..."
while ! pg_isready -U ${DB_USER:-pleroma} -d postgres://${DB_HOST:-db}:5432/${DB_NAME:-pleroma} -t 1; do
    sleep 1s
done

echo "-- Running migrations..."
su-exec pleroma ~pleroma/bin/pleroma_ctl migrate

echo "-- Starting!"
exec su-exec pleroma ~pleroma/bin/pleroma start
