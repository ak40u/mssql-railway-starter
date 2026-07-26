# Pinned to a specific cumulative update. The stock template uses 2022-latest,
# which is both an older major version and a moving tag - the same template
# deployed twice can give you different builds, under the same data volume.
FROM mcr.microsoft.com/mssql/server:2022-CU26-ubuntu-22.04

USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Runs as root because the mounted volume is root-owned; this is what the
# RAILWAY_RUN_UID=0 variable does on the platform, stated here instead.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
