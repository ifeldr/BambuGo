// Pannello di BambuGo per Windows e Linux. I dati arrivano già interpretati dal processo Rust.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const COLORS = {
  brandA: 'var(--brand-a)', brandB: 'var(--brand-b)', red: 'var(--red)', orange: 'var(--orange)',
  yellow: 'var(--yellow)', green: 'var(--green)', gray: 'var(--gray)',
};

let snap = null;
let showSettings = false;
let confirmStop = false;
let cameraOpen = localStorage.getItem('cameraOpen') !== 'false';
let cameraAttached = false;
let cameraFrame = null;
let cameraError = null;
let lastFrameAt = 0;
let showLinks = false;

// MARK: - Utilità

function formatMinutes(m) {
  const h = Math.floor(m / 60);
  return h > 0 ? `${h}h ${m % 60}m` : `${m % 60}m`;
}

function eta(minutes) {
  return new Date(Date.now() + minutes * 60000).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' });
}

function stateColor(s) {
  if (!s) return COLORS.gray;
  if (s.connection === 'error') return COLORS.orange;
  if (s.connection !== 'connected' || !s.hasData) return COLORS.gray;
  switch (s.status.gcodeState) {
    case 'RUNNING': case 'PREPARE': case 'SLICING': return COLORS.brandB;
    case 'PAUSE': return COLORS.yellow;
    case 'FINISH': return COLORS.green;
    case 'FAILED': return COLORS.red;
    default: return COLORS.brandA;
  }
}

function wifiQuality(dbm) {
  if (dbm >= -55) return 'ottimo';
  if (dbm >= -67) return 'buono';
  if (dbm >= -75) return 'discreto';
  return 'debole';
}

function bambuColor(hex) {
  if (!hex || hex.length < 6) return '#888';
  return '#' + hex.slice(0, 6);
}

const card = (inner, extra = '') => `<section class="card" ${extra}>${inner}</section>`;
const pill = (text, color) => `<span class="state-pill" style="--c:${color}">${esc(text)}</span>`;
const fdm = () => snap.status.workMode === 'fdm' && !snap.isLaserWork;

// MARK: - Intestazione

function renderHeader() {
  const s = snap;
  const badge = $('badge');
  badge.style.setProperty('--c', stateColor(s));
  badge.classList.toggle('working', s.connection === 'connected' && s.isActive);
  if (!badge.firstChild) {
    badge.innerHTML = `<svg viewBox="0 0 44 44" fill="none" stroke="#fff">
      <rect x="8.4" y="8.4" width="27.2" height="27.2" rx="3.5" stroke-width="1.6"/>
      <rect x="8.4" y="15.4" width="27.2" height="1.4" fill="#fff" stroke="none"/>
      <rect class="head" x="12.3" y="14" width="6.2" height="4.8" rx="1.5" fill="#fff" stroke="none"/>
      <rect x="17.6" y="26.4" width="8.8" height="4.4" rx="1" fill="rgba(255,255,255,.75)" stroke="none"/>
      <rect x="11.9" y="30.8" width="20.2" height="1.6" fill="#fff" stroke="none"/></svg>`;
  }
  $('name').textContent = s.displayName;
  const parts = [];
  if (s.model && s.model !== s.displayName) parts.push(esc(s.model));
  if (s.status.toolModule && s.connection === 'connected') parts.push(esc(s.status.toolModule.name));
  parts.push({ connected: esc(s.host), connecting: 'Connessione…', error: 'Disconnessa', notConfigured: 'Configura la stampante' }[s.connection]);
  let html = parts.join('<span class="sep">·</span>');
  if (s.status.wifiSignal != null && s.connection === 'connected') {
    html += `<span class="sep">·</span><span title="Segnale Wi-Fi: ${s.status.wifiSignal} dBm">${icon('wifi')}</span>${wifiQuality(s.status.wifiSignal)}`;
  }
  $('subtitle').innerHTML = html;
  const button = $('settingsButton');
  button.hidden = !s.configured;
  button.innerHTML = icon(showSettings ? 'close' : 'gear');
  button.title = showSettings ? 'Chiudi impostazioni' : 'Impostazioni';
}

