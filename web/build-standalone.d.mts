export function buildStandalone(options: { out: string; geometry: string; board: string }): Promise<{
  /** The files in the bundle, relative to web/. */
  inputs: string[];
  bytes: number;
  sizes: Record<string, { bytesInOutput: number }>;
}>;
