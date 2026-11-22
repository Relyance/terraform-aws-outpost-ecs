#!/bin/sh
set -eu
umask 077

if [ "${1:-}" = health ]; then
  response=$(REDISCLI_AUTH="$REDIS_WORKER_PASSWORD" redis-cli --tls --sni "$REDIS_HOSTNAME" \
    -h 127.0.0.1 -p "$REDIS_PORT" --user "$REDIS_WORKER_USER" PING)
  test "$response" = PONG
  exit
fi

: "${REDIS_TLS_CERTIFICATE:?Missing Redis server certificate}"
: "${REDIS_TLS_KEY:?Missing Redis server key}"
: "${REDIS_WORKER_PASSWORD:?Missing Redis worker password}"
: "${REDIS_EXPORTER_PASSWORD:?Missing Redis exporter password}"

worker_hash=$(printf '%s' "$REDIS_WORKER_PASSWORD" | sha256sum)
exporter_hash=$(printf '%s' "$REDIS_EXPORTER_PASSWORD" | sha256sum)
{
  # Redis 7 uses the default user's permissions to replay MULTI/EXEC from
  # AOF. Keep login disabled and no passwords, but let that internal replay
  # restore the broker's transactional unacknowledged-message index.
  printf 'user default off resetpass ~* &* +@all\n'
  printf 'user %s #%s %s\n' "$REDIS_WORKER_USER" "${worker_hash%% *}" "$REDIS_WORKER_ACCESS"
  printf 'user %s #%s %s\n' "$REDIS_EXPORTER_USER" "${exporter_hash%% *}" "$REDIS_EXPORTER_ACCESS"
} > "$REDIS_RUNTIME_DIR/users.acl"
printf '%s\n' "$REDIS_TLS_CERTIFICATE" > "$REDIS_RUNTIME_DIR/tls.crt"
printf '%s\n' "$REDIS_TLS_KEY" > "$REDIS_RUNTIME_DIR/tls.key"
unset REDIS_WORKER_PASSWORD REDIS_EXPORTER_PASSWORD REDIS_TLS_CERTIFICATE REDIS_TLS_KEY

# A retiring ECS task may still be finishing I/O after the scheduler starts
# its replacement. Take an exclusive lock on the shared data filesystem.
exec 9>>"$REDIS_DATA_DIR/.redis.lock"
flock --exclusive --nonblock 9
exec redis-server --bind "$REDIS_BIND" --port 0 --tls-port "$REDIS_PORT" \
  --tls-cert-file "$REDIS_RUNTIME_DIR/tls.crt" --tls-key-file "$REDIS_RUNTIME_DIR/tls.key" \
  --tls-auth-clients no --aclfile "$REDIS_RUNTIME_DIR/users.acl" --dir "$REDIS_DATA_DIR" \
  --appendonly yes --appendfsync always --save "" \
  --maxmemory "$REDIS_MAX_MEMORY" --maxmemory-policy noeviction
