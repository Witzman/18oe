import { createApi, ApiError } from "./api.ts";
import { createPoller } from "./poller.ts";
import { createSession } from "./session.ts";
import type { MapGeometry } from "./render/mapdata.ts";
import type { Account } from "./types.ts";
import { h, mount } from "./ui/dom.ts";
import { kitPage } from "./ui/kit/page.ts";
import { mapDevPage } from "./ui/mapdev.ts";
import { accessPage, resetPage } from "./ui/access.ts";
import { loadGeometry } from "./ui/frame/mapview.ts";
import { mountConcession } from "./ui/panels/concession.ts";
import { mountTrain } from "./ui/panels/train.ts";
import { mountTrack } from "./ui/panels/track.ts";
import { mountToken } from "./ui/panels/token.ts";
import { gameFrame, gamesPage, notFoundPage, type Ctx } from "./ui/pages.ts";
import { applyAttention, watchTheme } from "./ui/attention.ts";
import { initTheme, themeSwitch } from "./ui/theme-switch.ts";

initTheme();
watchTheme();
applyAttention(false, null);
const root = document.getElementById("app")!;
document.body.append(themeSwitch());
const api = createApi();
const ctx: Ctx = { api, me: null, go: (hash) => { location.hash = hash; } };
let poller: ReturnType<typeof createPoller> | null = null;
let page: { stop: () => void } | null = null;
// After a 401 the player logs in again and lands on the same game and view (#162).
let returnTo: string | null = null;

async function route() {
  poller?.stop();
  poller = null;
  page?.stop();
  page = null;
  applyAttention(false, null);
  if (location.hash === "#/kit") { mount(root, kitPage()); return; }
  if (/^#\/map(\?|$)/.test(location.hash)) {
    const dev = mapDevPage(api, location.hash);
    page = dev;
    mount(root, dev.root);
    return;
  }
  try {
    if (!ctx.me) ctx.me = await api.me().catch((e: unknown) => {
      if (e instanceof ApiError && e.status === 401) return null;
      throw e;
    });
    if (!ctx.me && location.hash === "#/reset") { mount(root, resetPage(api)); return; }
    if (!ctx.me) {
      mount(root, accessPage(api, location.hash === "#/register" ? "register" : "login", (me: Account) => { ctx.me = me; const back = returnTo; returnTo = null; if (back && back !== location.hash) location.hash = back; else if (back) void route(); else { location.hash = "#/"; void route(); } }));
      return;
    }
    const game = /^#\/game\/(\d+)$/.exec(location.hash);
    if (game) {
      const gameId = Number(game[1]);
      const hash = location.hash;
      const toLogin = () => { returnTo = hash; ctx.me = null; void route(); };
      let self: ReturnType<typeof createPoller>;
      const frame = gameFrame(() => void self.tick(), api);
      page = { stop: () => frame.dispose() };
      mount(root, frame.root);
      let mapGeometry: MapGeometry | null = null;
      const concession = mountConcession(frame, { map: () => mapGeometry });
      mountTrain(frame);
      const track = mountTrack(frame, { map: () => mapGeometry });
      mountToken(frame);
      // Hex names and zones for the home token step; the panel works without them (hex ids only).
      void loadGeometry(api).then((m) => { mapGeometry = m; concession.refresh(); track.refresh(); }, () => {});
      // #294: display errors (a panel, the map or the frame threw on a state) go to the server log once per
      // message, so a failure in a player's browser is visible without their DevTools.
      const reported = new Set<string>();
      const report = (e: unknown) => {
        const key = e instanceof Error ? `${e.name}: ${e.message}` : String(e);
        if (reported.has(key) || reported.size >= 10) return;
        reported.add(key);
        void api.clientError(gameId, e).catch(() => {});
      };
      frame.hooks.onRenderError = report;
      self = poller = createPoller({
        api, gameId,
        onGame: (g) => { frame.render(g); applyAttention(g.state.prompt.viewer_to_act, gameId); },
        onUnauthorized: toLogin,
        onOk: () => frame.band.ok(),
        onRetryIn: (ms, why) => frame.band.failed(ms, why),
        // #294: a display error outside the panels; the band names it, the console has the stack, the server log a line.
        onRenderError: (e) => { console.error("game state could not be drawn", e); report(e); },
        onError: (e) => {
          if (e.status === 404) { self.stop(); mount(root, notFoundPage()); }
          else if (e.status !== 0 && e.status < 500) frame.message.say(e.message, "error");
        },
        isVisible: () => !document.hidden,
      });
      frame.session = createSession({
        api, gameId, poller: self,
        say: frame.message.say, clearMessage: frame.message.clear, setBusy: frame.setBusy,
        discardSelection: frame.discardSelection,
        onUnauthorized: toLogin,
        onNotFound: () => { self.stop(); mount(root, notFoundPage()); },
      });
      frame.reload = () => { void api.getGame(gameId).then((g) => self.adopt(g), () => {}); };
      poller.start();
    } else {
      mount(root, await gamesPage(ctx));
    }
  } catch (e) {
    // Session ended while the lobby loaded: back to the login page.
    if (e instanceof ApiError && e.status === 401) { ctx.me = null; mount(root, accessPage(api, "login", (me: Account) => { ctx.me = me; void route(); })); return; }
    mount(root, h("p", { class: "error" }, e instanceof Error ? e.message : String(e)));
  }
}

window.addEventListener("hashchange", () => void route());
document.addEventListener("visibilitychange", () => { if (!document.hidden) void poller?.tick(); });
void route();
