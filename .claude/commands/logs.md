# Application Logs

Tail application logs from Docker containers.

## Usage

- `/logs` - Tail all container logs
- `/logs web` - Tail only the web container logs
- `/logs js` - Tail only the JavaScript container logs
- `/logs db` - Tail only the database container logs

## Instructions

1. Parse the argument `$ARGUMENTS`:
   - If empty, run: `docker compose logs -f --tail=100`
   - If a service name is provided, run: `docker compose logs -f --tail=100 <service>`

2. Execute the command using Bash with `run_in_background: true` since this is a streaming command

3. Inform the user how to stop the logs (Ctrl+C or they can ask you to stop it)

## Examples

```bash
# All logs
docker compose logs -f --tail=100

# Web container only
docker compose logs -f --tail=100 web

# JavaScript container only
docker compose logs -f --tail=100 js
```
