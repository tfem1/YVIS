// YVIS installer page: collects the choices, has the server check them, shows
// the summary, then follows the installation. The server (yvis-installer)
// decides what is valid and what will run; this page only asks.
"use strict";

const KEY = document.querySelector('meta[name="yvis-key"]').content;
const ORDER = ["welcome", "region", "disk", "software", "account", "review", "install"];
const $ = (id) => document.getElementById(id);

let F = null;          // facts from the server
let step = "welcome";
const C = {};          // choices
let checked = null;    // last /api/check answer

async function api(path, body) {
  const r = await fetch(path, {
    method: body ? "POST" : "GET",
    headers: { "X-YVIS-Key": KEY, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  return r.json();
}

const gb = (n) => (n >= 1e12 ? (n / 1e12).toFixed(1) + " TB" : Math.round(n / 1e9) + " GB");

function el(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") e.className = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids) if (k != null) e.append(k);
  return e;
}

function options(select, values, current) {
  select.replaceChildren(...values.map((v) => el("option", { value: v, selected: v === current }, v)));
}

// ---------------------------------------------------------------- screens

function show(name) {
  step = name;
  document.querySelectorAll(".screen").forEach((s) => (s.hidden = s.dataset.screen !== name));
  const i = ORDER.indexOf(name);
  document.querySelectorAll("#steps li").forEach((li, j) => {
    li.className = j < i ? "done" : j === i ? "current" : "";
  });
  $("back").hidden = i === 0 || name === "install";
  $("next").hidden = name === "install";
  $("next").textContent = name === "review" ? "Install" : "Next";
  $("next").classList.toggle("danger", name === "review");
  $("nav-error").textContent = "";
  if (name === "review") review();
  if (name === "review") $("next").disabled = !$("consent").checked;
  else $("next").disabled = false;
  window.scrollTo(0, 0);
}

function welcome() {
  const nv = { open: "NVIDIA, supported by the open driver", unsupported: "NVIDIA, older (nouveau driver)", none: "no NVIDIA card" }[F.gpu.nvidia];
  const rows = [
    ["Firmware", F.firmware === "uefi" ? "UEFI" : "BIOS (legacy)"],
    ["Disks", F.disks.filter((d) => !d.live).map((d) => `${d.model || d.path} (${gb(d.size)})`).join(", ") || "none found"],
    ["Graphics", nv],
    ["System", "YVIS, kernel " + F.kernel],
  ];
  $("machine").replaceChildren(...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)]));
  if (F.demo || F.dry_run) {
    $("mode-note").hidden = false;
    $("mode-note").textContent = F.demo ? "Demo: an invented machine, nothing is written." : "Dry run: the commands are shown, not run.";
  }
}

function region() {
  options($("locale"), F.locales, C.locale);
  options($("keymap"), F.keymaps, C.keymap);
  options($("timezone"), F.timezones, C.timezone);
  for (const id of ["locale", "keymap", "timezone"]) $(id).onchange = (e) => (C[id] = e.target.value);
}

function disk() {
  const setMode = (m) => {
    C.disk.mode = m;
    document.querySelectorAll("[data-disk-mode]").forEach((b) => b.setAttribute("aria-checked", b.dataset.diskMode === m));
    $("disk-auto").hidden = m !== "auto";
    $("disk-manual").hidden = m !== "manual";
  };
  document.querySelectorAll("[data-disk-mode]").forEach((b) => (b.onclick = () => setMode(b.dataset.diskMode)));
  setMode(C.disk.mode);

  const cards = F.disks.map((d) => {
    const card = el("button", { class: "card", role: "radio", "aria-checked": C.disk.device === d.path, disabled: d.live },
      el("span", { class: "icon" }, (d.transport || "disk").toUpperCase().slice(0, 4)),
      el("div", {}, el("b", {}, d.model || d.path), el("span", {}, " " + d.path + (d.partitions.length ? ` · ${d.partitions.length} partition(s)` : " · empty"))),
      d.live ? el("span", { class: "badge" }, "YVIS runs from it") : d.removable ? el("span", { class: "badge" }, "removable") : null,
      el("span", { class: "size" }, gb(d.size)));
    card.onclick = () => {
      C.disk.device = d.path;
      document.querySelectorAll("#disks .card").forEach((c) => c.setAttribute("aria-checked", c === card));
    };
    return card;
  });
  $("disks").replaceChildren(...cards);
  if (!C.disk.device) {
    const first = F.disks.find((d) => !d.live);
    if (first) { C.disk.device = first.path; cards[F.disks.indexOf(first)].setAttribute("aria-checked", "true"); }
  }

  const parts = F.disks.filter((d) => !d.live).flatMap((d) => d.partitions.map((p) => ({ ...p, disk: d })));
  const label = (p) => `${p.path} · ${gb(p.size)} · ${p.label || p.type || p.fstype || "unformatted"}`;
  const fill = (sel, list, cur, empty) => {
    sel.replaceChildren(el("option", { value: "" }, empty), ...list.map((p) => el("option", { value: p.path, selected: p.path === cur }, label(p))));
  };
  fill($("root-part"), parts, C.disk.root, "Choose a partition");
  fill($("efi-part"), parts.filter((p) => p.fstype === "vfat" || /EFI/i.test(p.type || "")).concat(parts.filter((p) => !(p.fstype === "vfat" || /EFI/i.test(p.type || "")))), C.disk.efi, "Choose the EFI partition");
  $("root-part").onchange = (e) => (C.disk.root = e.target.value);
  $("efi-part").onchange = (e) => (C.disk.efi = e.target.value);
  $("efi-format").onchange = (e) => (C.disk.format_efi = e.target.checked);
  $("efi-field").hidden = $("efi-format-field").hidden = F.firmware !== "uefi";
}

