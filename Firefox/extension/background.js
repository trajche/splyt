"use strict";

const { resolve, proxyInfo, deadProxy, defaultState, hostOf, siteRule, isPaired } = SplytRules;

const TAB_KEY = "route";
const BADGES = {
  vpn: { text: "VPN", color: "#2f7dd1" },
  direct: { text: "DIR", color: "#2e8b57" },
  block: { text: "BLK", color: "#c0392b" },
};

let state = defaultState();
const tabRoutes = new Map();
const tabLoads = new Map();
let lastProxyError = null;

const ready = load();

async function load() {
  const saved = await browser.storage.local.get(["settings", "rules", "bypass"]);
  const defaults = defaultState();
  state = {
    settings: { ...defaults.settings, ...saved.settings },
    rules: { ...defaults.rules, ...saved.rules },
    bypass: saved.bypass || defaults.bypass,
  };
  await applyLeakProtection();
}

function save() {
  return browser.storage.local.set(state);
}

/**
 * Both settings cover traffic that never reaches proxy.onRequest with a tab
 * attached: WebRTC opens its own UDP sockets, and speculative connections are made
 * before a request exists. Either would leave on Firefox's app route.
 */
async function applyLeakProtection() {
  const { webRTCIPHandlingPolicy, networkPredictionEnabled } = browser.privacy.network;
  try {
    if (state.settings.leakProtection) {
      await webRTCIPHandlingPolicy.set({ value: "disable_non_proxied_udp" });
      await networkPredictionEnabled.set({ value: false });
    } else {
      await webRTCIPHandlingPolicy.clear({});
      await networkPredictionEnabled.clear({});
    }
  } catch (error) {
    console.warn("Splyt: could not change privacy settings", error);
  }
}

// Tabs. Rules live in session data, so they survive a browser restart with the tab.

function loadTab(tabId) {
  if (!tabLoads.has(tabId)) {
    tabLoads.set(tabId, readTabRoute(tabId));
  }
  return tabLoads.get(tabId);
}

async function readTabRoute(tabId) {
  try {
    const saved = await browser.sessions.getTabValue(tabId, TAB_KEY);
    if (saved) {
      tabRoutes.set(tabId, saved);
      return;
    }
    // A link opened from a routed tab must not escape that tab's route.
    const tab = await browser.tabs.get(tabId);
    if (tab.openerTabId !== undefined) {
      await loadTab(tab.openerTabId);
      const inherited = tabRoutes.get(tab.openerTabId);
      if (inherited) {
        await setTabRoute(tabId, inherited);
      }
    }
  } catch {
    // The tab closed while loading.
  }
}

async function setTabRoute(tabId, route) {
  if (route) {
    tabRoutes.set(tabId, route);
    await browser.sessions.setTabValue(tabId, TAB_KEY, route);
  } else {
    tabRoutes.delete(tabId);
    await browser.sessions.removeTabValue(tabId, TAB_KEY);
  }
}

browser.tabs.onCreated.addListener((tab) => {
  loadTab(tab.id).then(() => refreshBadge(tab.id));
});

browser.tabs.onRemoved.addListener((tabId) => {
  tabRoutes.delete(tabId);
  tabLoads.delete(tabId);
});

browser.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url || change.status) {
    refreshBadge(tabId);
  }
});

// Routing.

async function onRequest(details) {
  // A thrown error would make Firefox use no proxy at all, so failures must block.
  try {
    await ready;
    if (details.tabId >= 0) {
      await loadTab(details.tabId);
    }
    const { route } = resolve(state, details, tabRoutes.get(details.tabId));
    return proxyInfo(route, state.settings);
  } catch (error) {
    console.error("Splyt: failing closed", error);
    return deadProxy();
  }
}

browser.proxy.onRequest.addListener(onRequest, { urls: ["<all_urls>"] });

browser.proxy.onError.addListener((error) => {
  lastProxyError = { message: error.message, at: Date.now() };
});

// Toolbar.

function decide(tab) {
  const details = {
    type: "main_frame",
    url: tab.url,
    tabId: tab.id,
    cookieStoreId: tab.cookieStoreId,
  };
  return resolve(state, details, tabRoutes.get(tab.id));
}

async function refreshBadge(tabId) {
  try {
    const tab = await browser.tabs.get(tabId);
    const badge = BADGES[hostOf(tab.url) ? decide(tab).route : tabRoutes.get(tabId)];
    await browser.browserAction.setBadgeText({ tabId, text: badge ? badge.text : "" });
    if (badge) {
      await browser.browserAction.setBadgeBackgroundColor({ tabId, color: badge.color });
    }
  } catch {
    // The tab closed.
  }
}

async function refreshAllBadges() {
  const tabs = await browser.tabs.query({});
  await Promise.all(tabs.map((tab) => refreshBadge(tab.id)));
}

// Messages from the popup and settings page.

async function describe(tabId) {
  await loadTab(tabId);
  const tab = await browser.tabs.get(tabId);
  const host = hostOf(tab.url);
  const site = siteRule(state.rules.sites, host);
  let container = { id: tab.cookieStoreId, name: "No container" };
  if (tab.incognito) {
    container.name = "Private window";
  } else if (tab.cookieStoreId !== "firefox-default") {
    const identity = await browser.contextualIdentities.get(tab.cookieStoreId);
    container = { id: tab.cookieStoreId, name: identity.name, color: identity.colorCode };
  }
  return {
    tabId,
    host,
    site: site ? site.domain : host,
    routes: {
      tab: tabRoutes.get(tabId) || null,
      site: site ? site.route : null,
      container: state.rules.containers[tab.cookieStoreId] || null,
      profile: state.rules.profile,
    },
    container,
    effective: host ? decide(tab) : null,
    paired: isPaired(state.settings),
    error: lastProxyError,
  };
}

async function setRule({ level, key, route, tabId }) {
  if (level === "tab") {
    await setTabRoute(tabId, route);
  } else if (level === "profile") {
    state.rules.profile = route;
  } else {
    const rules = level === "site" ? state.rules.sites : state.rules.containers;
    if (route) {
      rules[key] = route;
    } else {
      delete rules[key];
    }
  }
  await save();
  await refreshAllBadges();
}

async function setSettings(change) {
  Object.assign(state.settings, change);
  lastProxyError = null;
  await save();
  await applyLeakProtection();
}

async function handleMessage(message) {
  await ready;
  switch (message.type) {
    case "describe":
      return describe(message.tabId);
    case "set-rule":
      return setRule(message);
    case "get-state": {
      const containers = await browser.contextualIdentities.query({});
      return { state, containers };
    }
    case "set-settings":
      return setSettings(message.change);
    case "set-bypass":
      state.bypass = message.bypass;
      return save();
    default:
      return undefined;
  }
}

browser.runtime.onMessage.addListener(handleMessage);

ready.then(async () => {
  const tabs = await browser.tabs.query({});
  await Promise.all(tabs.map((tab) => loadTab(tab.id)));
  await refreshAllBadges();
});
