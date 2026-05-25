#!/bin/ash
set -eu

SEED_SENTINEL_PATH=/var/lib/pleroma/.e2e_seeded
CONFIG_OVERRIDE_PATH=/var/lib/pleroma/config.exs

echo '-- Waiting for database...'
while ! pg_isready -U "${DB_USER:-pleroma}" -d "postgres://${DB_HOST:-db}:${DB_PORT:-5432}/${DB_NAME:-pleroma}" -t 1; do
	sleep 1s
done

echo '-- Writing E2E config overrides...'
cat > "$CONFIG_OVERRIDE_PATH" <<EOF
import Config

config :pleroma, Pleroma.Captcha,
	enabled: false

config :pleroma, :instance,
	registrations_open: true,
	account_activation_required: false,
	approval_required: false
EOF

echo '-- Running migrations...'
/opt/pleroma/bin/pleroma_ctl migrate

echo '-- Starting!'
/opt/pleroma/bin/pleroma start &
PLEROMA_PID=$!

cleanup() {
	if kill -0 "$PLEROMA_PID" 2>/dev/null; then
		kill -TERM "$PLEROMA_PID"
		wait "$PLEROMA_PID" || true
	fi
}

trap cleanup INT TERM

echo '-- Waiting for API...'
api_ok=false
for _i in $(seq 1 120); do
	if wget -qO- http://127.0.0.1:4000/api/v1/instance >/dev/null 2>&1; then
		api_ok=true
		break
	fi
	sleep 1s
done

if [ "$api_ok" != true ]; then
	echo 'Timed out waiting for Pleroma API to become available'
	exit 1
fi

if [ ! -f "$SEED_SENTINEL_PATH" ]; then
	if [ -n "${E2E_ADMIN_USERNAME:-}" ] && [ -n "${E2E_ADMIN_PASSWORD:-}" ] && [ -n "${E2E_ADMIN_EMAIL:-}" ]; then
		echo '-- Seeding admin user' "$E2E_ADMIN_USERNAME" '...'
		if ! /opt/pleroma/bin/pleroma_ctl user new "$E2E_ADMIN_USERNAME" "$E2E_ADMIN_EMAIL" --admin --password "$E2E_ADMIN_PASSWORD" -y; then
			echo '-- User already exists or creation failed, ensuring admin + confirmed...'
			/opt/pleroma/bin/pleroma_ctl user set "$E2E_ADMIN_USERNAME" --admin --confirmed
		fi
	else
		echo '-- Skipping admin seeding (missing E2E_ADMIN_* env)'
	fi

	touch "$SEED_SENTINEL_PATH"
fi

wait "$PLEROMA_PID"
