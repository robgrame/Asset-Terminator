import { app, arg, type InvocationContext } from "@azure/functions";
import { WipeApiClient } from "../client.js";
import { loadConfig } from "../config.js";
import { formatToolResult } from "../toolResult.js";

export interface GetWipeStatusArguments {
  requestId?: string;
  serialNumber?: string;
}

export async function getWipeStatus(
  args: GetWipeStatusArguments,
  client: WipeApiClient
): Promise<string> {
  if (Number(Boolean(args.requestId)) + Number(Boolean(args.serialNumber)) !== 1) {
    throw new Error("Provide exactly one of requestId or serialNumber.");
  }

  const result = await client.getStatus(args);
  return formatToolResult(result, "get_wipe_status");
}

export async function getWipeStatusHandler(
  _toolArguments: unknown,
  context: InvocationContext
): Promise<string> {
  const args = (context.triggerMetadata?.mcptoolargs ?? {}) as GetWipeStatusArguments;
  context.log("Retrieving an Asset-Terminator wipe request through MCP.");
  return getWipeStatus(args, new WipeApiClient(loadConfig()));
}

app.mcpTool("getWipeStatus", {
  toolName: "get_wipe_status",
  description:
    "Retrieves the durable state of a disposal request by requestId or serialNumber, including runbook execution status and result. Provide exactly one identifier.",
  toolProperties: {
    requestId: arg.string().describe("Exact request identifier.").optional(),
    serialNumber: arg
      .string()
      .describe("Serial number whose disposal requests should be listed.")
      .optional(),
  },
  handler: getWipeStatusHandler,
});
