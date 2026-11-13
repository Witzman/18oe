import assert from "node:assert/strict";
import { test } from "node:test";
import { applyAttention, faviconHref, pageTitle } from "../ui/attention.ts";

const colors = { accent: "#aa0000", panel: "#ffffff", ink: "#111111" };
const decode = (href: string) => decodeURIComponent(href.replace("data:image/svg+xml,", ""));

test("title: dot only when the viewer is to act; lobby without game number", () => {
  assert.equal(pageTitle(true, 12), "(●) 18OE · Partie 12");
  assert.equal(pageTitle(false, 12), "18OE · Partie 12");
  assert.equal(pageTitle(true, null), "(●) 18OE");
  assert.equal(pageTitle(false, null), "18OE");
});

test("favicon: the accent dot is there only when to act, colours come from the parameters", () => {
  const on = decode(faviconHref(true, colors));
  const off = decode(faviconHref(false, colors));
  assert.match(on, /<circle[^>]*fill="#aa0000"/);
  assert.doesNotMatch(off, /<circle/);
  assert.match(off, /fill="#ffffff"/);
});

test("applyAttention writes title and one icon link, reusing it on the next call", () => {
  const links: { rel: string; href: string; type: string }[] = [];
  const doc = {
    title: "",
    defaultView: null,
    head: { append: (l: { rel: string; href: string; type: string }) => links.push(l) },
    querySelector: () => links[0] ?? null,
    createElement: () => ({ rel: "", href: "", type: "" }),
  } as unknown as Document;
  applyAttention(true, 7, doc);
  assert.equal(doc.title, "(●) 18OE · Partie 7");
  assert.match(decode(links[0]!.href), /<circle/);
  applyAttention(false, 7, doc);
  assert.equal(doc.title, "18OE · Partie 7");
  assert.equal(links.length, 1);
  assert.doesNotMatch(decode(links[0]!.href), /<circle/);
});
