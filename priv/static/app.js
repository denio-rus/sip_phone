// Состояния и кнопки основного экрана
const REG_LABELS = {
  unregistered: ["не зарегистрирован", "gray"],
  registering:  ["регистрация…", "blue"],
  registered:   ["успешно", "green"],
  failed:       ["ошибка", "red"],
};

const CALL_LABELS = {
  idle:     ["свободно", "gray"],
  calling:  ["исходящий вызов…", "orange"],
  incoming: ["входящий вызов", "orange"],
  active:   ["разговор", "green"],
};

let lastState = null;

const $ = (id) => document.getElementById(id);
const show = (id, yes) => $(id).classList.toggle("hidden", !yes);

function render(st) {
  lastState = st;

  const [regText, regColor] = REG_LABELS[st.registration] || [st.registration, "gray"];
  $("reg-status").textContent = st.reg_error && st.registration === "failed"
    ? `ошибка: ${st.reg_error}` : regText;
  $("reg-status").className = `badge ${regColor}`;

  const [callText, callColor] = CALL_LABELS[st.call] || [st.call, "gray"];
  $("call-status").textContent = st.call_error && st.call === "idle"
    ? st.call_error : callText;
  $("call-status").className = `badge ${callColor}`;

  $("remote").textContent = st.remote || "—";
  // аккаунт живёт в стеке на сервере — показываем его и подставляем в пустые поля формы
  $("account").textContent = st.number && st.server ? `${st.number}@${st.server}` : "—";
  if (st.server && !$("server").value) $("server").value = st.server;
  if (st.number && !$("number").value) $("number").value = st.number;

  show("btn-unregister", st.registration === "registered" || st.registration === "registering");
  show("btn-register", st.registration !== "registered" && st.registration !== "registering");

  $("btn-call").disabled = st.registration !== "registered" || st.call !== "idle";
  show("btn-cancel", st.call === "calling");
  show("btn-answer", st.call === "incoming");
  show("btn-reject", st.call === "incoming");
  show("btn-hangup", st.call === "active");
}

async function post(url, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body || {}),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ok === false) showError(data.error || `HTTP ${res.status}`);
}

let errorTimer = null;
function showError(text) {
  const el = $("error");
  el.textContent = text;
  el.classList.remove("hidden");
  clearTimeout(errorTimer);
  errorTimer = setTimeout(() => el.classList.add("hidden"), 6000);
}

$("btn-register").onclick = () => {
  $("error").classList.add("hidden");
  post("/api/register", {
    server: $("server").value.trim(),
    number: $("number").value.trim(),
    password: $("password").value,
  });
};

$("btn-unregister").onclick = () => post("/api/unregister");
$("btn-call").onclick = () => post("/api/call", { number: $("callee").value.trim() });
$("btn-cancel").onclick = () => post("/api/cancel");
$("btn-answer").onclick = () => post("/api/answer");
$("btn-reject").onclick = () => post("/api/reject");
$("btn-hangup").onclick = () => post("/api/hangup");
$("btn-log").onclick = () => window.open("/log", "sip_log", "width=900,height=700");

// --- проводник: дерево файлов проекта + боковое превью ---
const mainEl = document.querySelector("main.phone");
let fsLoaded = false;

const fmtSize = (n) =>
  n < 1024 ? `${n} Б` :
  n < 1024 * 1024 ? `${(n / 1024).toFixed(1)} КБ` :
  `${(n / (1024 * 1024)).toFixed(1)} МБ`;

$("btn-explorer").onclick = () => {
  const opened = !$("explorer").classList.toggle("hidden"); // toggle вернул true, если скрыли
  mainEl.classList.toggle("explorer-open", opened);
  $("btn-explorer").textContent = opened ? "Скрыть проводник" : "Проводник";
  if (opened && !fsLoaded) {
    fsLoaded = true;
    loadDir($("fs-tree"), "");
  }
};

async function loadDir(container, rel) {
  let data;
  try {
    const res = await fetch(`/api/fs?path=${encodeURIComponent(rel)}`);
    data = await res.json();
  } catch { showError("Проводник: сервер недоступен"); return; }
  if (!Array.isArray(data)) { showError(data.error || "Проводник: ошибка списка файлов"); return; }
  container.textContent = "";
  for (const entry of data) container.appendChild(fsNode(entry, rel));
}

function fsNode(entry, parentRel) {
  const rel = parentRel ? `${parentRel}/${entry.name}` : entry.name;
  const row = document.createElement("div");
  row.className = `fs-item ${entry.type}`;

  if (entry.type === "dir") {
    row.textContent = `▸ ${entry.name}`;
    const kids = document.createElement("div");
    kids.className = "fs-kids hidden";
    let loaded = false;
    row.onclick = async () => {
      const opened = !kids.classList.toggle("hidden");
      row.textContent = `${opened ? "▾" : "▸"} ${entry.name}`;
      if (opened && !loaded) { loaded = true; await loadDir(kids, rel); } // ленивое раскрытие
    };
    const wrap = document.createElement("div");
    wrap.append(row, kids);
    return wrap;
  }

  row.textContent = entry.name;
  row.title = `${rel} (${fmtSize(entry.size)})`;
  row.onclick = () => openPreview(entry, rel, row);
  return row;
}

async function openPreview(entry, rel, row) {
  document.querySelectorAll(".fs-item.file.active").forEach((el) => el.classList.remove("active"));
  row.classList.add("active");
  $("fs-preview").classList.remove("hidden");
  mainEl.classList.add("preview-open"); // секция с превью расширяет окно ещё сильнее
  $("fs-preview-title").textContent = `${rel} · ${fmtSize(entry.size)}`;
  $("fs-preview-body").textContent = "загрузка…";

  let data;
  try {
    const res = await fetch(`/api/fs/file?path=${encodeURIComponent(rel)}`);
    data = await res.json();
  } catch { $("fs-preview-body").textContent = "не удалось загрузить файл"; return; }

  if (data.binary) {
    $("fs-preview-body").textContent = "Бинарный файл — просмотр недоступен.";
  } else {
    $("fs-preview-body").textContent = (data.content || "") +
      (data.truncated ? "\n\n… содержимое обрезано (показаны первые 256 КБ)" : "");
  }
}

$("fs-preview-close").onclick = () => {
  $("fs-preview").classList.add("hidden");
  mainEl.classList.remove("preview-open");
  document.querySelectorAll(".fs-item.file.active").forEach((el) => el.classList.remove("active"));
};

// --- WebSocket: состояние и живой лог ---
function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === "state") render(msg.data);
  };

  ws.onclose = () => setTimeout(connect, 1500);
  ws.onerror = () => ws.close();
}

fetch("/api/state").then((r) => r.json()).then(render).catch(() => {});
connect();

// --- тёмная/светлая тема ---
const toggle = $("theme-toggle");
const savedTheme = localStorage.getItem("sip_phone_theme") ||
  (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");

function applyTheme(t) {
  document.documentElement.dataset.theme = t;
  toggle.checked = t === "dark";
  localStorage.setItem("sip_phone_theme", t);
}

applyTheme(savedTheme);
toggle.onchange = () => applyTheme(toggle.checked ? "dark" : "light");