function software() {
  const hints = {
    minimal: "The desktop and its settings, nothing more.",
    desktop: "Everyday programs: files, text editor, image viewer, archives.",
    gaming: "Desktop, plus Steam, Proton, GameMode and MangoHud.",
  };
  const blurb = { kde: "Full desktop, preselected. Familiar and complete.", hyprland: "Tiling Wayland compositor, with the author's dotfiles." };
  $("desktops").replaceChildren(...Object.entries(F.desktops).map(([id, name]) => {
    const b = el("button", { class: "choice", role: "checkbox", "aria-checked": C.desktops.includes(id) },
      el("b", {}, name), el("span", {}, blurb[id] || ""),
      F.can.desktops.includes(id) ? null : el("span", { class: "badge" }, "installed later"));
    b.onclick = () => {
      C.desktops = C.desktops.includes(id) ? C.desktops.filter((d) => d !== id) : [...C.desktops, id];
      b.setAttribute("aria-checked", C.desktops.includes(id));
    };
    return b;
  }));
  $("profiles").replaceChildren(...Object.entries(F.profiles).map(([id, name]) => {
    const b = el("button", { role: "radio", "aria-checked": C.profile === id }, name);
    b.onclick = () => {
      C.profile = id;
      document.querySelectorAll("#profiles button").forEach((x) => x.setAttribute("aria-checked", x === b));
      $("profile-hint").textContent = hints[id];
    };
    return b;
  }));
  $("profile-hint").textContent = hints[C.profile];
  const nv = F.gpu.nvidia;
  $("nvidia").checked = C.nvidia;
  $("nvidia").disabled = nv !== "open";
  $("nvidia-field").classList.toggle("disabled", nv !== "open");
  $("nvidia-hint").textContent = nv === "open" ? "An NVIDIA card was found: the open kernel modules are recommended."
    : nv === "unsupported" ? "This NVIDIA card is too old for the open modules: the free nouveau driver is used."
    : "No NVIDIA card in this computer.";
  $("nvidia").onchange = (e) => (C.nvidia = e.target.checked);
}

function account() {
  const bind = (id, set) => { $(id).oninput = (e) => set(e.target.value); };
  $("fullname").value = C.user.fullname;
  $("username").value = C.user.name;
  $("hostname").value = C.hostname;
  let nameTouched = !!C.user.name;
  bind("fullname", (v) => {
    C.user.fullname = v;
    if (!nameTouched) {
      C.user.name = v.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").split(/\s+/)[0].replace(/[^a-z0-9_-]/g, "").slice(0, 32);
      $("username").value = C.user.name;
    }
  });
  bind("username", (v) => { nameTouched = true; C.user.name = v; });
  bind("hostname", (v) => (C.hostname = v));
  $("encrypt").checked = C.encrypt;
  const can = F.can.encrypt && C.disk.mode === "auto";
  $("encrypt").disabled = !can;
  $("encrypt-field").classList.toggle("disabled", !can);
  if (!F.can.encrypt) $("encrypt-hint").textContent = "Not available on this live system yet.";
  else if (C.disk.mode !== "auto") $("encrypt-hint").textContent = "Only when YVIS takes the whole disk.";
  $("passphrase-fields").hidden = !C.encrypt;
  $("encrypt").onchange = (e) => { C.encrypt = e.target.checked; $("passphrase-fields").hidden = !C.encrypt; };
}

function secrets() {
  return { password: $("password").value, passphrase: C.encrypt ? $("passphrase").value : "" };
}

