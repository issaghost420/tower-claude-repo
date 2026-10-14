#!/usr/bin/env node
/**
 * local-files-smart.js
 * Fork of @modelcontextprotocol/server-filesystem with automatic image resize.
 * Images over MAX_DIMENSION get downscaled before base64 encoding.
 * Prevents context-bombing the LLM with pixels it can't use anyway.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import fs from "fs/promises";
import path from "path";
import sharp from "sharp";
import os from "os";
import { execFile } from "child_process";
import { promisify } from "util";

// --- Config ---
const MAX_DIMENSION = 1024; // longest edge cap
const JPEG_QUALITY = 85;
const SQLITE_BIN = process.env.SQLITE3_BIN || "sqlite3";
const SQLITE_MAX_DB_BYTES = 1024 * 1024 * 1024; // refuse to snapshot dbs over 1GB
const SQLITE_MAX_OUTPUT_CHARS = 20000;
const IMAGE_EXTENSIONS = new Set([
  ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".tiff", ".tif", ".avif",
]);

// Allowed directories from CLI args
const allowedDirs = process.argv.slice(2).map((d) => path.resolve(d));
if (allowedDirs.length === 0) {
  console.error("Usage: local-files-smart.js <dir1> [dir2] ...");
  process.exit(1);
}

// --- Path security ---
async function resolveAndValidate(filePath) {
  const resolved = path.resolve(filePath);
  // Follow symlinks to get real path
  let real;
  try {
    real = await fs.realpath(resolved);
  } catch {
    // File might not exist yet (for write operations)
    real = resolved;
  }
  const allowed = allowedDirs.some(
    (dir) => real.startsWith(dir + path.sep) || real === dir
  );
  if (!allowed) {
    throw new Error(
      `Access denied: ${filePath} is outside allowed directories`
    );
  }
  return real;
}

// --- Image handling ---
function isImage(filePath) {
  return IMAGE_EXTENSIONS.has(path.extname(filePath).toLowerCase());
}

async function readImageResized(filePath) {
  const img = sharp(filePath);
  const meta = await img.metadata();
  const w = meta.width || 0;
  const h = meta.height || 0;

  let pipeline = img;
  if (w > MAX_DIMENSION || h > MAX_DIMENSION) {
    pipeline = pipeline.resize({
      width: MAX_DIMENSION,
      height: MAX_DIMENSION,
      fit: "inside",
      withoutEnlargement: true,
    });
  }

  const buf = await pipeline.jpeg({ quality: JPEG_QUALITY }).toBuffer();
  const b64 = buf.toString("base64");
  const resized = w > MAX_DIMENSION || h > MAX_DIMENSION;
  return {
    base64: b64,
    mimeType: "image/jpeg",
    originalSize: `${w}x${h}`,
    finalSize: resized
      ? `resized to fit ${MAX_DIMENSION}px`
      : `${w}x${h} (no resize needed)`,
  };
}

// --- File operations ---
async function readFile(filePath) {
  const resolved = await resolveAndValidate(filePath);

  if (isImage(resolved)) {
    const info = await readImageResized(resolved);
    return {
      content: [
        {
          type: "text",
          text: `[Image: ${path.basename(filePath)} | Original: ${info.originalSize} | ${info.finalSize}]`,
        },
        {
          type: "image",
          data: info.base64,
          mimeType: info.mimeType,
        },
      ],
    };
  }

  const content = await fs.readFile(resolved, "utf-8");
  return {
    content: [{ type: "text", text: content }],
  };
}

async function writeFile(filePath, content) {
  const resolved = await resolveAndValidate(filePath);
  await fs.writeFile(resolved, content, "utf-8");
  return { content: [{ type: "text", text: `Wrote ${filePath}` }] };
}

async function listDirectory(dirPath) {
  const resolved = await resolveAndValidate(dirPath);
  const entries = await fs.readdir(resolved, { withFileTypes: true });
  const lines = entries.map((e) => {
    const prefix = e.isDirectory() ? "[DIR]" : "[FILE]";
    return `${prefix} ${e.name}`;
  });
  return {
    content: [{ type: "text", text: lines.join("\n") }],
  };
}

async function directoryTree(dirPath, maxDepth = 3, currentDepth = 0) {
  if (currentDepth >= maxDepth) return [];
  const resolved = await resolveAndValidate(dirPath);
  const entries = await fs.readdir(resolved, { withFileTypes: true });
  const results = [];
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      const children = await directoryTree(full, maxDepth, currentDepth + 1);
      results.push({ name: entry.name, type: "directory", children });
    } else {
      results.push({ name: entry.name, type: "file" });
    }
  }
  return results;
}

async function moveFile(src, dest) {
  const resolvedSrc = await resolveAndValidate(src);
  const resolvedDest = await resolveAndValidate(dest);
  await fs.rename(resolvedSrc, resolvedDest);
  return {
    content: [{ type: "text", text: `Moved ${src} → ${dest}` }],
  };
}

async function searchFiles(dirPath, pattern, maxResults = 50) {
  const resolved = await resolveAndValidate(dirPath);
  const regex = new RegExp(pattern, "i");
  const results = [];

  async function walk(dir) {
    if (results.length >= maxResults) return;
    const entries = await fs.readdir(dir, { withFileTypes: true });
    for (const entry of entries) {
      if (results.length >= maxResults) return;
      const full = path.join(dir, entry.name);
      if (entry.name.startsWith(".") || entry.name === "node_modules") continue;
      if (regex.test(entry.name)) {
        results.push(full);
      }
      if (entry.isDirectory()) {
        await walk(full);
      }
    }
  }

  await walk(resolved);
  return {
    content: [
      {
        type: "text",
        text: results.length
          ? results.join("\n")
          : `No files matching "${pattern}" found`,
      },
    ],
  };
}

async function getFileInfo(filePath) {
  const resolved = await resolveAndValidate(filePath);
  const stat = await fs.stat(resolved);
  const info = {
    path: resolved,
    size: stat.size,
    modified: stat.mtime.toISOString(),
    created: stat.birthtime.toISOString(),
    isDirectory: stat.isDirectory(),
    isFile: stat.isFile(),
    permissions: `0${(stat.mode & 0o777).toString(8)}`,
  };
  return {
    content: [{ type: "text", text: JSON.stringify(info, null, 2) }],
  };
}

async function createFile(filePath, content) {
  const parent = path.dirname(path.resolve(filePath));
  // Validate the nearest existing ancestor's real path before mkdir, so a
  // symlinked dir can't get new dirs/files created outside allowed dirs
  let existing = parent;
  while (true) {
    try {
      await fs.access(existing);
      break;
    } catch {
      existing = path.dirname(existing);
    }
  }
  await resolveAndValidate(existing);
  await fs.mkdir(parent, { recursive: true });
  const target = path.join(await resolveAndValidate(parent), path.basename(filePath));
  try {
    // "wx" = O_CREAT|O_EXCL: the OS refuses if anything already exists at target
    await fs.writeFile(target, content, { encoding: "utf-8", flag: "wx" });
  } catch (err) {
    if (err.code === "EEXIST") {
      throw new Error(`${filePath} already exists. create_file never overwrites, pick a new name`);
    }
    throw err;
  }
  return {
    content: [{ type: "text", text: `Created ${target}` }],
  };
}

// --- SQLite (read-only) ---
// Queries run on a temp snapshot copy (db + -wal), never the original file:
// apps like Firefox hold an exclusive lock on their dbs, and a copy can't be
// used to modify the real one. sqlite3 also runs with -readonly and -safe
// (-safe blocks .shell/.system, ATTACH, writefile(), load_extension, ...).
async function withSqliteSnapshot(dbPath, fn) {
  const resolved = await resolveAndValidate(dbPath);
  const stat = await fs.stat(resolved);
  if (!stat.isFile()) throw new Error(`${dbPath} is not a file`);
  if (stat.size > SQLITE_MAX_DB_BYTES) {
    throw new Error(`${dbPath} is ${Math.round(stat.size / 1e6)}MB, over the 1GB snapshot limit`);
  }
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "lf-sqlite-"));
  try {
    const copy = path.join(dir, "db.sqlite");
    await fs.copyFile(resolved, copy);
    for (const ext of ["-wal", "-shm"]) {
      try {
        await fs.copyFile(resolved + ext, copy + ext);
      } catch {}
    }
    return await fn(copy);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
}

async function runSqlite(dbCopy, sql) {
  // A line starting with "." would be a sqlite3 CLI dot-command, never SQL
  if (sql.split("\n").some((line) => line.trimStart().startsWith("."))) {
    throw new Error("Dot-commands are not allowed, send plain SQL only");
  }
  const { stdout } = await promisify(execFile)(
    SQLITE_BIN,
    ["-readonly", "-safe", "-bail", "-json", dbCopy, sql],
    { timeout: 20000, maxBuffer: 64 * 1024 * 1024 }
  );
  const trimmed = stdout.trim();
  if (!trimmed) return [];
  // -json prints one array per statement; keep the last one
  const arrays = trimmed.split(/\n(?=\[)/);
  return JSON.parse(arrays[arrays.length - 1]);
}

function formatRows(rows, maxRows) {
  const cut = rows.slice(0, maxRows).map((row) =>
    Object.fromEntries(
      Object.entries(row).map(([k, v]) => [
        k,
        typeof v === "string" && v.length > 500 ? v.slice(0, 500) + "…" : v,
      ])
    )
  );
  let text = JSON.stringify(cut, null, 1);
  if (text.length > SQLITE_MAX_OUTPUT_CHARS) {
    text = text.slice(0, SQLITE_MAX_OUTPUT_CHARS) + "\n… (output truncated, add LIMIT or select fewer columns)";
  }
  const note =
    rows.length > maxRows ? `${rows.length} rows, showing first ${maxRows}` : `${rows.length} rows`;
  return { content: [{ type: "text", text: `${note}\n${text}` }] };
}

async function sqliteSchema(dbPath) {
  return withSqliteSnapshot(dbPath, async (copy) => {
    const rows = await runSqlite(
      copy,
      "SELECT type, name, sql FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY type, name;"
    );
    const text = rows.map((r) => `-- ${r.type} ${r.name}\n${r.sql};`).join("\n\n");
    return { content: [{ type: "text", text: text || "No tables" }] };
  });
}

async function sqliteQuery(dbPath, sql, maxRows = 200) {
  return withSqliteSnapshot(dbPath, async (copy) => formatRows(await runSqlite(copy, sql), maxRows));
}

async function editFile(filePath, edits) {
  const resolved = await resolveAndValidate(filePath);
  let content = await fs.readFile(resolved, "utf-8");
  for (const edit of edits) {
    if (!content.includes(edit.oldText)) {
      throw new Error(
        `Edit failed: could not find "${edit.oldText.slice(0, 50)}..." in ${filePath}`
      );
    }
    content = content.replace(edit.oldText, edit.newText);
  }
  await fs.writeFile(resolved, content, "utf-8");
  return {
    content: [
      {
        type: "text",
        text: `Applied ${edits.length} edit(s) to ${filePath}`,
      },
    ],
  };
}

// --- MCP Server ---
const server = new Server(
  { name: "local-files-smart", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "read_file",
      description:
        "Read a file from disk. Images are automatically resized to max 1024px and returned as JPEG.",
      inputSchema: {
        type: "object",
        properties: { path: { type: "string", description: "File path" } },
        required: ["path"],
      },
    },
    {
      name: "read_multiple_files",
      description: "Read multiple files at once. Images are auto-resized.",
      inputSchema: {
        type: "object",
        properties: {
          paths: {
            type: "array",
            items: { type: "string" },
            description: "Array of file paths",
          },
        },
        required: ["paths"],
      },
    },
    {
      name: "write_file",
      description: "Write content to a file (creates or overwrites).",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
          content: { type: "string" },
        },
        required: ["path", "content"],
      },
    },
    {
      name: "create_file",
      description:
        "Create a NEW file with content. Fails if the file already exists (never overwrites). Creates missing parent directories.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
          content: { type: "string" },
        },
        required: ["path", "content"],
      },
    },
    {
      name: "edit_file",
      description:
        "Search-and-replace edits in a file. Each edit has oldText and newText.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
          edits: {
            type: "array",
            items: {
              type: "object",
              properties: {
                oldText: { type: "string" },
                newText: { type: "string" },
              },
              required: ["oldText", "newText"],
            },
          },
        },
        required: ["path", "edits"],
      },
    },
    {
      name: "list_directory",
      description: "List files and directories in a path.",
      inputSchema: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
    {
      name: "directory_tree",
      description: "Get a recursive tree view of a directory (max 3 levels).",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string" },
          max_depth: { type: "number", description: "Max depth (default 3)" },
        },
        required: ["path"],
      },
    },
    {
      name: "move_file",
      description: "Move or rename a file.",
      inputSchema: {
        type: "object",
        properties: {
          source: { type: "string" },
          destination: { type: "string" },
        },
        required: ["source", "destination"],
      },
    },
    {
      name: "search_files",
      description: "Search for files by name pattern (regex) in a directory.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string", description: "Directory to search" },
          pattern: { type: "string", description: "Regex pattern for filename" },
        },
        required: ["path", "pattern"],
      },
    },
    {
      name: "sqlite_schema",
      description:
        "List the tables/views and their columns (CREATE statements) of a SQLite database file. Read-only, works on locked dbs (e.g. Firefox places.sqlite).",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string", description: "Path to the .sqlite/.db file" },
        },
        required: ["path"],
      },
    },
    {
      name: "sqlite_query",
      description:
        "Run a read-only SQL query on a SQLite database file and get rows as JSON. Runs on a snapshot copy, so it can never modify the database. Use sqlite_schema first to see table names.",
      inputSchema: {
        type: "object",
        properties: {
          path: { type: "string", description: "Path to the .sqlite/.db file" },
          sql: { type: "string", description: "A SELECT query (plain SQL, no dot-commands)" },
          max_rows: { type: "number", description: "Max rows to return (default 200)" },
        },
        required: ["path", "sql"],
      },
    },
    {
      name: "get_file_info",
      description: "Get metadata about a file (size, dates, permissions).",
      inputSchema: {
        type: "object",
        properties: { path: { type: "string" } },
        required: ["path"],
      },
    },
    {
      name: "list_allowed_directories",
      description: "List directories this server is allowed to access.",
      inputSchema: {
        type: "object",
        properties: {},
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "read_file":
        return await readFile(args.path);
      case "read_multiple_files": {
        const results = [];
        for (const p of args.paths) {
          try {
            const result = await readFile(p);
            results.push(...result.content);
          } catch (err) {
            results.push({ type: "text", text: `Error reading ${p}: ${err.message}` });
          }
        }
        return { content: results };
      }
      case "write_file":
        return await writeFile(args.path, args.content);
      case "create_file":
        return await createFile(args.path, args.content);
      case "edit_file":
        return await editFile(args.path, args.edits);
      case "list_directory":
        return await listDirectory(args.path);
      case "directory_tree": {
        const tree = await directoryTree(args.path, args.max_depth || 3);
        return {
          content: [{ type: "text", text: JSON.stringify(tree, null, 2) }],
        };
      }
      case "move_file":
        return await moveFile(args.source, args.destination);
      case "search_files":
        return await searchFiles(args.path, args.pattern);
      case "sqlite_schema":
        return await sqliteSchema(args.path);
      case "sqlite_query":
        return await sqliteQuery(args.path, args.sql, args.max_rows || 200);
      case "get_file_info":
        return await getFileInfo(args.path);
      case "list_allowed_directories":
        return {
          content: [{ type: "text", text: allowedDirs.join("\n") }],
        };
      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (err) {
    return {
      content: [{ type: "text", text: `Error: ${err.message}` }],
      isError: true,
    };
  }
});

// --- Start ---
const transport = new StdioServerTransport();
await server.connect(transport);
