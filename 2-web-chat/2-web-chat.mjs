#!/usr/bin/env node

import express from "express";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const model = "gpt-5-nano";
const api = "https://api.openai.com/v1/responses";
const port = 3000;

const __dirname = dirname(fileURLToPath(import.meta.url));

const app = express();
app.use(express.json());

app.get("/", (req, res) => {
  res.sendFile(join(__dirname, "2-web-chat.html"));
});

app.post("/api/chat", async (req, res) => {
  const { message, prevId } = req.body;

  const payload = {
    model,
    input: message,
    stream: true,
    reasoning: { summary: "auto" },
    ...(prevId && { previous_response_id: prevId }),
  };

  const openaiRes = await fetch(api, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!openaiRes.ok) {
    const text = await openaiRes.text();
    return res.status(openaiRes.status).json({ error: text });
  }

  // Set SSE headers
  res.set({
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
  });

  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of openaiRes.body) {
    buffer += decoder.decode(chunk, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop();

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;

      const data = line.slice(6);
      if (data === "[DONE]") {
        res.write("data: [DONE]\n\n");
        continue;
      }

      let event;
      try {
        event = JSON.parse(data);
      } catch {
        continue;
      }

      switch (event.type) {
        case "response.reasoning_summary_part.added":
        case "response.reasoning_summary_text.delta":
        case "response.reasoning_summary_text.done":
        case "response.output_text.delta":
        case "response.completed":
          res.write(`data: ${JSON.stringify(event)}\n\n`);
          break;
      }
    }
  }

  res.end();
});

app.listen(port, () => {
  console.log(`Server running at http://localhost:${port}`);
});
