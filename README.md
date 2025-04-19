# Harmonic Team

[Harmonic Team](https://harmonic.team) is group coordination software based on 3 main data types:

1. Notes (group knowledge)
2. Decisions (group decisions)
3. Commitments (group action)

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
