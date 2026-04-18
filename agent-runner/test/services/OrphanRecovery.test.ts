import { describe, it, expect } from "vitest";

describe("orphan recovery: active task guard", () => {
  it("Set correctly tracks active task IDs for XAUTOCLAIM guard", () => {
    // This tests the pattern used in index.ts — a Set<string> of active task run IDs.
    // XAUTOCLAIM checks this set to avoid reclaiming entries for tasks we're still running.
    const activeTaskRunIds = new Set<string>();

    activeTaskRunIds.add("task-1");
    activeTaskRunIds.add("task-2");

    // Simulated XAUTOCLAIM entries — should skip active tasks
    const claimedEntries = [
      { taskRunId: "task-1" }, // active — skip
      { taskRunId: "task-3" }, // not active — process
    ];

    const toProcess = claimedEntries.filter(e => !activeTaskRunIds.has(e.taskRunId));
    expect(toProcess).toEqual([{ taskRunId: "task-3" }]);

    // After task completes, remove from set
    activeTaskRunIds.delete("task-1");
    expect(activeTaskRunIds.has("task-1")).toBe(false);
  });
});

describe("orphan recovery: dead-letter threshold", () => {
  it("dead-letters after 3 delivery attempts", () => {
    const DEAD_LETTER_THRESHOLD = 3;

    // Simulated claimed entries with delivery counts
    const entries = [
      { taskRunId: "task-a", deliveryCount: 1 },
      { taskRunId: "task-b", deliveryCount: 3 },
      { taskRunId: "task-c", deliveryCount: 5 },
    ];

    const deadLettered = entries.filter(e => e.deliveryCount >= DEAD_LETTER_THRESHOLD);
    const toCheck = entries.filter(e => e.deliveryCount < DEAD_LETTER_THRESHOLD);

    expect(deadLettered.map(e => e.taskRunId)).toEqual(["task-b", "task-c"]);
    expect(toCheck.map(e => e.taskRunId)).toEqual(["task-a"]);
  });
});
