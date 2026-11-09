// Route decisions. Pure logic, shared by the background page and the Node tests.
"use strict";

(function (root) {
  const ROUTES = ["vpn", "direct", "block", "system"];
  const USERNAME = "splyt";
  const LOOPBACK = "127.0.0.1";
  // Nothing listens here, so requests routed to it fail. Firefox fails a content
  // request when its only proxy is unreachable, instead of connecting directly.
  const DEAD_PORT = 1;

  const DEFAULT_BYPASS = [
    "localhost",
    "local",
    "lan",
    "home.arpa",
    "internal",
    "netbird.cloud",
    "netbird.selfhosted",
    "ts.net",
  ];

  function defaultState() {
    return {
      settings: { vpnPort: 0, directPort: 0, token: "", leakProtection: true },
      rules: { profile: "system", sites: {}, containers: {} },
      bypass: DEFAULT_BYPASS.slice(),
    };
  }

  function hostOf(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:" &&
          parsed.protocol !== "ws:" && parsed.protocol !== "wss:") {
        return null;
      }
      return parsed.hostname.replace(/^\[|\]$/g, "").toLowerCase();
    } catch {
      return null;
    }
  }

  /** Normalises typed input such as "https://www.Example.com/x" to a host. */
  function normalizeSite(input) {
    const text = String(input).trim().toLowerCase();
    if (!text) {
      return null;
    }
    const host = hostOf(text.includes("://") ? text : `https://${text}`);
    return host ? host.replace(/^\*\./, "").replace(/\.$/, "") : null;
  }

  function matchesDomain(host, domain) {
    return host === domain || host.endsWith(`.${domain}`);
  }

  /** The most specific site rule wins, so a subdomain can override its parent. */
  function siteRule(sites, host) {
    if (!host) {
      return null;
    }
    let best = null;
    for (const domain of Object.keys(sites)) {
      if (matchesDomain(host, domain) && (!best || domain.length > best.length)) {
        best = domain;
      }
    }
    return best ? { domain: best, route: sites[best] } : null;
  }

  function isPrivateAddress(host) {
    const v4 = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
    if (v4) {
      const [a, b] = [Number(v4[1]), Number(v4[2])];
      return a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) ||
        (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
        (a === 192 && b === 168);
    }
    if (!host.includes(":")) {
      return false;
    }
    return host === "::1" || /^f[cd]/.test(host) || /^fe[89ab]/.test(host);
  }

  function isBypassed(host, bypass) {
    return !!host && (isPrivateAddress(host) || bypass.some((domain) => matchesDomain(host, domain)));
  }

  /**
   * The site a request belongs to: the page in the tab, not the request's own
   * host. A site rule then covers that page's CDNs and third parties too.
   */
  function pageHost(details) {
    if (details.type === "main_frame") {
      return hostOf(details.url);
    }
    const ancestors = details.frameAncestors;
    if (ancestors && ancestors.length) {
      return hostOf(ancestors[ancestors.length - 1].url);
    }
    return hostOf(details.documentUrl) || hostOf(details.originUrl) || hostOf(details.url);
  }

  /**
   * Firefox's own requests (updates, telemetry, safe browsing) have no tab and no
   * web origin, and must stay unproxied. If a proxied system request fails, Firefox
   * disables all of the extension's proxies for 48 hours, which would silently
   * send every routed tab down the normal path. Service workers also have no tab,
   * but they do have a web origin, so they stay covered.
   */
  function isSystemRequest(details) {
    if (details.tabId >= 0) {
      return false;
    }
    return !(hostOf(details.originUrl) || hostOf(details.documentUrl));
  }

  /** Decides a request. Precedence: tab, site, container, profile. */
  function resolve(state, details, tabRoute) {
    if (isSystemRequest(details)) {
      return { route: "system", source: "firefox" };
    }
    const decision = choose(state, details, tabRoute);
    if (decision.route !== "block" && decision.route !== "system" &&
        isBypassed(hostOf(details.url), state.bypass)) {
      return { route: "system", source: "bypass" };
    }
    return decision;
  }

  function choose(state, details, tabRoute) {
    if (tabRoute) {
      return { route: tabRoute, source: "tab" };
    }
    const site = siteRule(state.rules.sites, pageHost(details));
    if (site) {
      return { route: site.route, source: "site", domain: site.domain };
    }
    const container = state.rules.containers[details.cookieStoreId];
    if (container) {
      return { route: container, source: "container" };
    }
    return { route: state.rules.profile, source: "profile" };
  }

  function deadProxy() {
    return { type: "socks", host: LOOPBACK, port: DEAD_PORT, proxyDNS: true, failoverTimeout: 1 };
  }

  function isPaired(settings) {
    return !!settings.token && settings.vpnPort > 0 && settings.directPort > 0;
  }

  /**
   * What to hand Firefox. Always a single proxy: a second entry, or a trailing
   * direct entry, would let a tab leave on the wrong route when Splyt is off.
   */
  function proxyInfo(route, settings) {
    if (route === "system") {
      return { type: "direct" };
    }
    if (route === "block" || !isPaired(settings)) {
      return deadProxy();
    }
    return {
      type: "socks",
      host: LOOPBACK,
      port: route === "vpn" ? settings.vpnPort : settings.directPort,
      username: USERNAME,
      password: settings.token,
      proxyDNS: true,
      failoverTimeout: 5,
    };
  }

  /** Parses the "vpnPort:directPort:token" code shown by the Mac app. */
  function parsePairing(code) {
    const match = String(code).trim().match(/^(\d{1,5}):(\d{1,5}):([0-9a-f]{16,255})$/i);
    if (!match) {
      return null;
    }
    const [vpnPort, directPort] = [Number(match[1]), Number(match[2])];
    if (!vpnPort || !directPort || vpnPort > 65535 || directPort > 65535 || vpnPort === directPort) {
      return null;
    }
    return { vpnPort, directPort, token: match[3] };
  }

  const api = {
    ROUTES, DEFAULT_BYPASS, defaultState, hostOf, normalizeSite, siteRule, isBypassed,
    pageHost, isSystemRequest, resolve, proxyInfo, deadProxy, isPaired, parsePairing,
  };
  if (typeof module !== "undefined") {
    module.exports = api;
  } else {
    root.SplytRules = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this);
