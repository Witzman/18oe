export interface AddonOptions { out: string; geometry: string; site?: boolean; release?: string }
export function buildAddon(options: AddonOptions): Promise<object>;
export function buildWithInputs(options: AddonOptions): Promise<{ manifest: { version: string }; inputs: string[] }>;
