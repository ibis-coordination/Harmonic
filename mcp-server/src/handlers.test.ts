import { describe, it, expect, vi, beforeEach } from "vitest";
import { handleFetchPage, handleExecuteAction, handleSearch, handleGetHelp, type Config } from "./handlers.js";

// Helper to create a mock fetch response
function mockFetch(status: number, body: string): typeof fetch {
  return vi.fn().mockResolvedValue({
    ok: status >= 200 && status < 300,
    status,
    text: () => Promise.resolve(body),
  });
}

describe("handleFetchPage", () => {
  let config: Config;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
  });

  it("returns error when API token is not set", async () => {
    config.apiToken = undefined;
    const result = await handleFetchPage("/collectives/team", config);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HARMONIC_API_TOKEN");
  });

  it("fetches markdown from the server", async () => {
    const mockFn = mockFetch(200, "# Collective Page\n\nWelcome!");
    const result = await handleFetchPage("/collectives/team", config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/collectives/team",
      expect.objectContaining({
        method: "GET",
        headers: expect.objectContaining({
          Accept: "text/markdown",
          Authorization: "Bearer test-token",
        }),
      })
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toBe("# Collective Page\n\nWelcome!");
  });

  it("normalizes paths without leading slash", async () => {
    const mockFn = mockFetch(200, "content");
    await handleFetchPage("collectives/team", config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/collectives/team",
      expect.anything()
    );
  });

  it("returns error on HTTP failure", async () => {
    const mockFn = mockFetch(404, "Not found");
    const result = await handleFetchPage("/collectives/nonexistent", config, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 404");
  });

  it("returns error on network failure", async () => {
    const mockFn = vi.fn().mockRejectedValue(new Error("Network error"));
    const result = await handleFetchPage("/collectives/team", config, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Network error");
  });
});

describe("handleExecuteAction", () => {
  let config: Config;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
  });

  it("works without any prior fetch_page call", async () => {
    // Statelessness check: the handler depends only on the passed path,
    // never on a remembered cursor.
    const mockFn = mockFetch(200, "Note created");
    const result = await handleExecuteAction(
      "/collectives/team",
      "create_note",
      { text: "hi" },
      config,
      mockFn
    );

    expect(result.isError).toBeUndefined();
  });

  it("returns error when API token is not set", async () => {
    config.apiToken = undefined;
    const result = await handleExecuteAction("/collectives/team", "create_note", {}, config);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HARMONIC_API_TOKEN");
  });

  it("posts to {path}/actions/{action} built from the passed path", async () => {
    const mockFn = mockFetch(200, "Note created successfully");
    const params = { title: "Test", text: "Content" };
    const result = await handleExecuteAction(
      "/collectives/team",
      "create_note",
      params,
      config,
      mockFn
    );

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/collectives/team/actions/create_note",
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
    await handleExecuteAction("/collectives/team", "join", undefined, config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      expect.anything(),
      expect.objectContaining({
        body: "{}",
      })
    );
  });

  it("returns error on HTTP failure (e.g. 422 validation)", async () => {
    const mockFn = mockFetch(422, "Validation failed");
    const result = await handleExecuteAction(
      "/collectives/team",
      "create_note",
      {},
      config,
      mockFn
    );

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 422");
  });

  it("returns error on 404 (unknown action) with the teaching-error body", async () => {
    // Rails returns 404 with available-actions list when the action name
    // doesn't match. The handler should pass that body through as isError.
    const teachingBody =
      "# Unknown Action\n\n`bogus` is not a valid action at `/collectives/team`.\n\n## Available actions\n\n- ...";
    const mockFn = mockFetch(404, teachingBody);
    const result = await handleExecuteAction("/collectives/team", "bogus", {}, config, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 404");
    expect(result.content[0].text).toContain("Available actions");
  });

  it("returns error on network failure", async () => {
    const mockFn = vi.fn().mockRejectedValue(new Error("Connection refused"));
    const result = await handleExecuteAction(
      "/collectives/team",
      "create_note",
      {},
      config,
      mockFn
    );

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Connection refused");
  });

  it("strips /actions/<name> suffix when the agent passes an action URL as path", async () => {
    // The agent might copy an action URL verbatim from a page response;
    // we tolerate that rather than producing /foo/actions/x/actions/x.
    const mockFn = mockFetch(200, "Notification marked as read");
    const result = await handleExecuteAction(
      "/notifications/actions/mark_read",
      "mark_read",
      { id: "123" },
      config,
      mockFn
    );

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/notifications/actions/mark_read",
      expect.anything()
    );
    expect(result.isError).toBeUndefined();
  });

  it("strips /actions suffix (without trailing slash)", async () => {
    const mockFn = mockFetch(200, "Notification marked as read");
    await handleExecuteAction(
      "/notifications/actions",
      "mark_read",
      { id: "123" },
      config,
      mockFn
    );

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/notifications/actions/mark_read",
      expect.anything()
    );
  });

  it("normalizes path without leading slash", async () => {
    const mockFn = mockFetch(200, "ok");
    await handleExecuteAction("collectives/team", "create_note", { text: "x" }, config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/collectives/team/actions/create_note",
      expect.anything()
    );
  });

  it("truncates oversized error bodies to keep the agent's context manageable", async () => {
    const huge = "x".repeat(5000);
    const mockFn = mockFetch(422, huge);
    const result = await handleExecuteAction("/p", "a", {}, config, mockFn);

    expect(result.isError).toBe(true);
    // Bound generously: header + 2000 chars of body. Should be far below the
    // raw 5000-char body but still include enough for the agent to understand.
    expect(result.content[0].text.length).toBeLessThan(2200);
    expect(result.content[0].text.length).toBeGreaterThan(1900);
  });

  it("strips ?query string from path before constructing action URL", async () => {
    // After fetching a comment-context URL like /d/abc?comment_id=xyz,
    // the action URL is on the bare resource path — concatenating
    // /actions/<name> after the query produces a malformed URL.
    const mockFn = mockFetch(200, "Comment added");
    await handleExecuteAction(
      "/d/abc?comment_id=xyz",
      "add_comment",
      { text: "hi", replying_to_id: "xyz" },
      config,
      mockFn
    );

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/d/abc/actions/add_comment",
      expect.anything()
    );
  });
});

