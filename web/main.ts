import { createApi, ApiError } from "./api.ts";
import { createPoller } from "./poller.ts";
import { createSession } from "./session.ts";
import type { Account } from "./types.ts";
import { h, mount } from "./ui/dom.ts";
import { kitPage } from "./ui/kit/page.ts";
import { mapDevPage } from "./ui/mapdev.ts";
import { accessPage } from "./ui/access.ts";
import { gameFrame, gamesPage, notFoundPage, type Ctx } from "./ui/pages.ts";
import { initTheme, themeSwitch } from "./ui/theme-switch.ts";

initTheme();
const root = document.getElementById("app")!;
document.body.append(themeSwitch());
const api = createApi();
const ctx: Ctx = { api, me: null, accounts: [], go: (hash) => { location.hash = hash; } };
let poller: ReturnType<typeof createPoller> | null = null;
let page: { stop: () => void } | null = null;
// After a 401 the player logs in again and lands on the same game and view (#162).
let returnTo: string | null = null;

async function route() {
  poller?.stop();
  poller = null;
  page?.stop();
  page = null;
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
      const frame = gameFrame(() => void self.tick());
      mount(root, frame.root);
      self = poller = createPoller({
        api, gameId, onGame: frame.render,
        onUnauthorized: toLogin,
        onOk: () => frame.band.ok(),
        onRetryIn: (ms) => frame.band.failed(ms),
        onError: (e) => {
          if (e.status === 404) { self.stop(); mount(root, notFoundPage()); }
          else if (e.status !== 0) frame.message.say(e.message, "error");
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
      poller.start();
    } else {
      mount(root, await gamesPage(ctx));
    }
  } catch (e) {
    mount(root, h("p", { class: "error" }, e instanceof Error ? e.message : String(e)));
  }
}

window.addEventListener("hashchange", () => void route());
document.addEventListener("visibilitychange", () => { if (!document.hidden) void poller?.tick(); });
void route();
