#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { loadConfig } from "./config.js";
import { WipeApiClient, type ApiResult } from "./client.js";

const SCENARIOS = ["Retirement", "Sale", "Disposal", "LostStolen"] as const;

/**
 * Render an API result as an MCP tool response. Business outcomes such as
 * validation errors (400) or rejected guardrails (422) are returned as normal
 * (successful) tool calls with isError=false so the agent can reason about the
 * body. Authentication/authorization failures and server failures are exposed
 * as MCP errors; only transport failures throw.
 */
function toToolResult(result: ApiResult, action: string) {
  const bodyText =
    typeof result.body === "string"
      ? result.body
      : JSON.stringify(result.body, null, 2);

  const isError =
    [401, 403, 408, 429].includes(result.status) || result.status >= 500;
  const summary = `${action}: HTTP ${result.status}${result.ok ? " (accepted)" : ""}`;

  return {
    isError,
    content: [
      {
        type: "text" as const,
        text: `${summary}\n\n${bodyText}`,
      },
    ],
  };
}

async function main(): Promise<void> {
  const config = loadConfig();
  const client = new WipeApiClient(config);

  const server = new McpServer({
    name: "asset-terminator-mcp",
    version: "0.1.0",
  });

  server.registerTool(
    "submit_wipe_request",
    {
      title: "Submit a device disposal (wipe) request",
      description:
        "Submits a device disposal/wipe request to the Asset-Terminator intake Function API " +
        "(POST /api/v1/wipe). The API validates the request, resolves the device against Intune, " +
        "runs the guardrails and queues the wipe on Service Bus; the platform runbook performs the " +
        "actual wipe asynchronously. At least one device identifier (serialNumber, imei, " +
        "managedDeviceId or deviceName) is required. Use dryRun=true to exercise the pipeline " +
        "without wiping. Returns the requestId and status; poll get_wipe_status for the outcome.",
      inputSchema: {
        operatingSystem: z
          .string()
          .describe(
            "Reported OS. Maps to an enrollment platform (Windows, Apple, Android). Aliases: win/macos/ios/ipados/android/mobile."
          ),
        scenario: z
          .enum(SCENARIOS)
          .describe("Disposal scenario. One of: Retirement, Sale, Disposal, LostStolen."),
        serialNumber: z.string().optional().describe("Device serial number."),
        imei: z.string().optional().describe("Device IMEI (mobile)."),
        managedDeviceId: z.string().optional().describe("Intune managedDevice id (GUID)."),
        deviceName: z.string().optional().describe("Device name as known to Intune."),
        requestId: z
          .string()
          .optional()
          .describe("Idempotency key (e.g. the ServiceNow RITM). Defaults to a new GUID."),
        userConfirmed: z
          .boolean()
          .optional()
          .describe("Whether the user confirmed the wipe (guardrail). Required true unless dryRun."),
        dryRun: z
          .boolean()
          .optional()
          .describe("If true, validate and dispatch without performing the wipe."),
        mdmServerId: z.string().optional().describe("Apple ABM MDM server id (Apple only)."),
        callbackUrl: z
          .string()
          .url()
          .optional()
          .describe("Optional URL notified when the request reaches a terminal state."),
      },
    },
    async (args) => {
      if (!args.serialNumber && !args.imei && !args.managedDeviceId && !args.deviceName) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: "At least one of serialNumber, imei, managedDeviceId or deviceName is required.",
            },
          ],
        };
      }

      const payload: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(args)) {
        if (value !== undefined) payload[key] = value;
      }

      const result = await client.submitWipe(payload);
      return toToolResult(result, "submit_wipe_request");
    }
  );

  server.registerTool(
    "get_wipe_status",
    {
      title: "Get the status of a disposal (wipe) request",
      description:
        "Retrieves the durable state of a disposal request from the Asset-Terminator API " +
        "(GET /api/v1/wipe/status). Query by requestId (exact, single result) or by serialNumber " +
        "(all requests for a device). Returns status, timestamps, the Automation job id and the " +
        "structured runbook result. Provide exactly one of requestId or serialNumber.",
      inputSchema: {
        requestId: z.string().optional().describe("Exact request id to look up."),
        serialNumber: z
          .string()
          .optional()
          .describe("Serial number to list all disposal requests for a device."),
      },
    },
    async ({ requestId, serialNumber }) => {
      if (Number(Boolean(requestId)) + Number(Boolean(serialNumber)) !== 1) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: "Provide exactly one of requestId or serialNumber.",
            },
          ],
        };
      }

      const result = await client.getStatus({ requestId, serialNumber });
      return toToolResult(result, "get_wipe_status");
    }
  );

  const transport = new StdioServerTransport();
  await server.connect(transport);
  // stderr keeps the stdio JSON-RPC channel clean.
  console.error(
    `asset-terminator-mcp connected (base=${config.baseUrl}). Tools: submit_wipe_request, get_wipe_status.`
  );
}

main().catch((err) => {
  console.error(`Fatal: ${err instanceof Error ? err.message : String(err)}`);
  process.exit(1);
});
