import type { AddonOptions } from "./build-addon.mjs";
export function packAddon(options: AddonOptions): Promise<{ extension: string; source: string }>;
