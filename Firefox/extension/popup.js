"use strict";

const LABELS = { vpn: "VPN", direct: "Direct", block: "Block", system: "Normal" };
const SOURCES = {
  tab: "Set on this tab",
  site: "From the site rule",
  container: "From the container rule",
  profile: "From the profile default",
  bypass: "Local address, so it keeps its normal route",
};

let tabId;

function segments(options, selected, onChoose) {
  const group = document.createElement("div");
  group.className = "segments";
  group.setAttribute("role", "group");
  for (const { route, label } of options) {
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

function row(title, detail, level, key, selected, canInherit) {
  const element = document.createElement("section");
  element.className = "row";
  const heading = document.createElement("div");
  heading.className = "row-title";
  const name = document.createElement("span");
  name.textContent = title;
  const note = document.createElement("span");
  note.className = "muted";
  note.textContent = detail || "";
  note.title = detail || "";
  heading.append(name, note);

  const options = Object.entries(LABELS).map(([route, label]) => ({ route, label }));
  if (canInherit) {
    options.unshift({ route: null, label: "Inherit" });
  }
  const choose = async (route) => {
    await browser.runtime.sendMessage({ type: "set-rule", level, key, route, tabId });
    await render();
  };
  element.append(heading, segments(options, selected, choose));
  return element;
}

async function render() {
  const info = await browser.runtime.sendMessage({ type: "describe", tabId });
  document.getElementById("effective").textContent =
    info.effective ? `This page: ${LABELS[info.effective.route]}` : "Splyt";
  document.getElementById("source").textContent = info.effective
    ? (info.effective.domain ? `${SOURCES.site}: ${info.effective.domain}` : SOURCES[info.effective.source])
    : "This page has no network route.";

  const notice = document.getElementById("notice");
  notice.hidden = info.paired;
  notice.textContent = "Not paired. VPN and Direct are blocked until you paste the code from Splyt on your Mac.";

  const rows = [row("This tab", "", "tab", null, info.routes.tab, true)];
  if (info.host) {
    rows.push(row("This site", info.site, "site", info.site, info.routes.site, true));
  }
  rows.push(row("Container", info.container.name, "container", info.container.id, info.routes.container, true));
  rows.push(row("Profile default", "All other tabs", "profile", null, info.routes.profile, false));
  document.getElementById("rows").replaceChildren(...rows);
}

document.getElementById("reload").addEventListener("click", () => {
  browser.tabs.reload(tabId);
  window.close();
});

document.getElementById("settings").addEventListener("click", () => {
  browser.runtime.openOptionsPage();
  window.close();
});

browser.tabs.query({ active: true, currentWindow: true }).then(([tab]) => {
  tabId = tab.id;
  return render();
});
