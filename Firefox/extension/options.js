"use strict";

const { parsePairing, normalizeSite, isPaired } = SplytRules;
const LABELS = { vpn: "VPN", direct: "Direct", block: "Block", system: "Normal" };

const send = (message) => browser.runtime.sendMessage(message);

function routeButtons(selected, onChoose) {
  const group = document.createElement("div");
  group.className = "segments";
  group.setAttribute("role", "group");
  for (const [route, label] of [[null, "None"], ...Object.entries(LABELS)]) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.dataset.route = route || "inherit";
    button.setAttribute("aria-pressed", String(route === selected));
    button.addEventListener("click", () => onChoose(route));
    group.append(button);
  }
  return group;
}

function listRow(name, selected, onChoose) {
  const row = document.createElement("div");
  row.className = "list-row";
  const label = document.createElement("span");
  label.textContent = name;
  row.append(label, routeButtons(selected, onChoose));
  return row;
}

async function setRule(level, key, route) {
  await send({ type: "set-rule", level, key, route });
  await render();
}

async function render() {
  const { state, containers } = await send({ type: "get-state" });
  document.getElementById("pair-status").textContent = isPaired(state.settings)
    ? `Paired. VPN port ${state.settings.vpnPort}, Direct port ${state.settings.directPort}.`
    : "Not paired. VPN and Direct are blocked until you pair.";
  document.getElementById("leak").checked = state.settings.leakProtection;

  document.getElementById("sites").replaceChildren(
    ...Object.keys(state.rules.sites).sort().map((domain) =>
      listRow(domain, state.rules.sites[domain], (route) => setRule("site", domain, route)))
  );

  const identities = [
    { cookieStoreId: "firefox-default", name: "No container" },
    { cookieStoreId: "firefox-private", name: "Private windows" },
    ...containers,
  ];
  document.getElementById("containers").replaceChildren(
    ...identities.map(({ cookieStoreId, name }) =>
      listRow(name, state.rules.containers[cookieStoreId] || null,
        (route) => setRule("container", cookieStoreId, route)))
  );

  const bypass = document.getElementById("bypass");
  if (document.activeElement !== bypass) {
    bypass.value = state.bypass.join("\n");
  }
}

document.getElementById("pair").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.getElementById("code");
  const pairing = parsePairing(input.value);
  if (!pairing) {
    document.getElementById("pair-status").textContent = "That is not a Splyt pairing code.";
    return;
  }
  input.value = "";
  await send({ type: "set-settings", change: pairing });
  await render();
});

document.getElementById("add-site").addEventListener("submit", async (event) => {
  event.preventDefault();
  const input = document.getElementById("site");
  const domain = normalizeSite(input.value);
  if (!domain) {
    return;
  }
  input.value = "";
  await setRule("site", domain, "vpn");
});

document.getElementById("leak").addEventListener("change", async (event) => {
  await send({ type: "set-settings", change: { leakProtection: event.target.checked } });
});

document.getElementById("save-bypass").addEventListener("click", async () => {
  const lines = document.getElementById("bypass").value.split("\n");
  const bypass = [...new Set(lines.map(normalizeSite).filter(Boolean))];
  await send({ type: "set-bypass", bypass });
  document.getElementById("bypass").blur();
  await render();
});

render();
