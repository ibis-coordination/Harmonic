import { describe, it, expect } from "vitest";
import { parseAvailableActions } from "../../src/services/HarmonicClient.js";

describe("parseAvailableActions", () => {
  it("parses action names from YAML frontmatter", () => {
    const content = `---
app: Harmonic
host: test.harmonic.local
path: /collectives/team
actions:
  - name: create_note
    description: Create a new note
    path: /collectives/team/actions/create_note
    params:
      - name: body
        type: string
        required: true
  - name: vote
    description: Cast a vote
    path: /collectives/team/actions/vote
---
nav: | [Home](/) |

# Team Collective
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["create_note", "vote"]);
  });

  it("returns empty array when no frontmatter", () => {
    const content = "# Just a page\n\nSome content here.";
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("returns empty array for empty content", () => {
    expect(parseAvailableActions("")).toEqual([]);
  });

  it("returns empty array when frontmatter has no actions", () => {
    const content = `---
app: Harmonic
host: test.harmonic.local
path: /whoami
---
# About You
`;
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("handles frontmatter with single action", () => {
    const content = `---
actions:
  - name: send_heartbeat
    description: Send heartbeat
---
# Page
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["send_heartbeat"]);
  });

  it("ignores actions without name field", () => {
    const content = `---
actions:
  - name: valid_action
    description: Valid
  - description: No name field
  - name: another_valid
    description: Also valid
---
# Page
`;
    const actions = parseAvailableActions(content);
    expect(actions).toEqual(["valid_action", "another_valid"]);
  });

  it("handles malformed YAML gracefully", () => {
    const content = `---
actions: [not valid yaml
---
# Page
`;
    // Should not throw, return empty
    expect(parseAvailableActions(content)).toEqual([]);
  });

  it("does not confuse horizontal rules for frontmatter", () => {
    const content = `# Page Title

Some content

---

More content after rule
`;
    expect(parseAvailableActions(content)).toEqual([]);
  });
});
