import { Effect } from "effect";
import { loadConfig } from "./config/Config.js";
import { createAppLayer, runApp } from "./main.js";

async function main() {
  // First, load config to determine AI provider
  const configResult = await Effect.runPromise(
    loadConfig.pipe(Effect.either)
  );

  if (configResult._tag === "Left") {
    console.error("Configuration error:", configResult.left.message);
    process.exit(1);
  }

  const config = configResult.right;
  const appLayer = createAppLayer(config.aiProvider);

  // Handle graceful shutdown
  const controller = new AbortController();

  process.on("SIGINT", () => {
    console.log("\nReceived SIGINT, shutting down...");
    controller.abort();
  });

  process.on("SIGTERM", () => {
    console.log("\nReceived SIGTERM, shutting down...");
    controller.abort();
  });

  try {
    await Effect.runPromise(
      runApp.pipe(
        Effect.provide(appLayer),
        Effect.interruptible
      )
    );
  } catch (error) {
    if (error instanceof Error && error.name === "InterruptedException") {
      console.log("Shutdown complete");
    } else {
      console.error("Fatal error:", error);
      process.exit(1);
    }
  }
}

main();
