export interface AddonOptions { out: string; site?: boolean; release?: string }
export function withoutGameData(theme: string): string;
export function buildAddon(options: AddonOptions): Promise<object>;
export function buildWithInputs(options: AddonOptions): Promise<{ manifest: { version: string }; inputs: string[] }>;
