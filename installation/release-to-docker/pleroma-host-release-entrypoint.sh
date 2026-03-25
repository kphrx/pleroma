#!/usr/bin/env bash
set -euo pipefail

uid="${PLEROMA_UID:-}"
gid="${PLEROMA_GID:-}"

if [[ -z "${uid}" || -z "${gid}" ]]; then
  uid="$(stat -c '%u' /opt/pleroma)"
  gid="$(stat -c '%g' /opt/pleroma)"
fi

export HOME="${HOME:-/opt/pleroma}"

if [[ "${PLEROMA_RUN_MIGRATIONS:-1}" != "0" && "${1:-}" == "/opt/pleroma/bin/pleroma" && "${2:-}" == "start" ]]; then
  echo "Running migrations..."
  gosu "${uid}:${gid}" /opt/pleroma/bin/pleroma_ctl migrate
fi

exec gosu "${uid}:${gid}" "$@"
