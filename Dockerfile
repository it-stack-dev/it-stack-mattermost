# Dockerfile — IT-Stack MATTERMOST wrapper
# Module 07 | Category: collaboration | Phase: 2
# Base image: mattermost/mattermost-team-edition:9

FROM mattermost/mattermost-team-edition:9

# Labels
LABEL org.opencontainers.image.title="it-stack-mattermost" \
      org.opencontainers.image.description="Mattermost team messaging" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-mattermost"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/mattermost/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