// MARK: - Corpo

function renderDashboard() {
  const s = snap;
  const settingsVisible = showSettings || !s.configured;
  $('settings').hidden = !settingsVisible;
  $('dashboard').hidden = settingsVisible;
  if (settingsVisible) {
    setCamera(false);
    return;
  }

  const parts = [];
  if (s.connection === 'error' && s.error) {
    parts.push(`<div class="banner" style="--c:${COLORS.orange}">${icon('alert')}<span>${esc(s.error)}</span></div>`);
  }
  if (s.commandMessage) {
    parts.push(`<div class="banner" style="--c:${COLORS.orange}">${icon('hand')}<span>${esc(s.commandMessage)}</span></div>`);
  }
  if (!s.hasData) {
    parts.push(card(`<div class="row" style="padding:6px 0"><div class="spinner dark"></div>
      <span class="muted">${s.connection === 'connecting' ? 'Connessione in corso…' : 'In attesa di dati dalla stampante…'}</span></div>`));
    $('dashboard').innerHTML = parts.join('');
    setCamera(false);
    return;
  }
  if (s.printError || s.status.hms.length) parts.push(errorsCard());
  parts.push(jobCard());
  parts.push('<div id="cameraSlot"></div>');
  parts.push(s.isLaserWork ? laserCard() : temperatureRow());
  if (s.status.amsUnits.length || s.status.externalSpools.some((t) => !t.empty)) parts.push(filamentCard());

  $('dashboard').innerHTML = parts.join('');
  bindDashboard($('dashboard'));
  placeCameraCard();
  setCamera(cameraOpen && document.visibilityState === 'visible');
  renderCameraContent();
}

function errorsCard() {
  const s = snap.status;
  const count = s.hms.length + (snap.printError ? 1 : 0);
  const sevColor = (v) => (v <= 2 ? COLORS.red : v === 3 ? COLORS.orange : COLORS.brandB);
  const row = (title, detail, sev, color, url) => `<div class="error-row" style="--c:${color}">
      <div class="bar"></div><div class="text"><div>${esc(title)}</div><div class="mono">${esc(detail)}</div></div>
      <span class="sev">${esc(sev)}</span>
      ${url ? `<button class="link-button" data-url="${esc(url)}" title="Apri la spiegazione sul wiki Bambu Lab">${icon('help')}</button>` : ''}</div>`;
  let html = `<div class="card-title" style="color:${COLORS.red}">${icon('alert')}Errori e avvisi<span class="count">${count}</span></div>`;
  if (snap.printError) {
    const e = snap.printError;
    html += row(e.title, `Codice ${e.code}`, fdm() ? 'Stampa' : 'Lavoro', COLORS.red, e.url);
  }
  const printer = s.hms.filter((a) => !a.isAms);
  const ams = s.hms.filter((a) => a.isAms);
  if (printer.length) {
    html += `<div class="section">Stampante</div>` + printer.map((a) => row(a.module, a.code, a.severityName, sevColor(a.severity), a.url)).join('');
  }
  if (ams.length) {
    html += `<div class="section">AMS</div>` + ams.map((a) => row(a.detail || a.module, a.code, a.severityName, sevColor(a.severity), a.url)).join('');
  }
  return card(html);
}

function ring(value, color) {
  const v = Math.min(Math.max(value, 0), 1);
  const c = 2 * Math.PI * 33;
  return `<div class="ring"><svg viewBox="0 0 74 74">
      <circle cx="37" cy="37" r="33" fill="none" stroke="var(--card-border)" stroke-width="7"/>
      <circle cx="37" cy="37" r="33" fill="none" stroke="${color}" stroke-width="7" stroke-linecap="round"
        stroke-dasharray="${c}" stroke-dashoffset="${c * (1 - Math.max(v, 0.01))}"/></svg>
      <div class="value"><b>${Math.round(v * 100)}</b><span>%</span></div></div>`;
}

