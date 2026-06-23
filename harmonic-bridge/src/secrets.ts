// Secret resolution for harmonic-bridge.
//
// References look like <scheme>://<body> (e.g. op://Personal/foo/bar,
// file:///etc/harmonic-bridge/token). For a given reference, harmonic-bridge looks up the
// scheme in the resolver map, substitutes the body into the template,
// shells out, and uses stdout as the secret. Resolvers run at wake time
// only — secrets never get written to disk by harmonic-bridge, never logged, never
// passed to the resolver subprocess (the resolver receives the reference
// body, not the secret).

import { exec } from "node:child_process";
import { promisify } from "node:util";

const execAsync = promisify(exec);

export class SecretError extends Error {
  override readonly name = "SecretError";
}

export interface SecretReference {
  readonly scheme: string;
  readonly body: string;
}

const REFERENCE_RE = /^([a-z][a-z0-9+\-.]*):\/\/(.+)$/i;

// Matches placeholder tokens in resolver command templates: {path}, {name},
// {ref}, etc. The name inside the braces is purely documentary — any
// matching identifier is replaced with the reference body, so README
// examples like "op read {ref}" and "printenv {name}" both work without
// harmonic-bridge needing to know the conventional names for each resolver.
const PLACEHOLDER_RE = /\{[a-z_][a-z0-9_]*\}/gi;

export function parseReference(value: string): SecretReference | null {
  const m = REFERENCE_RE.exec(value);
  if (!m) return null;
  const scheme = m[1];
  const body = m[2];
  if (!scheme || !body) return null;
  return { scheme, body };
}

export async function resolveSecret(
  reference: string,
  resolvers: Readonly<Record<string, string>>,
): Promise<string> {
  const parsed = parseReference(reference);
  if (!parsed) {
    throw new SecretError(`"${reference}" is not a secret reference (expected scheme://body)`);
  }

  const template = resolvers[parsed.scheme];
  if (!template) {
    throw new SecretError(`no resolver configured for scheme "${parsed.scheme}"`);
  }

  const command = template.replace(PLACEHOLDER_RE, parsed.body);

  try {
    const { stdout } = await execAsync(command);
    return stdout.replace(/\n+$/, "");
  } catch (e) {
    const detail = e instanceof Error ? e.message : String(e);
    throw new SecretError(`resolver for "${parsed.scheme}" failed: ${detail}`);
  }
}
