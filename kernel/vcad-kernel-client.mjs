import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const defaultWorkerPath = fileURLToPath(new URL("./vcad-kernel.mjs", import.meta.url));
const maxOutputBytes = 64 * 1024 * 1024;

function configuredTimeout() {
  const value = Number(process.env.AXIS_CAD_MCP_KERNEL_TIMEOUT_MS || 90_000);
  return Number.isFinite(value) ? Math.min(600_000, Math.max(100, Math.round(value))) : 90_000;
}

/**
 * Invoke the vcad bridge in a disposable process. A hung/trapped WASM solve is
 * killed without taking down the MCP transport, and request cancellation is
 * propagated through the SDK's AbortSignal.
 */
export function invokeKernelWorker(request, options = {}) {
  const workerPath = options.workerPath || defaultWorkerPath;
  const executable = options.executable || process.execPath;
  const timeoutMs = options.timeoutMs ?? configuredTimeout();
  const signal = options.signal;
  if (signal?.aborted) return Promise.reject(new Error("kernel_cancelled: request was cancelled before the worker started"));

  return new Promise((resolve, reject) => {
    const child = spawn(executable, [workerPath], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, AXIS_CAD_COMPILED_WORKER: "0", ...(options.env || {}) }
    });
    let stdout = "", stderr = "", stdoutBytes = 0, stderrBytes = 0, terminationError = null, settled = false;
    const stop = (error) => {
      if (terminationError || settled) return;
      terminationError = error;
      child.kill("SIGKILL");
    };
    const timer = setTimeout(() => stop(new Error(`kernel_timeout: worker exceeded ${timeoutMs} ms; the document was not changed`)), timeoutMs);
    const abort = () => stop(new Error("kernel_cancelled: request was cancelled; the document was not changed"));
    signal?.addEventListener("abort", abort, { once: true });
    const cleanup = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
    };
    const append = (current, chunk, stream) => {
      const bytes = Buffer.byteLength(chunk);
      if (stream === "stdout") stdoutBytes += bytes; else stderrBytes += bytes;
      if ((stream === "stdout" ? stdoutBytes : stderrBytes) > maxOutputBytes) stop(new Error(`kernel_worker_failed: ${stream} exceeded ${maxOutputBytes} bytes`));
      return current + chunk;
    };
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout = append(stdout, chunk, "stdout"); });
    child.stderr.on("data", (chunk) => { stderr = append(stderr, chunk, "stderr"); });
    child.on("error", (error) => {
      if (settled) return;
      settled = true; cleanup(); reject(new Error(`kernel_worker_failed: ${error.message}`));
    });
    child.on("close", (code, closeSignal) => {
      if (settled) return;
      settled = true; cleanup();
      if (terminationError) { reject(terminationError); return; }
      const line = stdout.trim().split(/\r?\n/).filter(Boolean).at(-1);
      let payload;
      try { payload = line ? JSON.parse(line) : null; }
      catch { reject(new Error(`kernel_worker_failed: invalid JSON response${stderr.trim() ? `; ${stderr.trim().slice(-1000)}` : ""}`)); return; }
      if (code !== 0 || !payload || payload.error) {
        const detail = payload?.error || stderr.trim() || `worker exited with code ${code}${closeSignal ? ` (${closeSignal})` : ""}`;
        reject(new Error(`kernel_worker_failed: ${detail}`)); return;
      }
      resolve(payload);
    });
    child.stdin.on("error", (error) => stop(new Error(`kernel_worker_failed: could not send request: ${error.message}`)));
    child.stdin.end(JSON.stringify(request));
  });
}

export function invokeKernel(request, { signal, timeoutMs } = {}) {
  return invokeKernelWorker(request, { signal, timeoutMs });
}
