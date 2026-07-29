/**
 * Runtime configuration resolved from environment variables.
 *
 * The MCP server is a thin, credential-holding proxy in front of the
 * Asset-Terminator disposal Function API. The AI agent never sees the function
 * key: it only calls the exposed tools, and this process attaches the key.
 */
export interface ServerConfig {
  /** Base URL of the intake Function App, e.g. https://attdisp-func-api-dev.azurewebsites.net */
  baseUrl: string;
  /** Function key sent as the x-functions-key header. */
  functionKey: string;
  /** Per-request timeout in milliseconds. */
  timeoutMs: number;
}

function stripTrailingSlash(value: string): string {
  return value.replace(/\/+$/, "");
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): ServerConfig {
  const baseUrl = env.AT_FUNCTION_BASE_URL?.trim();
  const functionKey = env.AT_FUNCTION_KEY?.trim();

  if (!baseUrl) {
    throw new Error(
      "AT_FUNCTION_BASE_URL is required (e.g. https://attdisp-func-api-dev.azurewebsites.net)."
    );
  }
  if (!functionKey) {
    throw new Error("AT_FUNCTION_KEY is required (the intake function key).");
  }

  const timeoutRaw = env.AT_FUNCTION_TIMEOUT_MS?.trim();
  const timeoutMs = timeoutRaw ? Number.parseInt(timeoutRaw, 10) : 30_000;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error("AT_FUNCTION_TIMEOUT_MS must be a positive integer (milliseconds).");
  }

  return {
    baseUrl: stripTrailingSlash(baseUrl),
    functionKey,
    timeoutMs,
  };
}
