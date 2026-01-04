# Documentation

This directory contains project documentation.

## Contents

- `ARCHITECTURE.md` - System architecture overview (TODO)
- `API.md` - API documentation (TODO)
- `DATA_MODEL.md` - Data model and relationships (TODO)
- `erd.pdf` - Entity-Relationship Diagram (generate with `bundle exec erd`)

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