function jobCard() {
  const s = snap.status;
  const color = stateColor(snap);
  if (snap.isActive) {
    const paused = s.gcodeState === 'PAUSE';
    const disabled = snap.pending || snap.connection !== 'connected' ? 'disabled' : '';
    let controls;
    if (confirmStop) {
      controls = `<span style="font-size:11px;font-weight:500">${fdm() ? 'Interrompere la stampa?' : 'Interrompere il lavoro?'}</span><span class="spacer"></span>
        <button class="control" style="--c:${COLORS.gray}" data-action="cancelStop" ${disabled}>${icon('undo')}No</button>
        <button class="control filled" style="--c:${COLORS.red}" data-action="stop" ${disabled}>${icon('stop')}Interrompi</button>`;
    } else {
      controls = `<button class="control" style="--c:${paused ? COLORS.green : COLORS.yellow}" data-action="${paused ? 'resume' : 'pause'}" ${disabled}>
          ${icon(paused ? 'play' : 'pause')}${paused ? 'Riprendi' : 'Pausa'}</button>
        <button class="control" style="--c:${COLORS.red}" data-action="confirmStop" ${disabled}>${icon('stop')}Interrompi</button>
        <span class="spacer"></span>
        ${snap.pending ? '<div class="spinner dark"></div><span class="muted small">Invio…</span>' : ''}`;
    }
    return card(`<div class="job">${ring(s.percent / 100, color)}
        <div class="job-info">${pill(snap.stateName, color)}
          <div class="job-name">${esc(s.taskName || 'Lavoro senza nome')}</div>
          ${s.totalLayers > 0 && fdm() ? `<div class="meta num">${icon('layers')}Strato ${s.layer} di ${s.totalLayers}</div>` : ''}
          ${s.remainingMinutes > 0 ? `<div class="meta num">${icon('clock')}${formatMinutes(s.remainingMinutes)} · fine alle ${eta(s.remainingMinutes)}</div>` : ''}
        </div></div>
      <div class="divider"></div>
      <div class="row">${controls}</div>
      ${snap.speedName && fdm() ? `<div class="row" style="font-size:11px"><span class="muted">${icon('gauge')} Velocità</span><span class="spacer"></span><b style="font-weight:500">${esc(snap.speedName)}</b></div>` : ''}`);
  }
  const st = s.gcodeState;
  const idleIcon = st === 'FINISH' ? 'check' : st === 'FAILED' ? 'x' : 'sparkles';
  let title;
  if (st === 'FINISH') title = fdm() ? 'Stampa completata' : 'Lavoro completato';
  else if (st === 'FAILED') title = fdm() ? 'Stampa non riuscita' : 'Lavoro non riuscito';
  else if (st === 'IDLE' || st === '') title = fdm() ? 'Pronta per stampare' : s.workMode === 'cut' ? 'Pronta per tagliare' : 'Pronta per incidere';
  else title = snap.stateName;
  return card(`<div class="idle"><div class="idle-icon" style="--c:${color}">${icon(idleIcon)}</div>
      <div><div style="font-size:13px;font-weight:600">${esc(title)}</div>
      ${s.taskName ? `<div class="muted" style="font-size:11px">Ultimo lavoro: ${esc(s.taskName)}</div>` : ''}</div></div>`);
}

// La scheda della telecamera resta la stessa tra un aggiornamento e l'altro (niente sfarfallio).
let cameraCardEl = null;
let cameraCardKey = '';

function placeCameraCard() {
  const key = `${cameraOpen}|${snap.status.lightOn}`;
  if (!cameraCardEl || key !== cameraCardKey) {
    cameraCardKey = key;
    const holder = document.createElement('div');
    holder.innerHTML = cameraCard();
    const fresh = holder.firstElementChild;
    bindDashboard(fresh);
    if (cameraCardEl) cameraCardEl.replaceWith(fresh);
    cameraCardEl = fresh;
  }
  $('cameraSlot').replaceWith(cameraCardEl);
}

