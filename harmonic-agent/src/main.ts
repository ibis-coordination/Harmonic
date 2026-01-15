import { Effect, Layer } from "effect";
import { ConfigLive, ConfigService } from "./config/Config.js";
import { HttpServerLive, HttpServer } from "./http/HttpServer.js";
import { WebhookQueueLive } from "./queue/WebhookQueue.js";
import { McpClientLive } from "./mcp/McpClient.js";
import { ClaudeProviderLive } from "./ai/ClaudeProvider.js";
import { OpenAiProviderLive } from "./ai/OpenAiProvider.js";
import { AgentLoopLive } from "./agent/AgentLoop.js";
import { AgentWorkerLive, AgentWorker } from "./agent/AgentWorker.js";
import type { AiProviderType } from "./config/Config.js";

function createAiProviderLayer(provider: AiProviderType) {
  if (provider === "openai") {
    return OpenAiProviderLive;
  }
  return ClaudeProviderLive;
}

export const createAppLayer = (aiProvider: AiProviderType) => {
  const AiProviderLayer = createAiProviderLayer(aiProvider);

  // Build layers from bottom up, merging to expose all services
  const baseLayer = ConfigLive;

  const withQueue = Layer.provideMerge(WebhookQueueLive, baseLayer);

  const withMcp = Layer.provideMerge(McpClientLive, withQueue);

  const withAi = Layer.provideMerge(AiProviderLayer, withMcp);

  const withAgentLoop = Layer.provideMerge(AgentLoopLive, withAi);

  const withHttp = Layer.provideMerge(HttpServerLive, withAgentLoop);

  const withWorker = Layer.provideMerge(AgentWorkerLive, withHttp);

  return withWorker;
};

export const runApp = Effect.gen(function* () {
  const config = yield* ConfigService;

  console.log("Starting Harmonic Agent Service...");
  console.log(`AI Provider: ${config.aiProvider}`);
  console.log(`Model: ${config.aiModel}`);
  console.log(`Max turns: ${config.maxTurns}`);

  const httpServer = yield* HttpServer;
  const agentWorker = yield* AgentWorker;

  yield* httpServer.start;
  yield* agentWorker.start;

  // Keep running until interrupted
  yield* Effect.never;
}).pipe(
  Effect.scoped,
  Effect.catchAll((error) => {
    console.error("Application error:", error);
    return Effect.void;
  })
);
