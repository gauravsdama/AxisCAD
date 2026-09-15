export interface KernelWorkerOptions {
  workerPath?: string;
  executable?: string;
  timeoutMs?: number;
  signal?: AbortSignal;
  env?: Record<string, string>;
}

export function invokeKernelWorker<T = Record<string, unknown>>(
  request: Record<string, unknown>,
  options?: KernelWorkerOptions
): Promise<T>;

export function invokeKernel<T = Record<string, unknown>>(
  request: Record<string, unknown>,
  options?: Pick<KernelWorkerOptions, "signal" | "timeoutMs">
): Promise<T>;
