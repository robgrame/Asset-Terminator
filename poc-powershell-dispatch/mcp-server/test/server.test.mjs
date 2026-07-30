import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function createApiStub() {
  const requests = [];
  const server = http.createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const record = {
      method: request.method,
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      functionKey: request.headers["x-functions-key"],
      body: request.method === "POST" ? await readJson(request) : undefined,
    };
    requests.push(record);

    response.setHeader("Content-Type", "application/json");

    if (record.query.requestId === "unauthorized") {
      response.writeHead(401).end(JSON.stringify({ error: "Unauthorized" }));
      return;
    }
    if (record.body?.serialNumber === "guardrail") {
      response.writeHead(422).end(JSON.stringify({ status: "Rejected" }));
      return;
    }
    if (request.method === "POST" && url.pathname === "/api/v1/wipe") {
      response
        .writeHead(202)
        .end(JSON.stringify({ requestId: "req-123", status: "Queued" }));
      return;
    }
    if (request.method === "GET" && url.pathname === "/api/v1/wipe/status") {
      response
        .writeHead(200)
        .end(JSON.stringify({ requestId: record.query.requestId, status: "Completed" }));
      return;
    }

    response.writeHead(404).end(JSON.stringify({ error: "Not found" }));
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    requests,
    close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}

async function createMcpClient(baseUrl) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["dist/index.js"],
    env: {
      ...process.env,
      AT_FUNCTION_BASE_URL: baseUrl,
      AT_FUNCTION_KEY: "host-key",
      AT_FUNCTION_TIMEOUT_MS: "5000",
    },
  });
  const client = new Client({ name: "asset-terminator-test", version: "1.0.0" });
  await client.connect(transport);
  return { client, close: () => client.close() };
}

test("publishes tools and proxies requests with the host key", async (t) => {
  const api = await createApiStub();
  const mcp = await createMcpClient(api.baseUrl);
  t.after(async () => {
    await mcp.close();
    await api.close();
  });

  const tools = await mcp.client.listTools();
  assert.deepEqual(
    tools.tools.map((tool) => tool.name).sort(),
    ["get_wipe_status", "submit_wipe_request"]
  );

  const submit = await mcp.client.callTool({
    name: "submit_wipe_request",
    arguments: {
      operatingSystem: "Windows",
      scenario: "Disposal",
      serialNumber: "SERIAL-1",
      dryRun: true,
    },
  });
  assert.equal(submit.isError, false);
  assert.match(submit.content[0].text, /HTTP 202/);
  assert.equal(api.requests[0].functionKey, "host-key");
  assert.equal(api.requests[0].body.serialNumber, "SERIAL-1");

  const status = await mcp.client.callTool({
    name: "get_wipe_status",
    arguments: { requestId: "req-123" },
  });
  assert.equal(status.isError, false);
  assert.match(status.content[0].text, /Completed/);
  assert.deepEqual(api.requests[1].query, { requestId: "req-123" });
});

test("validates identifier combinations before calling the API", async (t) => {
  const api = await createApiStub();
  const mcp = await createMcpClient(api.baseUrl);
  t.after(async () => {
    await mcp.close();
    await api.close();
  });

  const missingDevice = await mcp.client.callTool({
    name: "submit_wipe_request",
    arguments: { operatingSystem: "Windows", scenario: "Disposal" },
  });
  assert.equal(missingDevice.isError, true);

  const ambiguousStatus = await mcp.client.callTool({
    name: "get_wipe_status",
    arguments: { requestId: "req-123", serialNumber: "SERIAL-1" },
  });
  assert.equal(ambiguousStatus.isError, true);
  assert.match(ambiguousStatus.content[0].text, /exactly one/);
  assert.equal(api.requests.length, 0);
});

test("distinguishes business outcomes from authentication failures", async (t) => {
  const api = await createApiStub();
  const mcp = await createMcpClient(api.baseUrl);
  t.after(async () => {
    await mcp.close();
    await api.close();
  });

  const rejected = await mcp.client.callTool({
    name: "submit_wipe_request",
    arguments: {
      operatingSystem: "Windows",
      scenario: "Disposal",
      serialNumber: "guardrail",
    },
  });
  assert.equal(rejected.isError, false);
  assert.match(rejected.content[0].text, /HTTP 422/);

  const unauthorized = await mcp.client.callTool({
    name: "get_wipe_status",
    arguments: { requestId: "unauthorized" },
  });
  assert.equal(unauthorized.isError, true);
  assert.match(unauthorized.content[0].text, /HTTP 401/);
});
