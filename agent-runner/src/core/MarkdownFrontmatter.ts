/**
 * Parsers for the YAML frontmatter that Rails' markdown layout wraps every page
 * response in. Used by McpClient to extract the per-page action list and the
 * server-resolved path from a `fetch_page` result.
 *
 * Rails emits this frontmatter with a standard YAML emitter (Psych) and it is
 * meant to be read by any standard YAML client, so we parse it with a real YAML
 * parser. An earlier version grep-and-sliced the text, which coupled us to the
 * exact whitespace/quoting Rails happened to produce; a real parser reads
 * whatever valid YAML the server emits (quoted paths, column-0 or indented
 * sequences, block scalars) the same way an external client would.
 */
import { parse as parseYaml } from "yaml";

interface Frontmatter {
  readonly path?: unknown;
  readonly actions?: unknown;
}

/**
 * Extract and parse the YAML frontmatter block that opens a markdown response.
 * The block is fenced by a leading `---\n` and the next `\n---\n` (matching Ruby
 * MarkdownUiService#parse_frontmatter). Returns the parsed mapping, or null when
 * there is no frontmatter block, it is not valid YAML, or it is not a mapping.
 */
function parseFrontmatter(content: string): Frontmatter | null {
  if (!content.startsWith("---\n")) return null;
  const endIndex = content.indexOf("\n---\n", 4);
  if (endIndex === -1) return null;

  const block = content.slice(4, endIndex);
  try {
    const parsed: unknown = parseYaml(block);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return null;
    }
    return parsed as Frontmatter;
  } catch {
    return null;
  }
}

/**
 * Parse the available action names from a markdown response's frontmatter.
 * Returns the ordered list of `actions[].name` values, skipping entries without
 * a usable name. Empty when there is no frontmatter or no actions.
 */
export function parseAvailableActions(content: string): readonly string[] {
  const frontmatter = parseFrontmatter(content);
  if (frontmatter === null || !Array.isArray(frontmatter.actions)) return [];

  const names: string[] = [];
  for (const action of frontmatter.actions) {
    if (action === null || typeof action !== "object") continue;
    const name: unknown = (action as { name?: unknown }).name;
    if (typeof name === "string" && name.trim() !== "") {
      names.push(name.trim());
    }
  }
  return names;
}

/**
 * Extract the server-resolved `path` from a markdown response's frontmatter.
 * The server follows redirects internally; this is the path it actually landed
 * on. Returns null when there is no frontmatter or no string `path`.
 */
export function parseResolvedPath(content: string): string | null {
  const frontmatter = parseFrontmatter(content);
  if (frontmatter === null) return null;
  const path: unknown = frontmatter.path;
  return typeof path === "string" && path.trim() !== "" ? path : null;
}
