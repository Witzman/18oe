// The view "Karte" of the game frame (#258): mounts the renderer (#44) into the main area with the real
// GET /map data (loaded once per session, cached) and feeds it the game state of every poll (the renderer
// diffs per hex, tilestate.ts). The map lives in its own host element that outlives view switches, so camera
// and zoom stay; the renderer follows the element size itself (ResizeObserver). Clicks reach the frame
// through `frame.hooks.map` for the track and token panels (#48, #174).
import type { Api } from "../../api.ts";
import type { Game } from "../../types.ts";
import { mountMap, type MapEvent, type MapEventData, type MapView } from "../../render/map.ts";
import type { MapGeometry } from "../../render/mapdata.ts";
import { h } from "../dom.ts";
import { txt } from "../text.ts";
import type { GameFrame } from "./frame.ts";

declare global {
  interface Window { oeFrameMap?: FrameMap }
}

export interface FrameMap {
  /** Subscribes to a map event ("hex", "city", "hover"); survives the map being mounted later. Returns the unsubscribe. */
  on(event: MapEvent, handler: (data: MapEventData) => void): () => void;
  /** The mounted map, null while loading or after a failure. */
  readonly view: MapView | null;
  /** Resolves with the map once it is up (null on failure or dispose). */
  ready(): Promise<MapView | null>;
}

// One load per session and api object: /map does not depend on the game (ETag revalidates on reload).
const cache = new WeakMap<Api, Promise<MapGeometry>>();
export function loadGeometry(api: Api): Promise<MapGeometry> {
  let p = cache.get(api);
  if (!p) {
    p = api.map();
    cache.set(api, p);
    p.catch(() => { if (cache.get(api) === p) cache.delete(api); }); // a failure is not cached: retry fetches again
  }
  return p;
}

export function mountMapView(frame: GameFrame, api: Api): () => void {
  const host = h("div", { class: "frame-map" });
  const status = h("div", { class: "frame-map-status", role: "status" });
  const retry = h("button", { type: "button", class: "frame-map-retry" }, txt("map.retry").de);
  let map: MapView | null = null;
  let game: Game | null = null;
  let loading: Promise<MapView | null> | null = null;
  let disposed = false;
  const subs = new Map<MapEvent, Set<(d: MapEventData) => void>>();
  const unsubs: (() => void)[] = [];

  const say = (key: string | null, withRetry = false) => {
    status.replaceChildren(...(key ? [h("p", {}, txt(key).de), ...(withRetry ? [retry] : [])] : []));
    status.hidden = key === null;
  };
  const emit = (event: MapEvent) => (d: MapEventData) => { for (const f of subs.get(event) ?? []) f(d); };

  function load(): Promise<MapView | null> {
    if (map) return Promise.resolve(map);
    if (loading) return loading;
    say("map.loading");
    host.dataset.state = "loading";
    loading = (async () => {
      try {
        const geometry = await loadGeometry(api);
        if (disposed) return null;
        const m = await mountMap(host, geometry);
        if (disposed) { m.destroy(); return null; }
        map = m;
        for (const ev of ["hex", "city", "hover"] as const) unsubs.push(m.on(ev, emit(ev)));
        if (game) m.setState(game);
        say(null);
        host.dataset.state = "ready";
        // Test and screenshot handle, like the dev page (#44).
        window.oeMap = m;
        window.oeFrameMap = frame.hooks.map;
        return m;
      } catch (e) {
        if (disposed) return null;
        const status401 = (e as { status?: number }).status === 401;
        say(status401 ? "map.unauthorized" : "map.error", !status401);
        host.dataset.state = "error";
        return null;
      } finally { loading = null; }
    })();
    return loading;
  }
  retry.onclick = () => { void load(); };
  host.append(status);

  const offGame = frame.subscribe((g) => { game = g; map?.setState(g); });

  frame.views.register({
    id: "map", labelKey: "frame.view_map",
    render: ({ container }) => {
      // The frame clears the container on view switches; the host (and the map in it) is only re-attached.
      if (host.parentElement !== container) container.append(host);
      if (!map && !loading && host.dataset.state !== "error") void load();
    },
  });

  frame.hooks.map = {
    on(event, handler) {
      let s = subs.get(event);
      if (!s) subs.set(event, (s = new Set()));
      s.add(handler);
      return () => s!.delete(handler);
    },
    get view() { return map; },
    ready: () => (map ? Promise.resolve(map) : loading ?? Promise.resolve(null)),
  };
  // "Heimat auf der Karte zeigen" (outliner): switch to the map and fly there.
  frame.hooks.onFocusCorporation = (id) => { frame.views.activate("map"); void load().then((m) => m?.flyTo(id)); };

  return () => {
    disposed = true;
    offGame();
    unsubs.forEach((f) => f());
    map?.destroy();
    if (window.oeMap === map) { delete window.oeMap; delete window.oeFrameMap; }
    map = null;
    host.remove();
  };
}
