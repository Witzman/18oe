export interface Scene { name: string; title: string; fixture: string; eval?: string }
export function loadScenes(file?: string): Scene[];
export function pickScenes(scenes: Scene[], names: string[]): Scene[];