describe("handleSearch", () => {
  let config: Config;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
  });

  it("delegates to fetch_page with search URL", async () => {
    const mockFn = mockFetch(200, "# Search Results\n\n- Note: Test note");
    const result = await handleSearch("type:note status:open", config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/search?q=type%3Anote%20status%3Aopen",
      expect.objectContaining({ method: "GET" })
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("Search Results");
  });

  it("passes through errors", async () => {
    config.apiToken = undefined;
    const result = await handleSearch("test", config);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HARMONIC_API_TOKEN");
  });
});

describe("handleGetHelp", () => {
  let config: Config;

  beforeEach(() => {
    config = { baseUrl: "http://localhost:3000", apiToken: "test-token" };
  });

  it("delegates to fetch_page with help URL", async () => {
    const mockFn = mockFetch(200, "# Decisions\n\nAcceptance voting...");
    const result = await handleGetHelp("decisions", config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/help/decisions",
      expect.objectContaining({ method: "GET" })
    );
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("Decisions");
  });

  it("encodes topic with special characters", async () => {
    const mockFn = mockFetch(200, "# Help");
    await handleGetHelp("reminder-notes", config, mockFn);

    expect(mockFn).toHaveBeenCalledWith(
      "http://localhost:3000/help/reminder-notes",
      expect.anything()
    );
  });

  it("passes through errors", async () => {
    const mockFn = mockFetch(404, "Not found");
    const result = await handleGetHelp("nonexistent", config, mockFn);

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("HTTP 404");
  });
});