function cameraCard() {
  const light = snap.status.lightOn;
  return card(`<button class="collapse ${cameraOpen ? '' : 'closed'}" data-action="toggleCamera">
      <span class="card-title">${icon('video')}Telecamera</span>${icon('chevron', 'chev')}</button>
    ${cameraOpen ? `<div class="camera" id="camera"><div id="cameraContent"></div>
      <div class="overlay"><span id="live" class="live" hidden>LIVE</span><span class="spacer"></span>
        ${light != null ? `<button class="overlay-button ${light ? 'on' : ''}" data-action="light" title="${light ? 'Spegni la luce' : 'Accendi la luce'}">${icon(light ? 'bulbOn' : 'bulb')}</button>` : ''}
        <button class="overlay-button" data-action="fullCamera" title="Ingrandisci">${icon('expand')}</button>
      </div></div>` : ''}`);
}

function renderCameraContent() {
  const content = $('cameraContent');
  const full = $('cameraFull');
  const live = cameraFrame && !cameraError && Date.now() - lastFrameAt < 20000;
  if (content) {
    if (cameraFrame && !cameraError) {
      let img = content.querySelector('img');
      if (!img) {
        content.innerHTML = '<img alt="Telecamera">';
        img = content.querySelector('img');
      }
      img.src = cameraFrame;
    } else if (cameraError) {
      content.innerHTML = `<div class="message">${icon('videoOff')}<span>${esc(cameraError)}</span></div>`;
    } else {
      content.innerHTML = '<div class="spinner"></div>';
    }
    const liveTag = $('live');
    if (liveTag) liveTag.hidden = !live;
  }
  if (!full.hidden) {
    const img = full.querySelector('img');
    if (img && cameraFrame) img.src = cameraFrame;
  }
}

function setCamera(wanted) {
  const want = wanted || !$('cameraFull').hidden;
  if (want && !cameraAttached) {
    cameraAttached = true;
    invoke('camera_attach');
  } else if (!want && cameraAttached) {
    cameraAttached = false;
    invoke('camera_detach');
  }
}

function tempTile({ title, iconName, current, target, ambient = false, active = false, tip = '' }) {
  const heating = (target || 0) > 0;
  const value = current == null ? '–' : Math.round(current);
  const compact = $('dashboard').dataset.compact === '1';
  let foot;
  if (heating) {
    const ratio = Math.min(Math.max((current || 0) / target, 0), 1);
    foot = `<div class="temp-bar"><div style="width:${ratio * 100}%"></div></div>
      <div class="temp-note">${compact ? '→ ' : 'obiettivo '}${Math.round(target)}°</div>`;
  } else {
    foot = `<div class="temp-note off">${ambient ? 'ambiente' : 'spento'}</div>`;
  }
  return `<div class="temp ${heating ? 'heating' : ''} ${active ? 'active' : ''}" title="${esc(tip)}">
    <div class="temp-title">${icon(iconName)}${esc(title)}${active ? '<span class="dot"></span>' : ''}</div>
    <div class="temp-value"><b>${value}</b><span>°C</span></div>${foot}</div>`;
}

