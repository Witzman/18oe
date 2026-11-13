// Dev page #/map (#44): the map alone, full window, for looking at it and for screenshots.
//   #/map                     geometry from GET /map (needs a login)
//   #/map?src=map.json        geometry from another URL (bin/shot on a local copy, no server)
//   &pitch=60&yaw=0           camera override (theme values otherwise)
//   &cache=1                  cache static blocks as textures (measurement)
// The map is exposed as window.oeMap for bin/shot --eval.
import { ApiError, type Api } from "../api.ts";
import { mountMap, type MapView } from "../render/map.ts";
import type { MapGeometry } from "../render/mapdata.ts";
import { h } from "./dom.ts";

declare global {
  interface Window { oeMap?: MapView }
}

export function mapDevParams(hash: string): { src: string | null; pitch?: number; yaw?: number; cache: boolean } {
  const q = new URLSearchParams(hash.split("?")[1] ?? "");
  const num = (k: string) => (q.has(k) && Number.isFinite(Number(q.get(k))) ? Number(q.get(k)) : undefined);
  const out: { src: string | null; pitch?: number; yaw?: number; cache: boolean } = { src: q.get("src"), cache: q.get("cache") === "1" };
  const pitch = num("pitch"), yaw = num("yaw");
  if (pitch !== undefined) out.pitch = pitch;
  if (yaw !== undefined) out.yaw = yaw;
  return out;
}

export function mapDevPage(api: Api, hash: string): { root: HTMLElement; ready: Promise<MapView | null>; stop: () => void } {
  const p = mapDevParams(hash);
  const root = h("div", { class: "map-dev" });
  const status = h("p", { class: "map-dev-status" }, "Loading map …");
  root.append(status);
  let map: MapView | null = null;
  let stopped = false;
  const ready = (async () => {
    try {
      const geometry: MapGeometry = p.src ? await (await fetch(p.src)).json() : await api.map();
      if (stopped) return null;
      const camera: { pitch?: number; yaw?: number } = {};
      if (p.pitch !== undefined) camera.pitch = p.pitch;
      if (p.yaw !== undefined) camera.yaw = p.yaw;
      map = await mountMap(root, geometry, { camera, cache: p.cache });
      status.remove();
      window.oeMap = map;
      root.dataset.ready = "1";
      return map;
    } catch (e) {
      status.textContent = e instanceof ApiError && e.status === 401 ? "Bitte zuerst anmelden." : `Fehler: ${e instanceof Error ? e.message : String(e)}`;
      return null;
    }
  })();
  return { root, ready, stop: () => { stopped = true; map?.destroy(); delete window.oeMap; } };
}
