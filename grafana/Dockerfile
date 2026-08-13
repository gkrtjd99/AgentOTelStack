# Grafana image with the VictoriaLogs datasource baked in at build time.
# The release URL and digest are intentionally explicit so runtime startup has
# no network/plugin installation dependency.
# Pin the multi-arch release manifest; keeping the digest here makes rebuilds
# reproducible and prevents an unreviewed tag update.
FROM grafana/grafana@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43 AS plugin

USER root

ADD https://github.com/VictoriaMetrics/victorialogs-datasource/releases/download/v0.31.0/victoriametrics-logs-datasource-v0.31.0.tar.gz /tmp/victorialogs-datasource.tar.gz
RUN printf '%s  %s\n' '6b6d7b27354ad972946318aac2a54f04363375e7cd5d1cad9d3bb74d00eb970b' /tmp/victorialogs-datasource.tar.gz > /tmp/victorialogs-datasource.sha256 \
    && sha256sum -c /tmp/victorialogs-datasource.sha256 \
    # Keep plugins outside /var/lib/grafana: the latter is intentionally backed
    # by the persistent data volume in compose and would mask baked plugins.
    && mkdir -p /opt/grafana-plugins \
    && tar -xzf /tmp/victorialogs-datasource.tar.gz -C /opt/grafana-plugins \
    && test -f /opt/grafana-plugins/victoriametrics-logs-datasource/plugin.json \
    && chown -R 472:0 /opt/grafana-plugins \
    && chmod -R a=rX /opt/grafana-plugins \
    # Restore execute permission for the platform backend binaries after the
    # read-only hardening above.
    && chmod 0555 /opt/grafana-plugins/victoriametrics-logs-datasource/*_linux_* \
    && rm -f /tmp/victorialogs-datasource.tar.gz /tmp/victorialogs-datasource.sha256
USER 472

FROM grafana/grafana@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43

COPY --from=plugin --chown=472:0 /opt/grafana-plugins /opt/grafana-plugins
# Keep the exact upstream identity in the image metadata.  The Trivy waiver
# gate checks this label on the locally-built image; the local Compose name is
# intentionally not treated as Grafana's upstream identity.
LABEL org.opencontainers.image.base.name="grafana/grafana" \
      org.opencontainers.image.base.digest="sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43"
# Grafana 12 enables external core-plugin management by default. Keep this
# image self-contained: only the verified plugin above may be loaded, and no
# startup catalog/preinstall/update fetch is needed for this stack.
USER root
RUN printf '%s\n' '[feature_toggles]' 'externalCorePlugins = false' '[plugins]' 'plugin_admin_enabled = false' 'plugin_catalog_url =' 'public_key_retrieval_disabled = true' 'public_key_retrieval_on_startup = false' 'preinstall =' 'preinstall_sync =' 'preinstall_disabled = true' 'preinstall_auto_update = false' '[analytics]' 'check_for_updates = false' 'check_for_plugin_updates = false' > /etc/grafana/grafana.ini \
    && chown 472:0 /etc/grafana/grafana.ini \
    && chmod 0444 /etc/grafana/grafana.ini
USER 472
ENV GF_PATHS_PLUGINS=/opt/grafana-plugins
ENV GF_PLUGINS_PREINSTALL_SYNC=""
ENV GF_PLUGINS_PREINSTALL_DISABLED="true"
ENV GF_PLUGINS_PLUGIN_ADMIN_ENABLED="false"
ENV GF_PLUGINS_PUBLIC_KEY_RETRIEVAL_DISABLED="true"
ENV GF_ANALYTICS_CHECK_FOR_UPDATES="false"
ENV GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES="false"
