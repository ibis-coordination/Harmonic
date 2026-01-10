# ERD Diagram

Generate an Entity-Relationship Diagram for the database schema.

## Usage

- `/erd` - Generate the ERD diagram

## Instructions

1. Run the ERD generation script:
   ```bash
   ./scripts/generate-erd.sh
   ```

2. Inform the user where the generated diagram is located

3. Briefly describe the core domain models if helpful:
   - **Note** - Posts/content (Observe phase)
   - **Decision** - Acceptance voting (Decide phase)
   - **Commitment** - Action pledges with critical mass (Act phase)
   - **Cycle** - Time-bounded activity windows (Orient phase)
   - **Link** - Bidirectional references (Orient phase)
