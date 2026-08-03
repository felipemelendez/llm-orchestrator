// Validate a Claude Code workflow script: its `export const meta` literal AND
// the syntax of the whole script.
//
// TWO defects this replaces, both of which made the validator unable to fail.
//
// 1. `node --check <file.js>` returns 0 on invalid syntax whenever the file
//    contains `export` (node parses it as ESM), and this validator REQUIRES
//    every workflow to begin with `export const meta`. Measured on v24.10.0:
//    garbage alone -> rc=1; the same garbage under an `export` line -> rc=0.
//
// 2. The meta check was `[[ "$first" == export\ const\ meta* ]]`, a trailing
//    glob that accepted `export const metadata`, `meta = 42`, and a meta with
//    no `name:`.
//
// Checking a `.mjs` copy fixes (1) but is the WRONG GRAMMAR: a workflow script
// legitimately uses top-level `return` and top-level `await`, which are
// illegal in an ES module but legal in an async function body — the shape the
// Workflow engine actually runs. So the script is compiled as an async
// function body, with the meta export rewritten to a plain const. That accepts
// exactly what the engine accepts and rejects real syntax errors.
//
// COMPILED, NEVER CALLED: the AsyncFunction constructor parses the body and
// returns; nothing in the script runs. The meta OBJECT LITERAL alone is
// evaluated, which is how purity is enforced — a variable, call, or spread
// inside it throws exactly where the rule says it should.
//
// Usage: node check-workflow-script.mjs <file.js>
// Exit 0 = valid; exit 1 with a one-line reason on stderr.

import { readFileSync } from "node:fs";

const file = process.argv[2];
if (!file) {
  process.stderr.write("usage: check-workflow-meta.mjs <file.js>\n");
  process.exit(1);
}

const src = readFileSync(file, "utf8");

const declMatch = src.match(/export\s+const\s+meta\s*=\s*/);
if (!declMatch) {
  process.stderr.write("no 'export const meta =' declaration found\n");
  process.exit(1);
}

const start = declMatch.index + declMatch[0].length;
if (src[start] !== "{") {
  process.stderr.write(
    `meta must be an object literal, got: ${src.slice(start, start + 20).trim()}\n`,
  );
  process.exit(1);
}

// Walk to the matching close brace, honouring strings, template literals, and
// comments so a `}` inside any of them does not end the object early.
let depth = 0, i = start, end = -1, quote = null, inLine = false, inBlock = false;
for (; i < src.length; i++) {
  const c = src[i], next = src[i + 1];
  if (inLine) { if (c === "\n") inLine = false; continue; }
  if (inBlock) { if (c === "*" && next === "/") { inBlock = false; i++; } continue; }
  if (quote) {
    if (c === "\\") { i++; continue; }
    if (c === quote) quote = null;
    continue;
  }
  if (c === "/" && next === "/") { inLine = true; i++; continue; }
  if (c === "/" && next === "*") { inBlock = true; i++; continue; }
  if (c === '"' || c === "'" || c === "`") { quote = c; continue; }
  if (c === "{") depth++;
  else if (c === "}") { depth--; if (depth === 0) { end = i; break; } }
}
if (end === -1) {
  process.stderr.write("meta object literal is not closed\n");
  process.exit(1);
}

const literal = src.slice(start, end + 1);

let meta;
try {
  // Strict mode so an undeclared identifier is a ReferenceError rather than a
  // silent global read. Any call/variable/spread inside the literal fails here.
  meta = Function('"use strict"; return (' + literal + ");")();
} catch (err) {
  process.stderr.write(
    `meta is not a pure literal (${err.constructor.name}: ${err.message})\n`,
  );
  process.exit(1);
}

if (typeof meta !== "object" || meta === null || Array.isArray(meta)) {
  process.stderr.write(`meta must be an object, got ${typeof meta}\n`);
  process.exit(1);
}
for (const key of ["name", "description"]) {
  if (typeof meta[key] !== "string" || meta[key].trim() === "") {
    process.stderr.write(`meta.${key} must be a non-empty string\n`);
    process.exit(1);
  }
}
if (!/^[a-z0-9][a-z0-9-]*$/.test(meta.name)) {
  process.stderr.write(
    `meta.name must be lowercase kebab-case (it becomes the /<plugin>:<name> ` +
      `invocation), got: ${meta.name}\n`,
  );
  process.exit(1);
}
if (meta.phases !== undefined) {
  if (!Array.isArray(meta.phases)) {
    process.stderr.write("meta.phases must be an array when present\n");
    process.exit(1);
  }
  for (const p of meta.phases) {
    if (typeof p !== "object" || p === null || typeof p.title !== "string") {
      process.stderr.write("each meta.phases entry needs a string title\n");
      process.exit(1);
    }
  }
}

// --- syntax of the whole script, in the grammar the engine actually uses -----
// `export const meta = ` becomes `const meta = ` so the source is a valid
// function body; everything else is untouched, so reported line numbers stay
// aligned with the real file.
const asBody =
  src.slice(0, declMatch.index) +
  "const meta = " +
  src.slice(start);

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
try {
  new AsyncFunction(asBody); // compiles (parses) only — never invoked
} catch (err) {
  process.stderr.write(`syntax error: ${err.message}\n`);
  process.exit(1);
}
process.exit(0);
