# Architecture — IT-Stack MATTERMOST

## Overview

Mattermost is the team chat platform, replacing Slack/Teams with full SSO via Keycloak OIDC.

## Role in IT-Stack

- **Category:** collaboration
- **Phase:** 2
- **Server:** lab-app1 (10.0.50.13)
- **Ports:** 8065 (HTTP)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → mattermost → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
