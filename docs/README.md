# Documentation

This directory contains project documentation.

## Contents

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture, data model, and request flow
- `API.md` - API documentation (TODO)
- `erd.pdf` - Entity-Relationship Diagram (generate with `./scripts/generate-erd.sh`)

## Generating the ERD

After running `bundle install`, generate an ERD diagram:

```bash
# From within the Docker container
bundle exec erd

# Or using the bash script
./scripts/bash-web.sh
bundle exec erd
```

This creates `erd.pdf` in the project root. Move it to this directory for reference.
