import assert from "node:assert/strict";
import http from "node:http";
import test from "node:test";
import { WipeApiClient } from "../dist/client.js";
import { getWipeStatus } from "../dist/functions/getWipeStatus.js";
import { submitWipeRequest } from "../dist/functions/submitWipeRequest.js";

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
    } else if (record.body?.serialNumber === "guardrail") {
      response.writeHead(422).end(JSON.stringify({ status: "Rejected" }));
    } else if (request.method === "POST" && url.pathname === "/api/v1/wipe") {
      response.writeHead(202).end(
        JSON.stringify({ requestId: "req-123", status: "Queued" })
      );
    } else if (
      request.method === "GET" &&
      url.pathname === "/api/v1/wipe/status"
    ) {
      response.writeHead(200).end(
        JSON.stringify({ requestId: record.query.requestId, status: "Completed" })
      );
    } else {
      response.writeHead(404).end(JSON.stringify({ error: "Not found" }));
    }
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  return {
    client: new WipeApiClient({
      baseUrl: `http://127.0.0.1:${address.port}`,
      functionKey: "host-key",
      timeoutMs: 5000,
    }),
    requests,
    close: () =>
      new Promise((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve()))
      ),
  };
}

test("proxies both tools to the API with the host key", async (t) => {
  const api = await createApiStub();
  t.after(api.close);

  const submit = JSON.parse(
    await submitWipeRequest(
      {
        operatingSystem: "Windows",
        scenario: "Disposal",
        serialNumber: "SERIAL-1",
        dryRun: true,
      },
      api.client
    )
  );
  assert.equal(submit.httpStatus, 202);
  assert.equal(api.requests[0].functionKey, "host-key");
  assert.equal(api.requests[0].body.serialNumber, "SERIAL-1");

  const status = JSON.parse(
    await getWipeStatus({ requestId: "req-123" }, api.client)
  );
  assert.equal(status.result.status, "Completed");
  assert.deepEqual(api.requests[1].query, { requestId: "req-123" });
});

test("validates tool arguments before calling the API", async (t) => {
  const api = await createApiStub();
  t.after(api.close);

  await assert.rejects(
    submitWipeRequest(
      { operatingSystem: "Windows", scenario: "Disposal" },
      api.client
    ),
    /At least one/
  );
  await assert.rejects(
    getWipeStatus(
      { requestId: "req-123", serialNumber: "SERIAL-1" },
      api.client
    ),
    /exactly one/
  );
  assert.equal(api.requests.length, 0);
});

test("returns business outcomes and throws for authorization failures", async (t) => {
  const api = await createApiStub();
  t.after(api.close);

  const rejected = JSON.parse(
    await submitWipeRequest(
      {
        operatingSystem: "Windows",
        scenario: "Disposal",
        serialNumber: "guardrail",
      },
      api.client
    )
  );
  assert.equal(rejected.httpStatus, 422);
  assert.equal(rejected.result.status, "Rejected");

  await assert.rejects(
    getWipeStatus({ requestId: "unauthorized" }, api.client),
    /HTTP 401/
  );
});
