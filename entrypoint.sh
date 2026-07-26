#!/bin/bash
set -euo pipefail

if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  echo "MSSQL_SA_PASSWORD is not set - SQL Server has no default password and will not start without one" >&2
  exit 1
fi

# SQL Server checks this itself, but several seconds into startup and buried in a
# long log. Checking here turns a confusing crash loop into one line at the top of
# the deploy log.
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

# The stock launcher is used as-is. It runs the image's permissions check and its
# custom-setup phase, which is what creates MSSQL_DB and the MSSQL_USER login on
# an empty data directory - reimplementing any of that would only diverge from it.
/opt/mssql/bin/launch_sqlservr.sh /opt/mssql/bin/sqlservr &
LAUNCHER=$!

# What the launcher does not do is handle signals. It is a plain bash script, and
# as PID 1 a bash script with no trap ignores SIGTERM outright - so a deploy would
# fall through to SIGKILL and the next start would go through crash recovery on
# databases that were never closed. Signal the engine directly.
shutdown() {
  echo "stopping SQL Server"
  pkill -TERM -x sqlservr 2>/dev/null || true
  wait "$LAUNCHER" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

wait "$LAUNCHER"
