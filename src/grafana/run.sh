#!/bin/sh
set -eu

# This image is intentionally self-contained.  Do not allow the Grafana
# container entrypoint to turn an environment variable into a network plugin
# install or an arbitrary plugin URL.  This covers the upstream pluginUrl
# install knob as well as its container-facing environment forms.
while IFS='=' read -r name _; do
  case "$name" in
    GF_INSTALL_PLUGINS*|GF_PLUGIN_URL*|GF_PLUGINS_PLUGIN_URL*|\
    GF_PLUGINS_PREINSTALL|GF_PLUGINS_PREINSTALL_SYNC|GF_PLUGINS_PREINSTALL_URL*)
      echo "${name} is disabled in the self-contained Grafana image" >&2
      exit 1
      ;;
  esac
done <<EOF
$(env)
EOF

export HOME="${GF_PATHS_HOME}"

exec /usr/share/grafana/bin/grafana server \
  --homepath="${GF_PATHS_HOME}" \
  --config="${GF_PATHS_CONFIG}" \
  --packaging=docker \
  "$@" \
  cfg:default.log.mode="console" \
  cfg:default.paths.data="${GF_PATHS_DATA}" \
  cfg:default.paths.logs="${GF_PATHS_LOGS}" \
  cfg:default.paths.plugins="${GF_PATHS_PLUGINS}" \
  cfg:default.paths.provisioning="${GF_PATHS_PROVISIONING}"
