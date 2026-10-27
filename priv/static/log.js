const $ = (id) => document.getElementById(id);
const logEl = $("log");
const ARROWS = { in: "←", out: "→", info: "•" };

const CALL_TEXT = {
  idle: "линия свободна",
  calling: "исходящий вызов",
  incoming: "входящий вызов",
  active: "разговор",
};
const REG_TEXT = {
  unregistered: "не зарегистрирован",
  registering: "регистрация…",
  registered: "регистрация успешна",
  failed: "регистрация не удалась",
};

function fmtTs(ts) {
  return new Date(ts).toLocaleTimeString("ru-RU", { hour12: false }) +
    "." + String(ts % 1000).padStart(3, "0");
}

function addEntry(e) {
  const div = document.createElement("div");
  div.className = `entry dir-${e.dir}`;

  const head = document.createElement("div");
  head.className = "head";
  const peer = e.peer ? ` [${e.peer}]` : "";
  head.textContent = `${ARROWS[e.dir] || "•"} ${fmtTs(e.ts)}  ${e.first}${peer}`;

  const raw = document.createElement("div");
  raw.className = "raw";
  raw.textContent = e.raw || "";

  head.onclick = () => div.classList.toggle("open");

  div.append(head, raw);
  logEl.append(div);

  if (logEl.children.length > 500) logEl.firstChild.remove();
  logEl.scrollTop = logEl.scrollHeight;
}

function renderState(st) {
  const parts = [REG_TEXT[st.registration] || st.registration];
  if (st.call !== "idle") {
    parts.push(CALL_TEXT[st.call] || st.call);
    if (st.remote) parts.push(`абонент ${st.remote}`);
  }
  $("state-line").textContent = parts.join(" · ");
}

$("btn-clear").onclick = () => logEl.replaceChildren();

function connect() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === "sip_log") addEntry(msg.entry);
    else if (msg.type === "log_history") msg.entries.forEach(addEntry);
    else if (msg.type === "state") renderState(msg.data);
  };

  ws.onopen = () => ($("state-line").textContent = "подключено");
  ws.onclose = () => {
    $("state-line").textContent = "соединение потеряно, переподключение…";
    setTimeout(connect, 1500);
  };
  ws.onerror = () => ws.close();
}

connect();

// тема — синхронно с основным окном через localStorage
const toggle = $("theme-toggle");
function applyTheme(t) {
  document.documentElement.dataset.theme = t;
  toggle.checked = t === "dark";
}
applyTheme(localStorage.getItem("sip_phone_theme") ||
  (matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"));
toggle.onchange = () => {
  const t = toggle.checked ? "dark" : "light";
  localStorage.setItem("sip_phone_theme", t);
  applyTheme(t);
};
