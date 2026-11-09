// End-to-end test in real Firefox, using a throwaway headless profile.
//
// Needs a VPN that owns the default route. It compares each route's public IP with
// the Mac's own, then checks the failure paths: nothing may reach the IP service
// outside its route when the proxy is down, unpaired or given a wrong password.
//
// Usage: node Firefox/test/e2e.mjs [firefox binary]
// Build the helper first: (cd SplytCore && swift build --product splyt-socks)

import { execFileSync, spawn } from "node:child_process";
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "../..");
const firefox = process.argv[2] ?? "/Applications/Firefox.app/Contents/MacOS/firefox";
const socksBinary = join(root, "SplytCore/.build/debug/splyt-socks");
const extensionSource = join(root, "Firefox/extension");
const debugPort = 19876;
const controlPort = 19877;
const vpnPort = 28230;
const directPort = 28231;
const token = "e2e0123456789abcdef0123456789abc";
const uuid = "6f7c1a52-0f3b-4f0e-9a44-53c0a1f7c001";
const extensionId = "splyt@firefox";
const ipService = "https://api.ipify.org/";
const pair = `${vpnPort}:${directPort}:${token}`;

const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const results = [];

function check(name, passed, detail = "") {
  results.push(passed);
  console.log(`${passed ? "ok  " : "FAIL"} ${name}${detail ? `  (${detail})` : ""}`);
}

function curlIP(...args) {
  return execFileSync("curl", ["-s", "--max-time", "10", ...args, ipService]).toString().trim();
}

function startSocks(password = token) {
  const child = spawn(socksBinary, [password, String(vpnPort), String(directPort)]);
  child.log = [];
  child.stdout.on("data", (data) => child.log.push(...data.toString().trim().split("\n")));
  return child;
}

async function stopSocks(child) {
  child.kill();
  await new Promise((done) => child.once("exit", done));
}