function temperatureRow() {
  const s = snap.status;
  const compact = s.dualNozzle && snap.hasChamberSensor;
  $('dashboard').dataset.compact = compact ? '1' : '0';
  const tiles = [];
  if (s.dualNozzle) {
    for (const n of s.nozzles) {
      const isActive = n.id === s.activeExtruder;
      tiles.push(tempTile({ title: `Ugello ${n.sideLetter}`, iconName: 'flame', current: n.current, target: n.target,
        active: isActive && snap.isActive, tip: `Ugello ${n.sideName.toLowerCase()}${isActive ? ' – in uso' : ''}` }));
    }
  } else {
    tiles.push(tempTile({ title: 'Ugello', iconName: 'flame', current: s.nozzle, target: s.nozzleTarget }));
  }
  tiles.push(tempTile({ title: 'Piatto', iconName: 'bed', current: s.bed, target: s.bedTarget }));
  if (snap.hasChamberSensor) {
    tiles.push(tempTile({ title: 'Camera', iconName: 'thermo', current: s.chamber, target: s.chamberTarget, ambient: true }));
  }
  return `<div class="temps ${compact ? 'compact' : ''}">${tiles.join('')}</div>`;
}

function laserCard() {
  const s = snap.status;
  const cut = s.workMode === 'cut';
  const iconName = s.toolModule ? s.toolModule.icon : cut ? 'cut' : 'laser';
  let subtitle;
  if (s.toolModule) subtitle = `${s.toolModule.name} montato`;
  else if ((snap.model || '').toUpperCase().startsWith('R1')) subtitle = 'Incisore e taglierina laser';
  else subtitle = cut ? 'Modulo da taglio' : 'Modulo laser';
  return card(`<div class="laser"><div class="laser-icon">${icon(iconName)}</div>
    <div style="flex:1"><div style="font-size:12px;font-weight:600">${cut ? 'Modalità taglio' : 'Modalità laser'}</div>
    <div class="muted small">${esc(subtitle)}</div></div>
    ${snap.hasChamberSensor && s.chamber != null ? `<span class="muted small" title="Temperatura in camera">${icon('thermo')} ${Math.round(s.chamber)}°</span>` : ''}</div>`);
}

function disc(tray, size = 34) {
  let inner;
  if (tray.empty) {
    inner = `<circle cx="20" cy="20" r="18.5" fill="none" stroke="var(--faint)" stroke-width="1.2" stroke-dasharray="3 3"/>`;
  } else {
    const remain = tray.remain;
    const r = 11.5;
    const arc = remain != null
      ? `<circle cx="20" cy="20" r="${r}" fill="none" stroke="rgba(255,255,255,.75)" stroke-width="2" stroke-linecap="round"
          stroke-dasharray="${2 * Math.PI * r}" stroke-dashoffset="${2 * Math.PI * r * (1 - Math.min(Math.max(remain, 0), 100) / 100)}"
          transform="rotate(-90 20 20)" style="mix-blend-mode:overlay"/>` : '';
    inner = `<circle cx="20" cy="20" r="19" fill="${bambuColor(tray.color)}" stroke="rgba(128,128,128,.35)" stroke-width="0.8"/>
      ${arc}<circle cx="20" cy="20" r="6.4" fill="var(--bg)" stroke="rgba(128,128,128,.3)" stroke-width="0.6"/>`;
  }
  const side = tray.loadedOn
    ? `<span class="side" title="${tray.loadedOn === 'S' ? "Caricata nell'ugello sinistro" : "Caricata nell'ugello destro"}">${tray.loadedOn}</span>` : '';
  return `<div class="disc ${tray.active ? 'active' : ''}" style="width:${size + 6}px;height:${size + 6}px"><svg viewBox="0 0 40 40">${inner}</svg>${side}</div>`;
}

function spool(tray) {
  const label = tray.empty ? tray.label : tray.remain != null ? `${tray.label} · ${tray.remain}%` : tray.label;
  const tip = tray.empty ? `Slot ${tray.label} vuoto` : `Slot ${tray.label}: ${tray.type}${tray.active ? ' – in uso' : ''}`;
  return `<div class="spool" title="${esc(tip)}">${disc(tray)}
    <div class="kind ${tray.empty ? 'empty' : ''}">${esc(tray.empty ? 'Vuoto' : tray.type)}</div>
    <div class="label">${esc(label)}</div></div>`;
}

