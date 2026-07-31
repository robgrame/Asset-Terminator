import type { ApiResult } from "./client.js";

export function formatToolResult(result: ApiResult, action: string): string {
  if ([401, 403, 408, 429].includes(result.status) || result.status >= 500) {
    const body =
      typeof result.body === "string"
        ? result.body
        : JSON.stringify(result.body);
    throw new Error(`${action} failed with HTTP ${result.status}: ${body}`);
  }

  return JSON.stringify(
    {
      action,
      httpStatus: result.status,
      accepted: result.ok,
      result: result.body,
    },
    null,
    2
  );
}
