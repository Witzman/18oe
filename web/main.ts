import { createApi, ApiError } from "./api.ts";
import { createPoller } from "./poller.ts";
import type { Account } from "./types.ts";
import { h, mount } from "./ui/dom.ts";
import { kitPage } from "./ui/kit/page.ts";
import { mapDevPage } from "./ui/mapdev.ts";
import { gameFrame, gamesPage, loginPage, type Ctx } from "./ui/pages.ts";
import { initTheme, themeSwitch } from "./ui/theme-switch.ts";

initTheme();
const root = document.getElementById("app")!;
document.body.append(themeSwitch());
const api = createApi();
const ctx: Ctx = { api, me: null, accounts: [], go: (hash) => { location.hash = hash; } };
let poller: ReturnType<typeof createPoller> | null = null;
let page: { stop: () => void } | null = null;

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
      mount(root, loginPage(ctx, (me: Account) => { ctx.me = me; location.hash = "#/"; void route(); }));
      return;
    }
    const game = /^#\/game\/(\d+)$/.exec(location.hash);
    if (game) {
      const frame = gameFrame();
      mount(root, frame.root);
      poller = createPoller({
        api, gameId: Number(game[1]), onGame: frame.render,
        onUnauthorized: () => { ctx.me = null; void route(); },
        onError: (e) => frame.root.append(h("p", { class: "error" }, e.message)),
        isVisible: () => !document.hidden,
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
