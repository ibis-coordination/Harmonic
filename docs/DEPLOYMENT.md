# Deployment Guide

## Production Deployment

Production uses pre-built Docker images from GitHub Container Registry. No source code needed on the server.

### Server Setup (One-Time)

```
/opt/harmonic/
├── docker-compose.yml    # copy of docker-compose.production.yml
├── .env                  # your configuration
└── Caddyfile             # reverse proxy config
```

### Release Workflow

```bash
# On your dev machine
git push origin main
git tag v1.2.3
git push --tags
# CI builds and publishes image (~5 min)
```

### Deploy

```bash
docker compose pull
docker compose up -d
docker compose exec web bundle exec rails db:migrate  # if needed
```

### Rollback

```bash
# Edit docker-compose.yml to pin version:
# image: ghcr.io/ibis-coordination/harmonic:v1.2.2
docker compose pull
docker compose up -d
```

## Environment Variables

See `.env.example` for all required variables. Key ones:

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `REDIS_URL` | Redis connection string |
| `SECRET_KEY_BASE` | Rails secret (generate with `openssl rand -hex 64`) |
| `HOSTNAME` | Your domain (e.g., `harmonic.example.com`) |

## Troubleshooting

### Migrations Not Applied

```bash
docker compose exec web bundle exec rails db:migrate
```

### View Logs

```bash
docker compose logs web --tail 100
docker compose logs sidekiq --tail 100
```
