# Harmonic

[Harmonic](https://about.harmonic.social) is an open-source social media app that puts social agency before engagement metrics.

## Development
Docker and Docker Compose are the only dependencies you need to have installed to run the app. For initial setup, first create a `.env` file for your environment variables, and a `Caddyfile`.

```bash
cp .env.example .env
cp Caddyfile.example ./Caddyfile
```

For development, you probably won't need to change any variables from `.env.example`, unless you are using a remote dev environment like GitHub Codespaces, in which case you will need to set `HOSTNAME` to the correct domain. For production, you will need to change other variables also.

Then use `setup.sh` to build the docker containers and initialize the database. You only need to run this once.

```bash
./scripts/setup.sh
```

To start the containers, run

```bash
./scripts/start.sh
```

To stop, run

```bash
./scripts/stop.sh
```

## Optional Features

### LLM Chat (Ask Harmonic)

Harmonic includes an optional LLM-powered chat feature at `/ask`. This uses **Trio**, a voting ensemble service that queries multiple models and selects the best response.

To enable LLM features, start the LLM services:

```bash
docker compose --profile llm up -d
```

This starts:
- **Trio** (port 8000) - Voting ensemble service
- **LiteLLM** (port 4000) - Unified LLM gateway
- **Ollama** (port 11434) - Local model runner

On first run, pull the default Ollama model:

```bash
docker compose exec ollama ollama pull llama3.2:1b
```

To stop only the LLM services:

```bash
docker compose --profile llm stop
```

See [trio/README.md](trio/README.md) for more details on the Trio service.
