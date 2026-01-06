# Documentation

This directory contains project documentation.

## Contents

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture, data model, and request flow
- [API.md](API.md) - REST API documentation with endpoints, request/response formats, and examples
- [KNOWN_BUGS.md](KNOWN_BUGS.md) - Known bugs discovered during testing with reproduction steps
- [TODO_INDEX.md](TODO_INDEX.md) - Categorized index of all TODO comments in the codebase
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
