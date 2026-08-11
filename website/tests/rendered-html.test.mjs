import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("https://coderbar.example/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
}

test("server-renders the CoderBar product page", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>CoderBar — Native agent control for macOS<\/title>/i);
  assert.match(html, /Stay in flow/);
  assert.match(html, /Monitor/);
  assert.match(html, /Approve/);
  assert.match(html, /Ask/);
  assert.match(html, /Jump/);
  assert.match(html, /Local by design/i);
  assert.doesNotMatch(html, /codex-preview|loading skeleton|Starter Project/i);
});

test("ships product metadata and artwork without starter assets", async () => {
  const [page, layout, packageJson] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
    readFile(new URL("../package.json", import.meta.url), "utf8"),
  ]);

  assert.match(page, /CoderBar/);
  assert.match(layout, /openGraph/);
  assert.match(layout, /\/og\.png/);
  assert.match(packageJson, /"name": "coderbar-site"/);
  assert.doesNotMatch(page + layout + packageJson, /_sites-preview|react-loading-skeleton|codex-preview/);

  await Promise.all([
    access(new URL("../public/icon.png", import.meta.url)),
    access(new URL("../public/og.png", import.meta.url)),
    access(new URL("../public/product/coderbar-expanded.png", import.meta.url)),
    access(new URL("../public/downloads/CoderBar-macos.zip", import.meta.url)),
  ]);
});