async function review() {
  $("consent").checked = false;
  $("next").disabled = true;
  $("summary").replaceChildren(...checked.summary.map((s) =>
    el("li", { class: /^(ERASE|FORMAT)/.test(s) ? "erase" : "" }, s)));
  $("plan").replaceChildren(...checked.steps.map((s) => el("li", {}, s)));
}

// ---------------------------------------------------------------- checks

function showErrors(errors) {
  document.querySelectorAll("small[data-error]").forEach((s) => {
    s.textContent = errors[s.dataset.error] || "";
    s.closest(".field")?.classList.toggle("invalid", !!errors[s.dataset.error]);
  });
}

// Which fields belong to which screen: the first screen with an error is shown.
const FIELDS = {
  region: ["locale", "keymap", "timezone"],
  disk: ["disk", "disk.mode", "disk.device", "disk.root", "disk.efi"],
  software: ["desktops", "profile"],
  account: ["user.name", "user.fullname", "user.password", "password2", "hostname", "encrypt", "encrypt.passphrase", "passphrase2"],
};

async function check(upTo) {
  const errors = {};
  if ($("password").value !== $("password2").value) errors.password2 = "the two passwords differ";
  if (C.encrypt && $("passphrase").value !== $("passphrase2").value) errors.passphrase2 = "the two passphrases differ";
  const r = await api("/api/check", { choices: C, secrets: secrets() });
  Object.assign(errors, r.errors);
  const reached = ORDER.slice(0, ORDER.indexOf(upTo) + 1);
  const relevant = Object.fromEntries(Object.entries(errors).filter(([k]) =>
    reached.some((s) => (FIELDS[s] || []).includes(k)) || !Object.values(FIELDS).flat().includes(k)));
  showErrors(relevant);
  if (Object.keys(relevant).length) {
    const bad = ORDER.find((s) => (FIELDS[s] || []).some((k) => relevant[k]));
    if (bad && bad !== step) show(bad);
    $("nav-error").textContent = "Some answers need a look.";
    return false;
  }
  if (!Object.keys(errors).length) checked = r;
  return true;
}

// ---------------------------------------------------------------- install

async function install() {
  $("next").disabled = true;
  const r = await api("/api/install", { choices: C, secrets: secrets(), confirm: true });
  if (!r.started) { $("nav-error").textContent = r.error || "The server refused."; $("next").disabled = false; return; }
  show("install");
  let since = 0;
  const log = $("log");
  const tick = async () => {
    const s = await api("/api/status?since=" + since);
    since = s.next;
    if (s.lines.length) { log.textContent += s.lines.join("\n") + "\n"; log.scrollTop = log.scrollHeight; }
    $("progress").replaceChildren(...s.steps.map((x) => el("li", { class: x.state }, x.title)));
    const done = s.steps.filter((x) => x.state === "done").length;
    $("meter").style.width = (100 * done / Math.max(1, s.steps.length)) + "%";
    if (s.state === "running") return setTimeout(tick, 700);
    const end = $("install-end");
    end.hidden = false;
    if (s.state === "done") {
      $("install-eyebrow").textContent = "Done";
      $("install-title").textContent = "YVIS is installed";
      end.textContent = F.demo || F.dry_run ? "Nothing was written: this was a demonstration." : "Remove the installation medium, then restart the computer.";
      document.querySelectorAll("#steps li").forEach((li) => (li.className = "done"));
    } else {
      $("install-eyebrow").textContent = "Stopped";
      $("install-title").textContent = "The installation failed";
      $("meter").classList.add("failed");
      $("log-box").open = true;
      end.textContent = "The details below show the command that failed. The disk may be partly written: start the installer again after fixing the cause.";
    }
  };
  tick();
}

// ---------------------------------------------------------------- start

$("back").onclick = () => show(ORDER[ORDER.indexOf(step) - 1]);
$("next").onclick = async () => {
  if (step === "review") return install();
  const next = ORDER[ORDER.indexOf(step) + 1];
  if (step !== "welcome" && !(await check(step))) return;
  if (next === "review" && !checked) return;
  if (next === "account") account();
  show(next);
};
$("consent").onchange = (e) => ($("next").disabled = !e.target.checked);

(async () => {
  F = await api("/api/facts");
  Object.assign(C, structuredClone(F.defaults));
  C.disk = { mode: "auto", device: null, root: "", efi: "", format_efi: false };
  C.nvidia = F.gpu.nvidia === "open";
  C.desktops = C.desktops.filter((d) => d in F.desktops);
  welcome(); region(); disk(); software(); account();
  show("welcome");
})();
