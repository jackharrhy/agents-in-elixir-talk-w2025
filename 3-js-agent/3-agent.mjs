#!/usr/bin/env node

import express from "express";
import { openai } from "@ai-sdk/openai";
import { streamText, tool, stepCountIs } from "ai";
import { z } from "zod";
import { exec } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const execAsync = promisify(exec);

const __dirname = dirname(fileURLToPath(import.meta.url));
const port = 3001;

const ALLOWED_COMMANDS = [
  "ls",
  "pwd",
  "whoami",
  "cat",
  "id",
  "uname",
  "hostname",
  "date",
  "uptime",
  "dig",
  "curl",
  "head",
  "tail",
  "wc",
  "grep",
  "echo",
];

const app = express();
app.use(express.json());

app.get("/", (req, res) => {
  res.sendFile(join(__dirname, "3-agent.html"));
});

app.post("/api/chat", async (req, res) => {
  const { messages } = req.body;

  const result = streamText({
    model: openai("gpt-5-chat-latest"),
    system: `You are a helpful assistant that can execute shell commands on the user's system.

You have access to these commands: ${ALLOWED_COMMANDS.join(", ")}

When the user asks about files, directories, system info, or network queries:
- Use the execute_command tool to run appropriate commands
- You can pass arguments to commands (e.g., "ls -la", "curl -s https://example.com", "dig google.com")
- After seeing command output, explain the results to the user

For network queries:
- Use "dig" for DNS lookups (e.g., "dig example.com", "dig +short example.com A")
- Use "curl" for HTTP requests (e.g., "curl -s https://api.example.com")

Be concise and helpful. Only execute commands when needed to answer the user's question.`,
    messages,
    tools: {
      execute_command: tool({
        description:
          "Execute a shell command on the user's system. Only whitelisted commands are allowed.",
        inputSchema: z.object({
          command: z
            .string()
            .describe(
              "The full command to execute, including arguments (e.g., 'ls -la', 'curl -s https://example.com')"
            ),
        }),
        execute: async ({ command }) => {
          const baseCommand = command.trim().split(/\s+/)[0];

          if (!ALLOWED_COMMANDS.includes(baseCommand)) {
            return {
              success: false,
              error: `Command '${baseCommand}' is not allowed. Allowed commands: ${ALLOWED_COMMANDS.join(
                ", "
              )}`,
            };
          }

          try {
            const { stdout, stderr } = await execAsync(command, {
              timeout: 30000,
              maxBuffer: 1024 * 1024,
            });
            return {
              success: true,
              stdout: stdout || "(no output)",
              stderr: stderr || undefined,
            };
          } catch (error) {
            return {
              success: false,
              error: error.message,
              stderr: error.stderr,
            };
          }
        },
      }),
    },
    stopWhen: stepCountIs(10),
    onStepFinish: async ({ toolResults }) => {
      if (toolResults?.length) {
        console.log("Tool results:", JSON.stringify(toolResults, null, 2));
      }
    },
  });

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");

  for await (const part of result.fullStream) {
    res.write(`data: ${JSON.stringify(part)}\n\n`);
  }

  res.write("data: [DONE]\n\n");
  res.end();
});

app.listen(port, () => {
  console.log(`Agent server running at http://localhost:${port}`);
});
