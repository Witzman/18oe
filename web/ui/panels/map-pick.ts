// Shared map binding of the operating panels that pick on the map (#48 track, #174 token): the panel says
// which targets glow and what the preview shows; this keeps it on the map, also when the map is mounted
// later than the panel, and clears only what this panel set. Map clicks reach the panel through
// `frame.hooks.map.on` (mapview.ts), which survives the map being mounted later.
import type { MapEvent, MapEventData, MapPreview, MapTargets, MapView } from "../../render/map.ts";
import type { MapRun } from "../../render/layers/runs.ts";
import type { GameFrame } from "../frame/frame.ts";

export interface MapPick {
  /** Targets and preview to show; null clears both (only if this panel set them). */
  show(targets: MapTargets | null, preview: MapPreview, run?: MapRun | null): void;
  /** Fly to a hex if the map is up. */
  flyTo(hex: string): void;
  /** Switch the main area to the map view. */
  toMap(): void;
  on(event: MapEvent, handler: (d: MapEventData) => void): () => void;
  stop(): void;
}

// Which pick set the map's targets last, per frame: a panel clears only its own marks, so the order in which
// the panels see a new state (one leaving its step, the next entering) does not matter.
const lastSetter = new WeakMap<GameFrame, object>();

export function mapPick(frame: GameFrame): MapPick {
  const me = {};
  let want: { targets: MapTargets | null; preview: MapPreview; run: MapRun | null } = { targets: null, preview: null, run: null };
  let owns = false;
  let waiting = false;
  const offs: (() => void)[] = [];

  function apply(m: MapView) {
    if (!want.targets && !want.preview && !want.run) {
      if (owns && lastSetter.get(frame) === me) { m.setTargets(null); m.setPreview(null); m.showRoutes(null); }
      owns = false;
      return;
    }
    m.setTargets(want.targets);
    m.setPreview(want.preview);
    m.showRoutes(want.run);
    owns = true;
    lastSetter.set(frame, me);
  }

  function push() {
    const fm = frame.hooks.map;
    if (!fm) return;
    if (fm.view) { apply(fm.view); return; }
    if (waiting) return;
    waiting = true;
    void fm.ready().then((m) => { waiting = false; if (m) apply(m); });
  }

  return {
    show(targets, preview, run = null) {
      const same = JSON.stringify(targets) === JSON.stringify(want.targets) && JSON.stringify(preview) === JSON.stringify(want.preview)
        && JSON.stringify(run) === JSON.stringify(want.run);
      want = { targets, preview, run };
      if (!same || ((targets || run) && !owns)) push();
    },
    flyTo(hex) { frame.hooks.map?.view?.flyTo(hex); },
    toMap() { frame.views.activate("map"); },
    on(event, handler) {
      const off = frame.hooks.map?.on(event, handler) ?? (() => {});
      offs.push(off);
      return off;
    },
    stop() { want = { targets: null, preview: null, run: null }; push(); offs.splice(0).forEach((f) => f()); },
  };
}
