const state = {
  sdtInventory: [],
  progress: [],
  pendingCommands: new Map()
};

function postCommand(command, payload = {}) {
  const message = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    command,
    payload
  };
  state.pendingCommands.set(message.id, command);
  setStatus(`${command} requested.`);

  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.postMessage(message);
  } else {
    setStatus("Running outside WPF bridge.");
  }
}

function setStatus(text) {
  document.getElementById("statusText").textContent = text || "";
}

function setText(id, value) {
  document.getElementById(id).textContent = value || "";
}

function renderInventory() {
  const search = document.getElementById("sdtSearch").value.toLowerCase();
  const root = document.getElementById("sdtInventory");
  root.textContent = "";

  const rows = state.sdtInventory.filter((item) => {
    const text = `${item.tag || ""} ${item.domain || ""} ${item.blockType || ""}`.toLowerCase();
    return text.includes(search);
  });

  if (rows.length === 0) {
    const empty = document.createElement("div");
    empty.className = "list-item";
    empty.textContent = "No SDT tags loaded.";
    root.appendChild(empty);
    return;
  }

  for (const item of rows) {
    const row = document.createElement("div");
    row.className = "list-item";
    row.innerHTML = `<strong></strong><span></span>`;
    row.querySelector("strong").textContent = item.tag || "(untagged)";
    row.querySelector("span").textContent = [item.domain, item.blockType].filter(Boolean).join(" / ");
    root.appendChild(row);
  }
}

function renderProgress() {
  const root = document.getElementById("progressStream");
  root.textContent = "";
  document.getElementById("progressSummary").textContent = `${state.progress.length} events`;

  for (const event of state.progress) {
    const row = document.createElement("div");
    row.className = `progress-event ${(event.level || "").toLowerCase()}`;
    const time = (event.timestampUtc || "").slice(11, 19);
    row.innerHTML = "<span></span><span></span><span></span><span></span>";
    const cells = row.querySelectorAll("span");
    cells[0].textContent = time;
    cells[1].textContent = event.stage || "";
    cells[2].textContent = `${event.percent ?? ""}%`;
    cells[3].textContent = event.message || "";
    root.appendChild(row);
  }
}

function receiveBridgeMessage(message) {
  let data = null;
  try {
    data = typeof message === "string" ? JSON.parse(message) : message;
  } catch (error) {
    setStatus(`Unable to read WPF message: ${error.message}`);
    return;
  }
  if (!data) return;

  if (data.id && state.pendingCommands.has(data.id)) {
    state.pendingCommands.delete(data.id);
    if (!data.ok) {
      setStatus(data.error || "Bridge command failed.");
      return;
    }
    if (data.type === "RunRenderResult" && data.payload && data.payload.accepted) {
      state.progress = [];
      renderProgress();
      setStatus("Render started.");
    }
    if (data.type === "ValidationResult") {
      setStatus("Validation refreshed.");
    }
  }

  if (data.type === "MappingStudioState") {
    const payload = data.payload || {};
    state.sdtInventory = payload.sdtInventory || [];
    setText("manifestPath", payload.manifestPath || "");
    setText("manifestText", payload.manifestText || "");
    setText("resolvedView", payload.resolvedMappingsText || "");
    setText("validationView", payload.validationText || "");
    setText("reportView", payload.renderReportText || "");
    setStatus(payload.status || "Mapping Studio data loaded.");
    renderInventory();
  }

  if (data.type === "ProgressEvent") {
    state.progress.push(data.payload || {});
    renderProgress();
  }

  if (data.type === "RenderReport") {
    setText("reportView", JSON.stringify(data.payload || {}, null, 2));
  }
}

document.getElementById("sdtSearch").addEventListener("input", renderInventory);
document.getElementById("refreshButton").addEventListener("click", () => postCommand("ValidateMapping"));
document.getElementById("runRenderButton").addEventListener("click", () => postCommand("RunRender"));

for (const tab of document.querySelectorAll(".tab")) {
  tab.addEventListener("click", () => {
    for (const current of document.querySelectorAll(".tab")) current.classList.remove("active");
    for (const panel of document.querySelectorAll(".tab-panel")) panel.classList.add("hidden");
    tab.classList.add("active");
    document.getElementById(`${tab.dataset.tab}View`).classList.remove("hidden");
  });
}

if (window.chrome && window.chrome.webview) {
  window.chrome.webview.addEventListener("message", (event) => receiveBridgeMessage(event.data));
  postCommand("ValidateMapping");
} else {
  setStatus("Static preview mode.");
  renderInventory();
  renderProgress();
}

window.AssemblerMappingStudio = { receiveBridgeMessage };
