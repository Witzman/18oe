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

// A human seat names its player by `account` (name or e-mail, resolved server-side, #212)
// or by the opaque `account_id`; the creator must hold a seat themselves.
export type SeatRequest =
  | { kind: "human"; account: string }
  | { kind: "human"; account_id: string }
  | { kind: "bot" };

export type RoundType = "auction" | "concession" | "stock" | "operating" | "consolidation";
export type EntityRef = { kind: "player" | "corporation"; id: string; owner?: string };

export interface Meta {
  seq: number;
  game_id: number | string;
  finished: boolean;
  round: { type: RoundType | string; number: number | null; turn: number; description: string | null };
  phase: {
    name: string; tiles: string[]; operating_rounds: number; status: string[];
    train_limits: Record<string, number> | number | null; next: NextPhase | null;
  };
  current: EntityRef | null;
  active_players: string[];
  standings: { player: string; value: number }[];
  winner: string | null;
  rr_phase: "auction" | "concession" | "regional_minor" | "major" | "consolidation";
  railroads: Railroads;
  operating_order: { id: string; done: boolean }[];
  priority: string[];
}

export interface NextPhase {
  name: string; on: string | null; tiles: string[]; operating_rounds: number;
  train_limits: Record<string, number> | number | null;
}

export type RegionalState = "unparred" | "parred" | "floated" | "converted" | "removed" | "closed";
export interface Railroads {
  minors: { floated: number; total: number };
  regionals: {
    unparred: number; parred: number; floated: number; converted: number; removed: number; closed: number;
    total: number; max_floated: number; max_removed: number;
  };
  regional_states: { id: string; state: RegionalState }[];
}
export interface ConcessionEntry { id: string; name: string; owner: string | null; status: "done" | "current" | "open" }
export interface Zone {
  id: string; price: number; chits_left: number; free: boolean; taken_by: string[]; discount: number;
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
  last_run: {
    revenue: number; dividend: string | null;
    routes: {
      train: string; name: string; revenue: number; hexes: string[];
      segments: { hex: string; exits: number[]; nodes: number[] }[];
      stops: { hex: string; index: number; revenue: number }[];
    }[];
  } | null;
  track_rights: string[];
  orient_express_marker: boolean;
  status: string[];
  regional_state: RegionalState | null;
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
  unsupported: string[];
  ranges: { type: string; entity: string; company: string; min: number; max: number; step: number }[];
  actions: Record<string, unknown>[];
  // The active step's own texts (#124), English as in the engine; help is null when empty.
  description: string | null; help: string | null; pass_description: string | null;
  choice_name: string | null;
  choices: { choice: string; target: string | null; entity: string; label: string }[];
  acting_as: { entity: string; kind: "player" | "corporation"; primary: boolean; types: string[] }[];
  context: PromptContext;
}

// Numbers of the active operating step (#123); one family, the others null.
export interface TrackContext {
  points: { budget: number; used: number; left: number };
  // Only for the viewer to act (the enumeration costs): per buildable hex the
  // price for this corporation with its parts, the tile points, tiles + rotations.
  hexes: {
    hex: string; points: number; cost: number; cost_parts: { label: string; amount: number }[];
    tiles: { name: string; color: string; rotations: number[] }[];
  }[] | null;
}
export interface TokenContext {
  kind: "home" | "operating";
  price: number | null;
  tokens_left: number;
  cities: { hex: string; city: number; id: string; price: number }[] | null;
}
export interface DividendContext {
  revenue: number;
  options: {
    kind: string; per_share: number; treasury: number; withheld: number;
    direction: string[]; times: number[]; price: number | null;
  }[];
}
export interface TrainContext {
  limit: number; count: number; must_buy: boolean;
  obligation: { active: boolean; fulfilled: boolean };
  reserved: { name: string; price: number } | null;
  cheapest_price: number | null; president_may_contribute: boolean; shortfall: number;
}
export interface PromptContext {
  track: TrackContext | null; token: TokenContext | null;
  dividend: DividendContext | null; train: TrainContext | null;
}

export interface AuctionCard {
  id: string; name: string; kind: "private" | "minor" | "concession";
  row: number; value: number; revenue: number; discount: number; min_bid: number;
  bid: { player: string; price: number } | null;
}
export interface Auction {
  top_row: number | null; increment: number; cards: AuctionCard[];
  current: string | null; to_act: string[]; passed: string[]; open_bidders: string[];
}

export interface CompanyState {
  id: string; kind: "private" | "minor" | "concession";
  owner: { kind: "player" | "corporation" | "bank" | "other"; id: string | null } | null;
  closed: boolean; face_down: boolean;
  abilities: { type: string; used: boolean; remaining: number | null }[];
}

// GET /catalog (#124): the static cards, never changes within a build.
export interface CatalogCard {
  id: string; name: string; value: number; revenue: number; text: string; auction_row: number; abilities: string[];
}
export interface Catalog {
  schema: number;
  privates: CatalogCard[];
  concessions: CatalogCard[];
  minors: {
    id: string; name: string; color: string; text_color: string | null; token_prices: number[]; text: string;
    charter: CatalogCard;
  }[];
  regionals: {
    id: string; name: string; home: string; zone: string | null; color: string; text_color: string | null;
    token_prices: number[]; shares: number[]; float_percent: number; text: string;
  }[];
}

export interface GameState {
  meta: Meta;
  players: Player[];
  corporations: Corporation[];
  market: { rows: (MarketCell | null)[][] };
  depot: {
    available: (Train & { owner: string | null })[]; upcoming: number; next: string | null; discarded: string[];
    schedule: {
      name: string; count: number; price: number; phase_on: string | null;
      rusts_on: string | null; obsolete_on: string | null; available_on: string | null;
    }[];
  };
  tiles: { name: string; color: string; remaining: number; unlimited: boolean; available: boolean }[];
  bank: { cash: number };
  auction: Auction | null;
  concession: ConcessionEntry[] | null;
  companies: CompanyState[];
  zones: Zone[];
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
