/**
 * Parsers for YAML-flavored frontmatter that Rails' markdown layout wraps
 * every page response in. Used by McpClient to extract per-page action lists
 * and the server-resolved path from a `fetch_page` result.
 *
 * These are deliberately small grep-and-slice parsers rather than a full YAML
 * implementation — the frontmatter shape we emit is fixed and predictable, so
 * a real parser would be over-engineered (and would force a runtime dep).
 */

/**
 * Parse available action names from the markdown response's YAML frontmatter.
 * Matches Ruby MarkdownUiService.parse_frontmatter + actions extraction.
 *
 * The Rails markdown layout wraps every response in frontmatter:
 *   ---
 *   actions:
 *     - name: create_note
 *       description: Create a note
 *       ...
 *   ---
 */
export function parseAvailableActions(content: string): readonly string[] {
  // Must start with "---\n" (matches Ruby: content.start_with?("---\n"))
  if (!content.startsWith("---\n")) return [];

  // Find closing "---\n" after position 4 (matches Ruby: content.index("\n---\n", 4))
  const endIndex = content.indexOf("\n---\n", 4);
  if (endIndex === -1) return [];

  const frontmatter = content.slice(4, endIndex);

  // Parse action names from the YAML frontmatter.
  // We don't use a full YAML parser — just extract "- name: <value>" lines
  // within the "actions:" block.
  const actionsMatch = /^actions:\s*$/m.exec(frontmatter);
  if (actionsMatch === null) return [];

  const actionsBlock = frontmatter.slice(actionsMatch.index + actionsMatch[0].length);
  const names: string[] = [];

  for (const line of actionsBlock.split("\n")) {
    // Stop if we hit a non-indented line (next top-level YAML key)
    if (line.length > 0 && !line.startsWith(" ") && !line.startsWith("\t")) break;

    // Match only top-level action items (2-space indent: "  - name: value")
    // Skip deeper nested "name:" like params (6+ spaces)
    const nameMatch = /^  - name:\s*(.+)$/.exec(line);
    if (nameMatch?.[1] !== undefined) {
      const name = nameMatch[1].trim();
      if (name !== "") names.push(name);
    }
  }

  return names;
}

/**
 * Extract a `path: …` value from a markdown response's YAML frontmatter.
 * Used to resolve the path the server actually landed on (the server follows
 * redirects internally; we don't see hop-by-hop).
 *
 * Returns null if there's no frontmatter or no `path:` line in it.
 */
export function parseResolvedPath(content: string): string | null {
  if (!content.startsWith("---\n")) return null;
  const endIndex = content.indexOf("\n---\n", 4);
  if (endIndex === -1) return null;
  const frontmatter = content.slice(4, endIndex);
  const match = /^path:\s*(.+)$/m.exec(frontmatter);
  return match?.[1]?.trim() ?? null;
}