class BiDi {
  static async connect() {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      try {
        const socket = new WebSocket(`ws://127.0.0.1:${debugPort}/session`);
        await new Promise((done, fail) => {
          socket.onopen = done;
          socket.onerror = () => fail(new Error("connect failed"));
        });
        return new BiDi(socket);
      } catch {
        await sleep(200);
      }
    }
    throw new Error("Firefox did not open its debugging port");
  }

  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      const waiter = this.pending.get(message.id);
      if (waiter) {
        this.pending.delete(message.id);
        message.type === "error" ? waiter.fail(new Error(message.message ?? message.error)) : waiter.done(message.result);
      }
    };
  }

  send(method, params = {}) {
    const id = this.nextId++;
    return new Promise((done, fail) => {
      this.pending.set(id, { done, fail });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }
}

// Added to a temporary copy of the extension, so it runs beside the code under
// test. It takes commands from this script over loopback HTTP.
const driverSource = `
  const pause = (ms) => new Promise((r) => setTimeout(r, ms));
  const driver = {
    send: (message) => handleMessage(message),
    async load(tabId, url) {
      await browser.tabs.update(tabId, { url });
      await pause(300);
      const deadline = Date.now() + 25000;
      while (Date.now() < deadline) {
        const tab = await browser.tabs.get(tabId);
        if (tab.status === "complete") break;
        await pause(100);
      }
      await pause(200);
      try {
        const [text] = await browser.tabs.executeScript(tabId, { code: "document.body.innerText" });
        return (text || "").trim().slice(0, 64);
      } catch {
        return "LOAD-FAILED";
      }
    },
    async visit(url, { route, cookieStoreId } = {}) {
      const tab = await browser.tabs.create({ url: "about:blank", active: false, cookieStoreId });
      if (route) await driver.send({ type: "set-rule", level: "tab", tabId: tab.id, route });
      const text = await driver.load(tab.id, url);
      await browser.tabs.remove(tab.id);
      return text;
    },
    async privacy() {
      const { webRTCIPHandlingPolicy, networkPredictionEnabled } = browser.privacy.network;
      return {
        webrtc: (await webRTCIPHandlingPolicy.get({})).value,
        prediction: (await networkPredictionEnabled.get({})).value,
      };
    },
    async createContainer() {
      const identity = await browser.contextualIdentities.create({ name: "E2E", color: "blue", icon: "circle" });
      return identity.cookieStoreId;
    },
    async openedTab(url, features) {
      const opener = await browser.tabs.create({ url: "about:blank", active: true });
      await driver.send({ type: "set-rule", level: "tab", tabId: opener.id, route: "direct" });
      await driver.load(opener.id, url);
      const created = new Promise((r) => browser.tabs.onCreated.addListener(function seen(tab) {
        browser.tabs.onCreated.removeListener(seen);
        r(tab);
      }));
      await browser.tabs.executeScript(opener.id, {
        code: "void window.open(" + JSON.stringify(url) + ", '_blank', " + JSON.stringify(features) + ")",
      });
      const child = await created;
      const text = await driver.load(child.id, url);
      const info = await driver.send({ type: "describe", tabId: child.id });
      await browser.tabs.remove([opener.id, child.id]);
      return { text, route: info.routes.tab, opener: child.openerTabId };
    },
  };
  (async () => {
    await ready;
    for (;;) {
      const command = await (await fetch("http://127.0.0.1:${controlPort}/next")).json();
      let reply;
      try {
        reply = { value: await driver[command.op](...command.args) };
      } catch (error) {
        reply = { error: String(error) };
      }
      await fetch("http://127.0.0.1:${controlPort}/result/" + command.id, { method: "POST", body: JSON.stringify(reply) });
    }
  })();
`;

function startControl() {
  const queue = [];
  const waiters = [];
  const results = new Map();
  let nextId = 1;
  const server = createServer((request, response) => {
    if (request.url === "/next") {
      const respond = (command) => response.end(JSON.stringify(command));
      queue.length ? respond(queue.shift()) : waiters.push(respond);
      return;
    }
    let body = "";
    request.on("data", (chunk) => { body += chunk; });
    request.on("end", () => {
      const id = Number(request.url.split("/").pop());
      const reply = JSON.parse(body);
      reply.error ? results.get(id).fail(new Error(reply.error)) : results.get(id).done(reply.value);
      results.delete(id);
      response.end();
    });
  });
  server.listen(controlPort, "127.0.0.1");
  const call = (op, ...args) => new Promise((done, fail) => {
    const command = { id: nextId++, op, args };
    results.set(command.id, { done, fail });
    waiters.length ? waiters.shift()(command) : queue.push(command);
  });
  return { call, close: () => { server.closeAllConnections(); server.close(); } };
}

async function main() {
  const profile = mkdtempSync(join(tmpdir(), "splyt-e2e-"));
  const extensionPath = mkdtempSync(join(tmpdir(), "splyt-e2e-ext-"));
  cpSync(extensionSource, extensionPath, { recursive: true });
  const manifest = JSON.parse(readFileSync(join(extensionPath, "manifest.json")));
  manifest.background.scripts.push("e2e-driver.js");
  writeFileSync(join(extensionPath, "manifest.json"), JSON.stringify(manifest));
  writeFileSync(join(extensionPath, "e2e-driver.js"), driverSource);
  const control = startControl();
  writeFileSync(join(profile, "user.js"), [
    `user_pref("extensions.webextensions.uuids", ${JSON.stringify(JSON.stringify({ [extensionId]: uuid }))});`,
    `user_pref("browser.shell.checkDefaultBrowser", false);`,
    `user_pref("datareporting.policy.dataSubmissionEnabled", false);`,
    `user_pref("browser.aboutwelcome.enabled", false);`,
  ].join("\n"));
  const browser = spawn(firefox, [
    "--headless", "--no-remote", "--profile", profile, `--remote-debugging-port=${debugPort}`,
  ], { stdio: "ignore" });

  let socks = startSocks();
  try {
    const home = curlIP("--interface", "en0");
    const exit = curlIP();
    console.log(`Mac on en0: ${home}, default route: ${exit}`);
    if (home === exit) {
      throw new Error("The default route is not a VPN, so routes cannot be told apart");
    }

    const bidi = await BiDi.connect();
    await bidi.send("session.new", { capabilities: {} });
    await bidi.send("webExtension.install", { extensionData: { type: "path", path: extensionPath } });
    const visit = (url, options = {}) => control.call("visit", url, options);
    const rule = (level, key, route) => control.call("send", { type: "set-rule", level, key, route });
    const setCode = (code) => {
      const [vpn, direct, secret] = code.split(":");
      return control.call("send", {
        type: "set-settings",
        change: { vpnPort: Number(vpn), directPort: Number(direct), token: secret },
      });
    };

    const privacy = await control.call("privacy");
    check("leak protection applied", privacy.webrtc === "disable_non_proxied_udp" && privacy.prediction === false,
      JSON.stringify(privacy));

    // Unpaired, routed tabs must fail and unrouted tabs must keep working.
    check("unpaired: VPN tab is blocked", (await visit(ipService, { route: "vpn" })) === "LOAD-FAILED");
    check("unpaired: Direct tab is blocked", (await visit(ipService, { route: "direct" })) === "LOAD-FAILED");
    const unrouted = await visit(ipService);
    check("no rule: normal route", unrouted === exit, unrouted);

    await setCode(pair);

    const [vpnTab, directTab] = await Promise.all([
      visit(ipService, { route: "vpn" }),
      visit(ipService, { route: "direct" }),
    ]);
    check("tab rule: VPN tab leaves by exit node", vpnTab === exit, vpnTab);
    check("tab rule: Direct tab leaves by en0", directTab === home, directTab);
    check("tab rule: VPN tab really used the VPN listener", socks.log.includes("vpn api.ipify.org"));
    check("tab rule: Direct tab really used the Direct listener", socks.log.includes("direct api.ipify.org"));
    check("tab rule: Block tab fails", (await visit(ipService, { route: "block" })) === "LOAD-FAILED");

    await rule("site", "api.ipify.org", "direct");
    const site = await visit(ipService);
    check("site rule: Direct", site === home, site);
    const tabWins = await visit(ipService, { route: "vpn" });
    check("precedence: tab beats site", tabWins === exit, tabWins);
    await rule("site", "api.ipify.org", null);

    const container = await control.call("createContainer");
    await rule("container", container, "direct");
    const inContainer = await visit(ipService, { cookieStoreId: container });
    const outside = await visit(ipService);
    check("container rule: tab in container is Direct", inContainer === home, inContainer);
    check("container rule: tab outside is unaffected", outside === exit, outside);
    await rule("container", container, null);

    await rule("profile", null, "direct");
    const profileDefault = await visit(ipService);
    check("profile default: Direct", profileDefault === home, profileDefault);
    await rule("profile", null, "system");

    // A tab opened by a routed tab must keep that route.
    const inherited = await control.call("openedTab", ipService, "");
    check("opened tab inherits its opener's route", inherited.text === home && inherited.route === "direct",
      JSON.stringify(inherited));

    const noopener = await control.call("openedTab", ipService, "noopener");
    check("noopener tab inherits its opener's route", noopener.text === home && noopener.route === "direct",
      JSON.stringify(noopener));

    // Wrong password.
    await setCode(`${vpnPort}:${directPort}:ffffffffffffffffffffffffffffffff`);
    check("wrong password: VPN tab fails", (await visit(ipService, { route: "vpn" })) === "LOAD-FAILED");
    check("wrong password: Direct tab fails", (await visit(ipService, { route: "direct" })) === "LOAD-FAILED");
    await setCode(pair);

    // The proxy is gone, as when Splyt is off. Repeat to catch any delayed failover.
    const firstLog = socks.log;
    await stopSocks(socks);
    for (let round = 1; round <= 3; round += 1) {
      const [vpn, direct] = await Promise.all([
        visit(ipService, { route: "vpn" }), visit(ipService, { route: "direct" }),
      ]);
      check(`proxy down, round ${round}: VPN tab fails`, vpn === "LOAD-FAILED", vpn);
      check(`proxy down, round ${round}: Direct tab fails`, direct === "LOAD-FAILED", direct);
    }
    const stillOK = await visit(ipService);
    check("proxy down: unrouted tab still works", stillOK === exit, stillOK);

    // Recovery, and what the proxy saw.
    socks = startSocks();
    await sleep(1500);
    const recovered = await visit(ipService, { route: "direct" });
    check("proxy back: Direct works again", recovered === home, recovered);
    const systemHosts = [...firstLog, ...socks.log].filter((line) => /mozilla|firefox|digicert|ocsp/.test(line));
    check("Firefox's own requests stayed off the proxy", systemHosts.length === 0,
      `${firstLog.length + socks.log.length} proxied connections, ${systemHosts.join(", ") || "none from Firefox"}`);

    await bidi.send("session.end").catch(() => {});
  } finally {
    socks.kill();
    control.close();
    browser.kill();
    await new Promise((done) => browser.once("exit", done));
    await sleep(500);
    rmSync(profile, { recursive: true, force: true });
    rmSync(extensionPath, { recursive: true, force: true });
  }
  const failed = results.filter((passed) => !passed).length;
  console.log(`\n${results.length - failed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
