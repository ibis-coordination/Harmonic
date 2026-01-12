import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleNavigate, handleExecuteAction, createState, type Config, type State } from "./handlers.js";

// Helper to create a mock fetch response
function mockFetch(status: number, body: string): typeof fetch {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    text: () => Promise.resolve(body),
  });
}

describe("handleNavigate", () => {
  let config: Config;
  let state: State;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
    state = createState();
  });

  it("returns error when API token is not set", async () => {
    config.apiToken = undefined;
    const result = await handleNavigate("/studios/team", config, state);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HARMONIC_API_TOKEN");
  });

  it("fetches markdown from the server", async () => {
    const mockFn = mockFetch(200, "# Studio Page\n\nWelcome!");
    const result = await handleNavigate("/studios/team", config, state, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/studios/team",
      expect.objectContaining({
        method: "GET",
        headers: expect.objectContaining({
          Accept: "text/markdown",
          Authorization: "Bearer test-token",
        }),
      })
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toBe("# Studio Page\n\nWelcome!");
  });

  it("normalizes paths without leading slash", async () => {
    const mockFn = mockFetch(200, "content");
    await handleNavigate("studios/team", config, state, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/studios/team",
      expect.anything()
    );
  });

  it("updates state.currentPath on success", async () => {
    const mockFn = mockFetch(200, "content");
    await handleNavigate("/studios/team", config, state, mockFn);

    expect(state.currentPath).toBe("/studios/team");
  });

  it("returns error on HTTP failure", async () => {
    const mockFn = mockFetch(404, "Not found");
    const result = await handleNavigate("/studios/nonexistent", config, state, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 404");
  });

  it("returns error on network failure", async () => {
    const mockFn = vi.fn().mockRejectedValue(new Error("Network error"));
    const result = await handleNavigate("/studios/team", config, state, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Network error");
  });
});

describe("handleExecuteAction", () => {
  let config: Config;
  let state: State;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
    state = createState();
    state.currentPath = "/studios/team";
  });

  it("returns error when no current path", async () => {
    state.currentPath = null;
    const result = await handleExecuteAction("create_note", {}, config, state);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("navigate");
  });

  it("returns error when API token is not set", async () => {
    config.apiToken = undefined;
    const result = await handleExecuteAction("create_note", {}, config, state);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HARMONIC_API_TOKEN");
  });

  it("posts to the action endpoint", async () => {
    const mockFn = mockFetch(200, "Note created successfully");
    const params = { title: "Test", text: "Content" };
    const result = await handleExecuteAction("create_note", params, config, state, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/studios/team/actions/create_note",
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({
          Accept: "text/markdown",
          "Content-Type": "application/json",
          Authorization: "Bearer test-token",
        }),
        body: JSON.stringify(params),
      })
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toBe("Note created successfully");
  });

  it("handles undefined params", async () => {
    const mockFn = mockFetch(200, "Success");
    await handleExecuteAction("join", undefined, config, state, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        body: "{}",
      })
    );
  });

  it("returns error on HTTP failure", async () => {
    const mockFn = mockFetch(422, "Validation failed");
    const result = await handleExecuteAction("create_note", {}, config, state, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 422");
  });

  it("returns error on network failure", async () => {
    const mockFn = vi.fn().mockRejectedValue(new Error("Connection refused"));
    const result = await handleExecuteAction("create_note", {}, config, state, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Connection refused");
  });

  it("strips /actions/ suffix from path when constructing action URL", async () => {
    // When user navigates to an action description page, currentPath includes /actions/
    state.currentPath = "/notifications/actions/mark_read";
    const mockFn = mockFetch(200, "Notification marked as read");
    const result = await handleExecuteAction("mark_read", { id: "123" }, config, state, mockFn);

    // Should POST to /notifications/actions/mark_read, not /notifications/actions/mark_read/actions/mark_read
    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/notifications/actions/mark_read",
      expect.anything()
    );
    expect(result.isError).toBeUndefined();
  });

  it("handles action execution from nested action path", async () => {
    // When on /studios/team/note/actions/create_note, executing create_note should work
    state.currentPath = "/studios/team/note/actions/create_note";
    const mockFn = mockFetch(200, "Note created");
    await handleExecuteAction("create_note", { text: "test" }, config, state, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/studios/team/note/actions/create_note",
      expect.anything()
    );
  });

  it("strips /actions suffix (without trailing slash) from path", async () => {
    // When user navigates to the actions index page
    state.currentPath = "/notifications/actions";
    const mockFn = mockFetch(200, "Notification marked as read");
    await handleExecuteAction("mark_read", { id: "123" }, config, state, mockFn);

    // Should POST to /notifications/actions/mark_read, not /notifications/actions/actions/mark_read
    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/notifications/actions/mark_read",
      expect.anything()
    );
  });
});

describe("createState", () => {
  it("creates state with null currentPath", () => {
    const state = createState();
    expect(state.currentPath).toBeNull();
  });
});
