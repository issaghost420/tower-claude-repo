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

// --- Config ---
const MAX_DIMENSION = 1024; // longest edge cap
const JPEG_QUALITY = 85;
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