function climate(unit, compact) {
  const parts = [];
  if (unit.dryingMinutes > 0) {
    parts.push(`<span class="drying" title="Essiccazione in corso: ${formatMinutes(unit.dryingMinutes)} rimanenti">${icon('wind')}${compact ? '' : formatMinutes(unit.dryingMinutes)}</span>`);
  }
  if (unit.humidity != null) parts.push(`<span title="Umidità nell'AMS">${icon('humidity')}${unit.humidity}%</span>`);
  if (!compact && unit.temperature) parts.push(`<span>${icon('thermo')}${Math.round(unit.temperature)}°</span>`);
  return `<div class="climate" ${compact ? 'style="margin:0;justify-content:center"' : ''}>${parts.join('')}</div>`;
}

function filamentCard() {
  const s = snap.status;
  const multi = s.amsUnits.filter((u) => !u.singleSlot);
  const singles = s.amsUnits.filter((u) => u.singleSlot);
  const externals = s.externalSpools.filter((t) => !t.empty);
  const blocks = [];
  multi.forEach((u) => {
    const title = multi.length > 1 ? `${u.model} · ${u.letter}` : u.model;
    blocks.push(`<div class="unit-head"><span class="card-title">${esc(title)}</span>
        ${u.nozzle ? `<span class="tag" title="Ugello a cui è collegata l'unità">→ ${esc(u.nozzle)}</span>` : ''}
        ${climate(u, false)}</div>
      <div class="spools ${u.trays.length > 4 ? 'five' : ''}">${u.trays.map(spool).join('')}</div>`);
  });
  if (singles.length) {
    const title = singles.length > 1 ? `${singles[0].model} ×${singles.length}` : singles[0].model;
    blocks.push(`<div class="card-title">${esc(title)}</div><div class="spools">${singles
      .filter((u) => u.trays.length)
      .map((u) => `<div class="spool">${spool(u.trays[0])}${climate(u, true)}</div>`)
      .join('')}</div>`);
  }
  if (externals.length) {
    blocks.push(externals.map((t) => {
      let title = 'Bobina esterna';
      if (s.dualNozzle && t.id === 'ext-254') title += ' sinistra';
      if (s.dualNozzle && t.id === 'ext-255') title += ' destra';
      const state = t.active ? pill('in uso', COLORS.brandB) : t.loadedOn ? pill('caricata', COLORS.gray) : '';
      return `<div class="external">${disc(t, 22)}<div style="flex:1"><div class="card-title">${title}</div>
        <div class="muted small">${esc(t.type)}</div></div>${state}</div>`;
    }).join(''));
  }
  return card(blocks.join('<div class="divider"></div>'));
}

function bindDashboard(root) {
  root.querySelectorAll('[data-action]').forEach((el) => {
    el.addEventListener('click', () => {
      switch (el.dataset.action) {
        case 'pause': invoke('print_command', { command: 'pause' }); break;
        case 'resume': invoke('print_command', { command: 'resume' }); break;
        case 'confirmStop': confirmStop = true; render(); break;
        case 'cancelStop': confirmStop = false; render(); break;
        case 'stop': confirmStop = false; invoke('print_command', { command: 'stop' }); render(); break;
        case 'light': invoke('set_light', { on: !snap.status.lightOn }); break;
        case 'toggleCamera':
          cameraOpen = !cameraOpen;
          localStorage.setItem('cameraOpen', cameraOpen);
          render();
          break;
        case 'fullCamera': openFullCamera(); break;
      }
    });
  });
  root.querySelectorAll('[data-url]').forEach((el) => {
    el.addEventListener('click', () => invoke('open_url', { url: el.dataset.url }));
  });
}

function openFullCamera() {
  const full = $('cameraFull');
  full.innerHTML = `<img alt="Telecamera"><button class="overlay-button" title="Chiudi">${icon('close')}</button>`;
  full.hidden = false;
  if (cameraFrame) full.querySelector('img').src = cameraFrame;
  full.querySelector('button').addEventListener('click', () => {
    full.hidden = true;
    full.innerHTML = '';
    setCamera(cameraOpen && !$('dashboard').hidden);
  });
  setCamera(true);
}

