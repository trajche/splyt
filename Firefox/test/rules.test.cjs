const test = require("node:test");
const assert = require("node:assert/strict");
const rules = require("../extension/rules.js");

function state(change = {}) {
  const base = rules.defaultState();
  base.settings = { ...base.settings, vpnPort: 18230, directPort: 18231, token: "abc" };
  Object.assign(base.rules, change);
  return base;
}

const page = (url, extra = {}) => ({ type: "main_frame", url, tabId: 1, cookieStoreId: "firefox-default", ...extra });

test("precedence is tab, site, container, profile", () => {
  const all = state({
    profile: "direct",
    containers: { "firefox-container-1": "block" },
    sites: { "example.com": "vpn" },
  });
  const request = page("https://example.com/", { cookieStoreId: "firefox-container-1" });
  assert.deepEqual(rules.resolve(all, request, "system"), { route: "system", source: "tab" });
  assert.equal(rules.resolve(all, request).source, "site");
  assert.equal(rules.resolve(all, { ...request, url: "https://other.com/" }).route, "block");
  assert.equal(rules.resolve(all, page("https://other.com/")).route, "direct");
});

test("a site rule covers subdomains but not lookalikes, and the longest match wins", () => {
  const sites = { "example.com": "vpn", "mail.example.com": "direct" };
  assert.equal(rules.siteRule(sites, "www.example.com").route, "vpn");
  assert.equal(rules.siteRule(sites, "a.mail.example.com").route, "direct");
  assert.equal(rules.siteRule(sites, "notexample.com"), null);
});

test("a site rule follows the page, so third-party requests stay on its route", () => {
  const s = state({ sites: { "example.com": "vpn" } });
  const subresource = {
    type: "script", url: "https://cdn.other.net/a.js", tabId: 1,
    documentUrl: "https://example.com/",
  };
  assert.equal(rules.resolve(s, subresource).route, "vpn");
  const nested = {
    type: "image", url: "https://img.other.net/a.png", tabId: 1,
    documentUrl: "https://frame.other.net/",
    frameAncestors: [{ url: "https://mid.other.net/" }, { url: "https://example.com/" }],
  };
  assert.equal(rules.resolve(s, nested).route, "vpn");
});

test("Firefox's own requests are never proxied, whatever the rules say", () => {
  const s = state({ profile: "vpn" });
  const system = { type: "xmlhttprequest", url: "https://aus5.mozilla.org/update", tabId: -1 };
  assert.deepEqual(rules.resolve(s, system), { route: "system", source: "firefox" });
  const extension = { ...system, originUrl: "moz-extension://abc/background.html" };
  assert.equal(rules.resolve(s, extension).route, "system");
});

test("service workers have no tab but still follow rules", () => {
  const s = state({ sites: { "example.com": "vpn" } });
  const worker = {
    type: "xmlhttprequest", url: "https://api.other.net/", tabId: -1,
    originUrl: "https://example.com/sw.js",
  };
  assert.equal(rules.resolve(s, worker).route, "vpn");
});

test("local destinations keep their route unless blocked", () => {
  const s = state({ profile: "vpn" });
  for (const url of ["http://localhost:3000/", "http://printer.local/", "http://192.168.1.1/",
    "http://100.125.226.85/", "http://[fd00::1]/", "https://peer.netbird.cloud/"]) {
    assert.deepEqual(rules.resolve(s, page(url)), { route: "system", source: "bypass" }, url);
  }
  assert.equal(rules.resolve(s, page("http://192.168.1.1/"), "block").route, "block");
  assert.equal(rules.resolve(s, page("https://8.8.8.8/")).route, "vpn");
  assert.equal(rules.resolve(s, page("https://172.32.0.1/")).route, "vpn");
});

test("proxy info never includes a way to escape the route", () => {
  const { settings } = state();
  assert.deepEqual(rules.proxyInfo("vpn", settings), {
    type: "socks", host: "127.0.0.1", port: 18230, username: "splyt", password: "abc",
    proxyDNS: true, failoverTimeout: 5,
  });
  assert.equal(rules.proxyInfo("direct", settings).port, 18231);
  assert.deepEqual(rules.proxyInfo("system", settings), { type: "direct" });
  assert.equal(rules.proxyInfo("block", settings).port, 1);
});

test("VPN and Direct fail closed until paired", () => {
  const unpaired = rules.defaultState().settings;
  assert.equal(rules.proxyInfo("vpn", unpaired).port, 1);
  assert.equal(rules.proxyInfo("direct", unpaired).port, 1);
  assert.equal(rules.proxyInfo("system", unpaired).type, "direct");
});

test("pairing codes are validated", () => {
  const token = "a".repeat(64);
  assert.deepEqual(rules.parsePairing(` 18230:18231:${token}\n`), { vpnPort: 18230, directPort: 18231, token });
  for (const bad of ["", "nope", `70000:18231:${token}`, `18230:18230:${token}`, "1:2:short", `0:2:${token}`]) {
    assert.equal(rules.parsePairing(bad), null, bad);
  }
});

test("typed sites are normalised", () => {
  assert.equal(rules.normalizeSite(" HTTPS://www.Example.com/path "), "www.example.com");
  assert.equal(rules.normalizeSite("example.com"), "example.com");
  assert.equal(rules.normalizeSite("  "), null);
});
