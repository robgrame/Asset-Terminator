import { app, arg, type InvocationContext } from "@azure/functions";
import { WipeApiClient } from "../client.js";
import { loadConfig } from "../config.js";
import { formatToolResult } from "../toolResult.js";

const SCENARIOS = new Set(["Retirement", "Sale", "Disposal", "LostStolen"]);

export interface SubmitWipeArguments {
  operatingSystem?: string;
  scenario?: string;
  serialNumber?: string;
  imei?: string;
  managedDeviceId?: string;
  deviceName?: string;
  requestId?: string;
  userConfirmed?: boolean;
  dryRun?: boolean;
  mdmServerId?: string;
}

export async function submitWipeRequest(
  args: SubmitWipeArguments,
  client: WipeApiClient
): Promise<string> {
  if (!args.operatingSystem?.trim()) {
    throw new Error("operatingSystem is required.");
  }
  if (!args.scenario || !SCENARIOS.has(args.scenario)) {
    throw new Error(
      "scenario must be one of: Retirement, Sale, Disposal, LostStolen."
    );
  }
  if (
    !args.serialNumber &&
    !args.imei &&
    !args.managedDeviceId &&
    !args.deviceName
  ) {
    throw new Error(
      "At least one of serialNumber, imei, managedDeviceId or deviceName is required."
    );
  }
  const payload = Object.fromEntries(
    Object.entries(args).filter(([, value]) => value !== undefined)
  );
  const result = await client.submitWipe(payload);
  return formatToolResult(result, "submit_wipe_request");
}

export async function submitWipeRequestHandler(
  _toolArguments: unknown,
  context: InvocationContext
): Promise<string> {
  const args = (context.triggerMetadata?.mcptoolargs ?? {}) as SubmitWipeArguments;
  context.log("Submitting an Asset-Terminator wipe request through MCP.");
  return submitWipeRequest(args, new WipeApiClient(loadConfig()));
}

app.mcpTool("submitWipeRequest", {
  toolName: "submit_wipe_request",
  description:
    "Submits a disposal/wipe request to Asset-Terminator. The API validates the device, applies guardrails and queues the platform runbook. Use dryRun=true to test without wiping, then poll get_wipe_status.",
  toolProperties: {
    operatingSystem: arg
      .string()
      .describe("Required OS: Windows, macOS, iOS, Android or Mobile."),
    scenario: arg
      .string()
      .describe("Required scenario: Retirement, Sale, Disposal or LostStolen."),
    serialNumber: arg.string().describe("Device serial number.").optional(),
    imei: arg.string().describe("Device IMEI.").optional(),
    managedDeviceId: arg
      .string()
      .describe("Intune managedDevice identifier.")
      .optional(),
    deviceName: arg.string().describe("Device name in Intune.").optional(),
    requestId: arg
      .string()
      .describe("Optional idempotency key, such as a ServiceNow RITM.")
      .optional(),
    userConfirmed: arg
      .boolean()
      .describe("Whether the user explicitly confirmed the wipe.")
      .optional(),
    dryRun: arg
      .boolean()
      .describe("Validate and dispatch without performing the destructive wipe.")
      .optional(),
    mdmServerId: arg
      .string()
      .describe("Apple Business Manager MDM server identifier.")
      .optional(),
  },
  handler: submitWipeRequestHandler,
});
