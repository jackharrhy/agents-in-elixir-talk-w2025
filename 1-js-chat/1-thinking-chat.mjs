#!/usr/bin/env node

import { createInterface } from "node:readline/promises";
import { stdin, stdout } from "node:process";

const model = "gpt-5-nano";
const api = "https://api.openai.com/v1/responses";

const gray = "\x1b[90m";
const reset = "\x1b[0m";

let prevId = null;

const rl = createInterface({ input: stdin, output: stdout });

while (true) {
  const userMsg = await rl.question("> ");

  if (!userMsg || userMsg === "exit") {
    break;
  }

  const payload = {
    model,
    input: userMsg,
    stream: true,
    reasoning: { summary: "auto" },
    ...(prevId && { previous_response_id: prevId }),
  };

  console.log();

  const res = await fetch(api, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${process.env.OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    console.error(`Error: ${res.status} ${res.statusText}`);
    const text = await res.text();
    console.error(text);
    continue;
  }

  const decoder = new TextDecoder();
  let buffer = "";

  for await (const chunk of res.body) {
    buffer += decoder.decode(chunk, { stream: true });
    const lines = buffer.split("\n");
    buffer = lines.pop();

    for (const line of lines) {
      if (!line.startsWith("data: ")) continue;

      const data = line.slice(6);
      if (data === "[DONE]") continue;

      let event;
      try {
        event = JSON.parse(data);
      } catch {
        continue;
      }

      switch (event.type) {
        case "response.reasoning_summary_part.added":
          process.stdout.write(gray);
          break;

        case "response.reasoning_summary_text.delta":
          process.stdout.write(event.delta ?? "");
          break;

        case "response.reasoning_summary_text.done":
          process.stdout.write(`${reset}\n\n`);
          break;

        case "response.output_text.delta":
          process.stdout.write(event.delta ?? "");
          break;

        case "response.completed":
          prevId = event.response?.id ?? null;
          break;
      }
    }
  }

  console.log();
}

rl.close();
