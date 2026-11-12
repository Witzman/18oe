// JSON view model of lib/oe/view.rb (#35) and the envelope of lib/oe/games_api.rb (#36).
// Kept in sync by hand; spec/web_view_keys_spec.rb checks the key sets against
// web/view-keys.json, which mirrors the interfaces below.

export interface Account { id: string; name: string }

export interface Seat {
  seat: number;
  kind: "human" | "bot";
  name: string;
  account_id?: string;
}

export type SeatRequest = { kind: "human"; account_id: string } | { kind: "bot" };

export type RoundType = "auction" | "concession" | "stock" | "operating" | "consolidation";
export type EntityRef = { kind: "player" | "corporation"; id: string; owner?: string };

export interface Meta {
  seq: number;
  game_id: number | string;
  finished: boolean;
  round: { type: RoundType | string; number: number | null; turn: number; description: string | null };
  phase: { name: string; tiles: string[]; operating_rounds: number; status: string[] };
  current: EntityRef | null;
  active_players: string[];
  standings: { player: string; value: number }[];
  winner: string | null;
}

export interface PlayerShare { corporation: string; percent: number; president: boolean }
export interface PlayerCompany { id: string; name: string | null; value: number | null; face_down: boolean }
export interface Player {
  id: string; name: string; order: number; cash: number; value: number;
  certs: number; cert_limit: number; shares: PlayerShare[]; companies: PlayerCompany[];
}

export interface Train {
  id: string; name: string; price: number; distance: unknown;
  rusts_on: string | null; obsolete_on: string | null;
}
export interface Corporation {
  id: string; name: string; type: string; president: string | null;
  ipoed: boolean; floated: boolean; closed: boolean; cash: number;
  share_price: number | null; par_price: number | null;
  shares: { holder: string; percent: number }[];
  reserved: { percent: number; player: string | null } | null;
  trains: Train[];
  tokens: { used: boolean; hex: string | null }[];
  last_run: { revenue: number; dividend: string | null } | null;
  track_rights: string[];
  orient_express_marker: boolean;
  status: string[];
}

export interface MarketCell { price: number; type: string | null; corporations: string[] }
export interface HexChange {
  hex: string;
  tile: { name: string; rotation: number; color: string };
  tokens?: { city: number; corporations: (string | undefined)[] }[];
  patronage?: Record<string, unknown>;
}
export interface Prompt {
  step: string | null; types: string[]; viewer_to_act: boolean;
  actions: Record<string, unknown>[];
}

export interface GameState {
  meta: Meta;
  players: Player[];
  corporations: Corporation[];
  market: { rows: (MarketCell | null)[][] };
  depot: { available: (Train & { owner: string | null })[]; upcoming: number; next: string | null; discarded: string[] };
  bank: { cash: number };
  map: HexChange[];
  log: { action: number; text: string }[];
  prompt: Prompt;
}

export interface Game {
  id: number;
  status: string;
  seats: Seat[];
  viewer: string | null;
  seq: number;
  state: GameState;
}

export interface GameSummary { id: number; status: string; seats: Seat[]; seq: number; created_at: string }
export interface Version { seq: number; status: string }
