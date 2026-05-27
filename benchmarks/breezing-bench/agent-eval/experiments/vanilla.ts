import type { ExperimentConfig } from "@vercel/agent-eval";

// Vanilla condition: single agent, minimal instructions (no validate)
export default {
  agent: "claude-code",
  model: "claude-haiku-4-5-20251001",
  runs: 3,
  earlyExit: false,
  timeout: 300,
  scripts: ["test"],
  sandbox: "docker",
  evals: [
    "task-11",
    "task-12",
    "task-13",
    "task-14",
    "task-15",
    "task-16",
    "task-17",
    "task-18",
    "task-19",
    "task-20",
  ],
  setup: async (sandbox) => {
    await sandbox.writeFiles({
      "CLAUDE.md": [
        "Complete the task described in PROMPT.md.",
        "Read the existing source files in src/ carefully.",
      ].join("\n"),
    });
  },
} satisfies ExperimentConfig;
