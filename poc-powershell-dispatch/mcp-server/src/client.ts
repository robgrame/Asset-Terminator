import type { ServerConfig } from "./config.js";

/**
 * Result of an API call: the parsed body plus the HTTP status, so the tool
 * layer can surface guardrail/validation outcomes (400/422) to the agent
 * without treating them as transport failures.
 */
export interface ApiResult {
  status: number;
  ok: boolean;
  body: unknown;
}

export class WipeApiClient {
  constructor(private readonly config: ServerConfig) {}

  private async request(
    method: "GET" | "POST",
    path: string,
    body?: unknown
  ): Promise<ApiResult> {
    const url = `${this.config.baseUrl}${path}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.config.timeoutMs);

    try {
      const response = await fetch(url, {
        method,
        headers: {
          "x-functions-key": this.config.functionKey,
          ...(body !== undefined ? { "Content-Type": "application/json" } : {}),
          Accept: "application/json",
        },
        body: body !== undefined ? JSON.stringify(body) : undefined,
        signal: controller.signal,
      });

      const text = await response.text();
      let parsed: unknown = text;
      if (text) {
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = text;
        }
      }

      return { status: response.status, ok: response.ok, body: parsed };
    } catch (err) {
      if (err instanceof Error && err.name === "AbortError") {
        throw new Error(
          `Request to ${method} ${path} timed out after ${this.config.timeoutMs} ms.`
        );
      }
      throw new Error(
        `Request to ${method} ${path} failed: ${err instanceof Error ? err.message : String(err)}`
      );
    } finally {
      clearTimeout(timer);
    }
  }

  /** POST /api/v1/wipe */
  submitWipe(payload: Record<string, unknown>): Promise<ApiResult> {
    return this.request("POST", "/api/v1/wipe", payload);
  }

  /** GET /api/v1/wipe/status?requestId=... | ?serialNumber=... */
  getStatus(query: { requestId?: string; serialNumber?: string }): Promise<ApiResult> {
    const params = new URLSearchParams();
    if (query.requestId) params.set("requestId", query.requestId);
    if (query.serialNumber) params.set("serialNumber", query.serialNumber);
    return this.request("GET", `/api/v1/wipe/status?${params.toString()}`);
  }
}
