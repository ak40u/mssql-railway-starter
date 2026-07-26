#!/bin/bash
set -euo pipefail

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
DB="${MSSQL_DATABASE:-app}"
APP_USER="${MSSQL_USER:-}"

if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  echo "MSSQL_SA_PASSWORD is not set - SQL Server has no default password and will not start without one" >&2
  exit 1
fi

# SQL Server checks this itself, but it does so several seconds into startup and
# reports it in the middle of a long log. Checking here turns a confusing crash
# loop into one line at the top of the deploy log.
if [ "${#MSSQL_SA_PASSWORD}" -lt 8 ]; then
  echo "MSSQL_SA_PASSWORD is shorter than 8 characters - SQL Server rejects it" >&2
  exit 1
fi
classes=0
[[ "$MSSQL_SA_PASSWORD" =~ [A-Z] ]] && classes=$((classes+1))
[[ "$MSSQL_SA_PASSWORD" =~ [a-z] ]] && classes=$((classes+1))
[[ "$MSSQL_SA_PASSWORD" =~ [0-9] ]] && classes=$((classes+1))
[[ "$MSSQL_SA_PASSWORD" =~ [^A-Za-z0-9] ]] && classes=$((classes+1))
if [ "$classes" -lt 3 ]; then
  echo "MSSQL_SA_PASSWORD uses only $classes of the four character classes - SQL Server requires three" >&2
  exit 1
fi

/opt/mssql/bin/sqlservr &
SQLSERVR_PID=$!

# SIGTERM has to reach sqlservr, not just this script. Without it the platform
# kills the container outright on every deploy and SQL Server spends the next
# start recovering databases that were never shut down.
shutdown() {
  echo "stopping SQL Server"
  kill -TERM "$SQLSERVR_PID" 2>/dev/null || true
  wait "$SQLSERVR_PID" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

echo "waiting for SQL Server to accept connections"
for i in $(seq 1 90); do
  if ! kill -0 "$SQLSERVR_PID" 2>/dev/null; then
    echo "SQL Server exited during startup - see the log above for the reason" >&2
    wait "$SQLSERVR_PID"
    exit 1
  fi
  if "$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -N -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Everything below is idempotent, so it runs on every start rather than only on
# an empty volume: a restored or resized volume gets the same treatment.
"$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -N -b -Q "
IF DB_ID(N'$DB') IS NULL
BEGIN
  CREATE DATABASE [$DB];
END" && echo "database [$DB] ready"

if [ -n "$APP_USER" ] && [ -n "${MSSQL_PASSWORD:-}" ]; then
  "$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -N -b -Q "
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$APP_USER')
BEGIN
  CREATE LOGIN [$APP_USER] WITH PASSWORD = N'$MSSQL_PASSWORD', DEFAULT_DATABASE = [$DB], CHECK_POLICY = ON;
END
USE [$DB];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$APP_USER')
BEGIN
  CREATE USER [$APP_USER] FOR LOGIN [$APP_USER];
  ALTER ROLE db_owner ADD MEMBER [$APP_USER];
END" && echo "login [$APP_USER] ready, owner of [$DB]"
fi

echo "SQL Server is up"
wait "$SQLSERVR_PID"