// MARK: - Impostazioni

let form = null;
let found = [];
let searching = false;
let searched = false;
let autostart = false;

async function openSettings() {
  const config = await invoke('get_config');
  autostart = await invoke('get_autostart').catch(() => false);
  form = { name: config.name, host: config.host, serial: config.serial, code: config.accessCode, model: '' };
  found = [];
  searched = false;
  renderSettings();
}

function renderSettings() {
  if (!form) return;
  const s = snap;
  const valid = form.host.trim() && form.serial.trim() && form.code.trim();
  let list = '';
  if (found.length) {
    list = `<div class="found">${found.map((p, i) => `<button data-found="${i}">${icon('search')}<span style="flex:1"><b>${esc(p.name)}</b>
      <div class="muted small">${esc(p.model)} · ${esc(p.host)}</div></span></button>`).join('')}</div>`;
  } else if (searched) {
    list = `<div class="note">Nessuna stampante trovata: inserisci i dati a mano. Il PC deve essere sulla stessa rete; su Windows consenti BambuGo nel firewall quando lo chiede.</div>`;
  }
  $('settings').innerHTML = `
    <div class="row"><span class="card-title">Stampante in rete locale</span><span class="spacer"></span>
      <button class="secondary" id="searchButton" ${searching ? 'disabled' : ''}>${searching ? 'Ricerca…' : 'Cerca in rete'}</button></div>
    ${list}
    <div class="field"><label>Nome (facoltativo)</label><input id="fName" value="${esc(form.name)}" placeholder="${esc(s.model || 'Stampante')}"></div>
    <div class="field"><label>Indirizzo IP</label><input id="fHost" value="${esc(form.host)}" placeholder="192.168.1.50"></div>
    <div class="field"><label>Numero di serie</label><input id="fSerial" value="${esc(form.serial)}" placeholder="01P00A000000000"></div>
    <div class="field"><label>Access code</label><input id="fCode" type="password" value="${esc(form.code)}" placeholder="12345678"></div>
    <div class="note">IP e access code sono sul display della stampante (Impostazioni → Rete/WLAN). Per pausa, interruzione e luce, con i firmware recenti attiva anche la modalità LAN e la modalità sviluppatore.</div>
    <label class="check"><input type="checkbox" id="fNotify" ${s.notifications ? 'checked' : ''}>Notifiche a fine stampa, errore e pausa</label>
    <label class="check"><input type="checkbox" id="fAuto" ${autostart ? 'checked' : ''}>Avvia BambuGo all'accesso</label>
    <div id="autoError" class="note" style="color:var(--orange)"></div>
    <div class="actions">
      ${s.configured ? '<button class="secondary" id="cancelButton">Annulla</button>' : ''}
      <button class="primary" id="saveButton" ${valid ? '' : 'disabled'}>Salva e connetti</button></div>
    <div class="note">BambuGo è un progetto indipendente, non affiliato a Bambu Lab. Comunica solo con la stampante nella tua rete; usalo a tuo rischio.</div>`;

  const bind = (id, key) => $(id).addEventListener('input', (e) => {
    form[key] = e.target.value;
    $('saveButton').disabled = !(form.host.trim() && form.serial.trim() && form.code.trim());
  });
  bind('fName', 'name'); bind('fHost', 'host'); bind('fSerial', 'serial'); bind('fCode', 'code');
  $('searchButton').addEventListener('click', async () => {
    searching = true; renderSettings();
    found = await invoke('discover').catch(() => []);
    searching = false; searched = true; renderSettings();
  });
  document.querySelectorAll('[data-found]').forEach((el) => el.addEventListener('click', () => {
    const p = found[Number(el.dataset.found)];
    form.host = p.host; form.serial = p.id; form.model = p.model;
    if (!form.name) form.name = p.name;
    renderSettings();
    $('fCode').focus();
  }));
  $('fNotify').addEventListener('change', (e) => invoke('set_notifications', { enabled: e.target.checked }));
  $('fAuto').addEventListener('change', async (e) => {
    try {
      await invoke('set_autostart', { enabled: e.target.checked });
      autostart = e.target.checked;
      $('autoError').textContent = '';
    } catch (err) {
      $('autoError').textContent = String(err);
      e.target.checked = autostart;
    }
  });
  if ($('cancelButton')) $('cancelButton').addEventListener('click', () => { showSettings = false; render(); });
  $('saveButton').addEventListener('click', async () => {
    await invoke('save_config', { host: form.host, serial: form.serial, accessCode: form.code, name: form.name, model: form.model || null });
    showSettings = false;
    cameraFrame = null; cameraError = null;
    render();
  });
}

