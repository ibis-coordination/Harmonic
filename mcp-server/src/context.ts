import { readFileSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const contextPath = join(__dirname, "..", "CONTEXT.md");

export const CONTEXT_MARKDOWN = readFileSync(contextPath, "utf-8");
