import path from "node:path";
import { describe, expect, it } from "vitest";
import { invokeKernelWorker } from "../kernel/vcad-kernel-client.mjs";

const workerPath = path.resolve("tests/fixtures/kernel-worker-fixture.mjs");

describe("bounded MCP kernel worker", () => {
  it("returns a normal isolated worker response", async () => {
    await expect(invokeKernelWorker({ action: "normal", value: 7 }, { workerPath, timeoutMs: 2_000 }))
      .resolves.toMatchObject({ ok: true, echoed: { action: "normal", value: 7 } });
  });

  it("kills a hung worker at the configured deadline", async () => {
    await expect(invokeKernelWorker({ action: "hang" }, { workerPath, timeoutMs: 100 }))
      .rejects.toThrow("kernel_timeout: worker exceeded 100 ms; the document was not changed");
  });

  it("propagates request cancellation and kills the worker", async () => {
    const controller = new AbortController();
    const request = invokeKernelWorker({ action: "hang" }, { workerPath, timeoutMs: 2_000, signal: controller.signal });
    controller.abort();
    await expect(request).rejects.toThrow("kernel_cancelled: request was cancelled; the document was not changed");
  });

  it("contains worker crashes and returns an actionable error", async () => {
    await expect(invokeKernelWorker({ action: "crash" }, { workerPath, timeoutMs: 2_000 }))
      .rejects.toThrow("kernel_worker_failed: fixture crash");
  });
});