// MARK: - Piede e avvio

function renderFooter() {
  $('lastUpdate').textContent = snap.lastUpdate ? new Date(snap.lastUpdate).toLocaleTimeString('it-IT') : '';
  $('refreshButton').disabled = snap.connection !== 'connected';
}

function render() {
  if (!snap) return;
  renderHeader();
  renderDashboard();
  renderFooter();
}

function setupStatic() {
  $('refreshButton').innerHTML = icon('refresh');
  $('coffeeButton').innerHTML = icon('cup');
  $('quitButton').innerHTML = icon('power');
  $('modelsButton').innerHTML = `${icon('globe')}Modelli online`;
  $('refreshButton').addEventListener('click', () => invoke('refresh'));
  $('coffeeButton').addEventListener('click', () => invoke('open_url', { url: 'https://www.paypal.me/lorenzogarbi' }));
  $('quitButton').addEventListener('click', () => invoke('quit'));
  $('settingsButton').addEventListener('click', async () => {
    showSettings = !showSettings;
    if (showSettings) await openSettings();
    render();
  });
  // Modelli online: si aprono nel browser predefinito.
  $('modelsButton').addEventListener('click', () => {
    showLinks = !showLinks;
    let links = document.getElementById('modelLinks');
    if (!showLinks) { links?.remove(); return; }
    links = document.createElement('div');
    links.id = 'modelLinks';
    links.className = 'links';
    links.innerHTML = [['MakerWorld', 'https://makerworld.com'], ['Printables', 'https://www.printables.com'], ['Thingiverse', 'https://www.thingiverse.com']]
      .map(([n, u]) => `<button data-url="${u}">${n}</button>`).join('');
    document.querySelector('.footer').before(links);
    links.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => invoke('open_url', { url: b.dataset.url })));
  });
  document.addEventListener('visibilitychange', () => {
    if (!snap) return;
    setCamera(document.visibilityState === 'visible' && cameraOpen && !$('dashboard').hidden && snap.hasData);
  });
  setInterval(() => { if (snap) renderCameraContent(); }, 5000);
}

async function main() {
  setupStatic();
  await listen('snapshot', (event) => {
    const wasConfigured = snap?.configured;
    snap = event.payload;
    if (!snap.status.gcodeState || !snap.isActive) confirmStop = false;
    // Durante la modifica delle impostazioni non ridisegniamo il modulo.
    if (showSettings || !snap.configured) {
      renderHeader();
      renderFooter();
      if (!form || wasConfigured !== snap.configured) openSettings();
      $('settings').hidden = false;
      $('dashboard').hidden = true;
      return;
    }
    render();
  });
  await listen('camera-frame', (event) => {
    cameraFrame = 'data:image/jpeg;base64,' + event.payload;
    cameraError = null;
    lastFrameAt = Date.now();
    renderCameraContent();
  });
  await listen('camera-error', (event) => {
    cameraError = event.payload;
    renderCameraContent();
  });
  snap = await invoke('get_snapshot');
  if (!snap.configured) await openSettings();
  render();
}

main();
