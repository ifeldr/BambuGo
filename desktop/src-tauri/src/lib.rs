//! BambuGo per Windows e Linux: icona nel tray con lo stato della stampante Bambu Lab,
//! collegata direttamente in rete locale (MQTT su TLS), come la versione macOS.

mod camera;
mod discovery;
mod icon;
mod mqtt;
mod status;
mod tls;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use status::PrintStatus;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, State, WebviewWindow, WindowEvent};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_notification::NotificationExt as _;

// MARK: - Configurazione

fn yes() -> bool {
    true
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default)]
    host: String,
    #[serde(default)]
    serial: String,
    #[serde(default)]
    access_code: String,
    #[serde(default)]
    name: String,
    /// Modello riconosciuto (es. "P1S").
    #[serde(default)]
    model: String,
    #[serde(default = "yes")]
    notifications: bool,
    #[serde(default = "yes")]
    show_camera: bool,
}

impl Default for Config {
    fn default() -> Self {
        serde_json::from_str("{}").unwrap()
    }
}

impl Config {
    fn configured(&self) -> bool {
        !self.host.is_empty() && !self.serial.is_empty() && !self.access_code.is_empty()
    }
}

fn config_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|d| d.join("config.json"))
}

fn load_config(app: &AppHandle) -> Config {
    config_path(app)
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_default()
}

fn save_config_file(app: &AppHandle, config: &Config) {
    let Some(path) = config_path(app) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(config) {
        let _ = std::fs::write(&path, text);
        // L'access code resta leggibile solo dall'utente.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        }
    }
}

// MARK: - Stato condiviso

#[derive(Clone, PartialEq)]
enum Conn {
    NotConfigured,
    Connecting,
    Connected,
    Error(String),
}

struct Inner {
    config: Config,
    conn: Conn,
    raw: Value,
    status: PrintStatus,
    has_data: bool,
    last_update: Option<u64>,
    ams_models: HashMap<i64, String>,
    command_message: Option<String>,
    pending_command: Option<String>,
    client: Option<mqtt::Handle>,
    generation: u64,
    camera: Option<camera::Stream>,
    camera_viewers: u32,
    camera_rtsp: bool,
    camera_got_frame: bool,
    camera_generation: u64,
}

type Shared = Arc<Mutex<Inner>>;

impl Inner {
    fn model(&self) -> String {
        if !self.config.model.is_empty() {
            return self.config.model.clone();
        }
        status::model_from_serial(&self.config.serial).unwrap_or("").to_string()
    }

    fn display_name(&self) -> String {
        if !self.config.name.is_empty() {
            return self.config.name.clone();
        }
        let m = self.model();
        if m.is_empty() { "Stampante".into() } else { m }
    }

    fn rebuild_status(&mut self) {
        let model = self.model();
        self.status = PrintStatus::parse(&self.raw, &model, &self.ams_models);
    }

    fn menu_title(&self) -> String {
        if self.conn != Conn::Connected || !self.has_data {
            return String::new();
        }
        let s = &self.status;
        match s.gcode_state.as_str() {
            "RUNNING" if s.remaining_minutes > 0 => format!("{}% · {}", s.percent, format_minutes(s.remaining_minutes)),
            "RUNNING" => format!("{}%", s.percent),
            "PAUSE" => format!("Pausa {}%", s.percent),
            "PREPARE" | "SLICING" => "Prep.".into(),
            "FINISH" => "Finita".into(),
            "FAILED" => "Errore".into(),
            _ => String::new(),
        }
    }

    fn snapshot(&self) -> Snapshot {
        let model = self.model();
        let (connection, error) = match &self.conn {
            Conn::NotConfigured => ("notConfigured", None),
            Conn::Connecting => ("connecting", None),
            Conn::Connected => ("connected", None),
            Conn::Error(e) => ("error", Some(e.clone())),
        };
        let s = &self.status;
        let print_error = (s.print_error != 0).then(|| {
            let (title, code, url) = status::print_error_info(s.print_error, &model, &s.work_mode);
            PrintError { title, code, url }
        });
        Snapshot {
            configured: self.config.configured(),
            host: self.config.host.clone(),
            serial: self.config.serial.clone(),
            name: self.config.name.clone(),
            display_name: self.display_name(),
            model: model.clone(),
            connection: connection.into(),
            error,
            has_data: self.has_data,
            last_update: self.last_update,
            state_name: s.state_name(),
            speed_name: s.speed_name(),
            menu_title: self.menu_title(),
            is_active: s.is_active(),
            command_message: self.command_message.clone(),
            pending: self.pending_command.is_some(),
            has_chamber_sensor: !status::lacks_chamber_sensor(&model) && s.chamber.unwrap_or(0.0) > 5.0,
            is_laser_work: status::is_laser_machine(&model) || s.work_mode != "fdm",
            camera_rtsp: !model.is_empty() && !status::uses_jpeg_camera(&model),
            print_error,
            problems: s.has_problems(),
            show_camera: self.config.show_camera,
            notifications: self.config.notifications,
            status: s.clone(),
        }
    }
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct PrintError {
    title: String,
    code: String,
    url: String,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Snapshot {
    configured: bool,
    host: String,
    serial: String,
    name: String,
    display_name: String,
    model: String,
    connection: String,
    error: Option<String>,
    has_data: bool,
    last_update: Option<u64>,
    status: PrintStatus,
    state_name: String,
    speed_name: Option<String>,
    menu_title: String,
    is_active: bool,
    command_message: Option<String>,
    pending: bool,
    has_chamber_sensor: bool,
    is_laser_work: bool,
    camera_rtsp: bool,
    print_error: Option<PrintError>,
    problems: bool,
    show_camera: bool,
    notifications: bool,
}

fn format_minutes(minutes: i64) -> String {
    let (h, m) = (minutes / 60, minutes % 60);
    if h > 0 { format!("{h}h {m}m") } else { format!("{m}m") }
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

// MARK: - Aggiornamento di interfaccia e tray

// L'interfaccia e il tray si aggiornano da un thread dedicato, senza tenere il lucchetto
// dello stato: le chiamate al tray attendono il thread principale e altrimenti
// potrebbero bloccarsi a vicenda con un comando dell'interfaccia.
enum UiMessage {
    Snapshot(Snapshot),
    Notify(String, String),
}

static UI: std::sync::OnceLock<std::sync::mpsc::Sender<UiMessage>> = std::sync::OnceLock::new();

fn start_ui_thread(app: AppHandle) {
    let (tx, rx) = std::sync::mpsc::channel::<UiMessage>();
    let _ = UI.set(tx);
    std::thread::spawn(move || {
        let mut icon_key = String::new();
        while let Ok(message) = rx.recv() {
            let mut latest = None;
            let mut pending = vec![message];
            while let Ok(more) = rx.try_recv() {
                pending.push(more);
            }
            for message in pending {
                match message {
                    UiMessage::Snapshot(snap) => latest = Some(snap),
                    UiMessage::Notify(title, body) => {
                        let _ = app.notification().builder().title(title).body(body).show();
                    }
                }
            }
            if let Some(snap) = latest {
                let _ = app.emit("snapshot", &snap);
                update_tray(&app, &mut icon_key, &snap);
            }
        }
    });
}

fn publish_state(_app: &AppHandle, inner: &mut Inner) {
    if let Some(tx) = UI.get() {
        let _ = tx.send(UiMessage::Snapshot(inner.snapshot()));
    }
}

fn update_tray(app: &AppHandle, icon_key: &mut String, snap: &Snapshot) {
    let Some(tray) = app.tray_by_id("main") else { return };
    let connected = snap.connection == "connected";
    let s = &snap.status;
    let mut badge = icon::Badge::None;
    let mut progress = None;
    let dimmed = !connected || !snap.has_data;
    if snap.connection == "error" {
        badge = icon::Badge::Warning;
    }
    if connected && snap.has_data {
        match s.gcode_state.as_str() {
            "RUNNING" | "PREPARE" | "SLICING" => progress = Some(s.percent as f64 / 100.0),
            "PAUSE" => {
                progress = Some(s.percent as f64 / 100.0);
                badge = icon::Badge::Pause;
            }
            "FINISH" => {
                progress = Some(1.0);
                badge = icon::Badge::Done;
            }
            "FAILED" => badge = icon::Badge::Failed,
            _ => {}
        }
        if snap.problems && badge != icon::Badge::Failed {
            badge = icon::Badge::Warning;
        }
    }
    let color = icon::state_color(&s.gcode_state, connected, snap.has_data);
    let key = format!("{color:?}{:?}{}{dimmed}", progress.map(|p| (p * 20.0) as i32), badge as u8);
    if key != *icon_key {
        *icon_key = key;
        let (rgba, w, h) = icon::draw(color, progress, badge, dimmed);
        let _ = tray.set_icon(Some(tauri::image::Image::new_owned(rgba, w, h)));
    }

    let mut tooltip = snap.display_name.clone();
    match snap.connection.as_str() {
        "connected" if snap.has_data => {
            tooltip.push_str(" – ");
            tooltip.push_str(&snap.state_name);
            if !snap.menu_title.is_empty() && s.is_active() {
                tooltip.push_str(&format!(" ({})", snap.menu_title));
            }
        }
        "connecting" => tooltip.push_str(" – connessione…"),
        "error" => tooltip.push_str(" – disconnessa"),
        "notConfigured" => tooltip = "BambuGo – configura la stampante".into(),
        _ => {}
    }
    let _ = tray.set_tooltip(Some(&tooltip));
    #[cfg(target_os = "linux")]
    {
        let _ = tray.set_title(if snap.menu_title.is_empty() { None } else { Some(snap.menu_title.as_str()) });
    }
}

fn notify(_app: &AppHandle, title: &str, body: &str) {
    if let Some(tx) = UI.get() {
        let _ = tx.send(UiMessage::Notify(title.to_string(), body.to_string()));
    }
}

fn notify_transition(app: &AppHandle, inner: &Inner, previous: &str) {
    let new = &inner.status;
    if !inner.config.notifications || previous.is_empty() || previous == new.gcode_state {
        return;
    }
    let name = if new.task_name.is_empty() { inner.display_name() } else { new.task_name.clone() };
    let fdm = new.work_mode == "fdm";
    match new.gcode_state.as_str() {
        "FINISH" if matches!(previous, "RUNNING" | "PAUSE" | "PREPARE") => {
            notify(app, if fdm { "Stampa completata ✅" } else { "Lavoro completato ✅" }, &name)
        }
        "FAILED" => notify(app, if fdm { "Stampa fallita ❌" } else { "Lavoro non riuscito ❌" }, &name),
        "PAUSE" if previous == "RUNNING" => notify(
            app,
            if fdm { "Stampa in pausa ⏸" } else { "Lavoro in pausa ⏸" },
            &format!("{name} – controlla la macchina"),
        ),
        _ => {}
    }
}

// MARK: - MQTT

fn connect(app: &AppHandle, shared: &Shared) {
    let mut inner = shared.lock().unwrap();
    inner.client = None;
    inner.generation += 1;
    inner.raw = Value::Object(Default::default());
    inner.status = PrintStatus::default();
    inner.has_data = false;
    inner.last_update = None;
    inner.command_message = None;
    inner.pending_command = None;
    inner.ams_models.clear();

    if !inner.config.configured() {
        inner.conn = Conn::NotConfigured;
        publish_state(app, &mut inner);
        return;
    }
    inner.conn = Conn::Connecting;
    let generation = inner.generation;
    let id: String = format!("bambugo-{:08x}", rand::random::<u32>());
    let topic = format!("device/{}/report", inner.config.serial);
    let (app2, shared2) = (app.clone(), shared.clone());
    inner.client = Some(mqtt::start(
        inner.config.host.clone(),
        inner.config.access_code.clone(),
        id,
        topic,
        move |event| on_mqtt(&app2, &shared2, generation, event),
    ));
    publish_state(app, &mut inner);
}

fn publish(inner: &Inner, json: &str) {
    if let Some(client) = &inner.client {
        client.publish(&format!("device/{}/request", inner.config.serial), json.as_bytes());
    }
}

const PUSHALL: &str = r#"{"pushing":{"sequence_id":"0","command":"pushall","version":1,"push_target":1}}"#;
const GET_VERSION: &str = r#"{"info":{"sequence_id":"0","command":"get_version"}}"#;

fn on_mqtt(app: &AppHandle, shared: &Shared, generation: u64, event: mqtt::Event) {
    let mut inner = shared.lock().unwrap();
    if inner.generation != generation {
        return;
    }
    match event {
        mqtt::Event::Connected => {
            inner.conn = Conn::Connected;
            publish(&inner, PUSHALL);
            publish(&inner, GET_VERSION);
        }
        mqtt::Event::Disconnected(message) => inner.conn = Conn::Error(message),
        mqtt::Event::AuthRejected => {
            inner.client = None;
            inner.conn = Conn::Error("Access code errato: controllalo sul display della stampante.".into());
        }
        mqtt::Event::Message(data) => {
            let Ok(object) = serde_json::from_slice::<Value>(&data) else { return };
            if let Some(system) = object.get("system") {
                handle_reply(&mut inner, system);
            }
            if let Some(info) = object.get("info") {
                handle_version(app, &mut inner, info);
            }
            let Some(print) = object.get("print") else {
                publish_state(app, &mut inner);
                return;
            };
            handle_reply(&mut inner, print);
            if let Some(command) = print.get("command").and_then(|c| c.as_str()) {
                if command != "push_status" {
                    publish_state(app, &mut inner);
                    return;
                }
            }
            let previous = inner.status.gcode_state.clone();
            // P1 e A1 inviano aggiornamenti parziali: uniamo i campi a quelli già noti.
            status::deep_merge(&mut inner.raw, print, false);
            inner.rebuild_status();
            inner.has_data = true;
            inner.last_update = Some(now_ms());
            inner.conn = Conn::Connected;
            notify_transition(app, &inner, &previous);
        }
    }
    publish_state(app, &mut inner);
}

fn handle_reply(inner: &mut Inner, dict: &Value) {
    let Some(command) = dict.get("command").and_then(|c| c.as_str()) else { return };
    if !["pause", "resume", "stop", "ledctrl"].contains(&command) {
        return;
    }
    let Some(result) = dict.get("result").and_then(|r| r.as_str()) else { return };
    if inner.pending_command.as_deref() == Some(command) {
        inner.pending_command = None;
    }
    if result.to_lowercase() != "success" {
        let reason = dict.get("reason").and_then(|r| r.as_str()).filter(|r| !r.is_empty()).unwrap_or(result);
        inner.command_message = Some(format!("Comando rifiutato dalla stampante: {reason}"));
    } else {
        inner.command_message = None;
    }
}

fn handle_version(app: &AppHandle, inner: &mut Inner, info: &Value) {
    if info.get("command").and_then(|c| c.as_str()) != Some("get_version") {
        return;
    }
    let Some(modules) = info.get("module").and_then(|m| m.as_array()) else { return };
    let (mut from_ota, mut from_product, mut from_code) = (None, None, None);
    let mut units = HashMap::new();
    for module in modules {
        if let Some((id, model)) = status::ams_unit_from_module(module) {
            units.insert(id, model.to_string());
            continue;
        }
        let name = module.get("name").and_then(|n| n.as_str()).unwrap_or("");
        if let Some(model) = module.get("product_name").and_then(|p| p.as_str()).and_then(status::model_from_product) {
            if name == "ota" {
                from_ota = Some(model);
            } else if from_product.is_none() {
                from_product = Some(model);
            }
        }
        if from_code.is_none() {
            if let Some(m) = module.get("project_name").and_then(|p| p.as_str()).and_then(status::model_from_code) {
                from_code = Some(m.to_string());
            }
        }
    }
    if !units.is_empty() {
        inner.ams_models = units;
    }
    if let Some(found) = from_ota.or(from_product).or(from_code) {
        if found != inner.config.model {
            inner.config.model = found;
            save_config_file(app, &inner.config);
        }
    }
    inner.rebuild_status();
}

fn send_print_command(app: &AppHandle, shared: &Shared, command: &str) {
    let generation;
    {
        let mut inner = shared.lock().unwrap();
        if inner.conn != Conn::Connected {
            return;
        }
        publish(&inner, &format!(r#"{{"print":{{"sequence_id":"0","command":"{command}","param":""}}}}"#));
        inner.command_message = None;
        inner.pending_command = Some(command.to_string());
        generation = inner.generation;
        publish_state(app, &mut inner);
    }
    let (app, shared, command) = (app.clone(), shared.clone(), command.to_string());
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(10));
        let mut inner = shared.lock().unwrap();
        if inner.generation != generation {
            return;
        }
        if inner.pending_command.as_deref() == Some(command.as_str()) {
            inner.pending_command = None;
            inner.command_message = Some("La stampante non ha risposto al comando. Con i firmware recenti attiva la modalità LAN e la modalità sviluppatore sul display.".into());
        }
        publish(&inner, PUSHALL);
        publish_state(&app, &mut inner);
    });
}

// MARK: - Telecamera

fn start_camera(app: &AppHandle, shared: &Shared, inner: &mut Inner) {
    inner.camera = None;
    inner.camera_generation += 1;
    let generation = inner.camera_generation;
    let (app2, shared2) = (app.clone(), shared.clone());
    inner.camera = Some(camera::start(
        inner.config.host.clone(),
        inner.config.access_code.clone(),
        inner.camera_rtsp,
        move |event| {
            let mut inner = shared2.lock().unwrap();
            if inner.camera_generation != generation {
                return;
            }
            match event {
                camera::Event::Frame(data) => {
                    inner.camera_got_frame = true;
                    let _ = app2.emit("camera-frame", data);
                }
                camera::Event::Error(message) => {
                    let _ = app2.emit("camera-error", message);
                    // Mai visto un'immagine: forse il modello usa l'altro protocollo.
                    if !inner.camera_got_frame && inner.camera_viewers > 0 {
                        inner.camera_rtsp = !inner.camera_rtsp;
                        let shared3 = shared2.clone();
                        let app3 = app2.clone();
                        drop(inner);
                        std::thread::spawn(move || {
                            std::thread::sleep(Duration::from_secs(2));
                            let mut inner = shared3.lock().unwrap();
                            if inner.camera_generation == generation && inner.camera_viewers > 0 {
                                start_camera(&app3, &shared3, &mut inner);
                            }
                        });
                    }
                }
            }
        },
    ));
}

// MARK: - Comandi per l'interfaccia

struct AppState(Shared);

#[tauri::command]
fn get_snapshot(state: State<AppState>) -> Snapshot {
    state.0.lock().unwrap().snapshot()
}

#[tauri::command]
fn get_config(state: State<AppState>) -> Config {
    state.0.lock().unwrap().config.clone()
}

#[tauri::command]
fn save_config(app: AppHandle, state: State<AppState>, host: String, serial: String, access_code: String, name: String, model: Option<String>) {
    {
        let mut inner = state.0.lock().unwrap();
        let serial = serial.trim().to_uppercase();
        if serial != inner.config.serial {
            inner.config.model.clear();
        }
        inner.config.host = host.trim().to_string();
        inner.config.serial = serial;
        inner.config.access_code = access_code.trim().to_string();
        inner.config.name = name.trim().to_string();
        if let Some(model) = model.filter(|m| !m.is_empty()) {
            inner.config.model = model;
        }
        save_config_file(&app, &inner.config);
        inner.camera = None;
        inner.camera_got_frame = false;
    }
    connect(&app, &state.0);
}

#[tauri::command]
fn set_notifications(app: AppHandle, state: State<AppState>, enabled: bool) {
    let mut inner = state.0.lock().unwrap();
    inner.config.notifications = enabled;
    save_config_file(&app, &inner.config);
    publish_state(&app, &mut inner);
}

#[tauri::command]
fn set_show_camera(app: AppHandle, state: State<AppState>, enabled: bool) {
    let mut inner = state.0.lock().unwrap();
    inner.config.show_camera = enabled;
    save_config_file(&app, &inner.config);
    publish_state(&app, &mut inner);
}

#[tauri::command]
fn get_autostart(app: AppHandle) -> bool {
    app.autolaunch().is_enabled().unwrap_or(false)
}

#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    let manager = app.autolaunch();
    if enabled { manager.enable() } else { manager.disable() }.map_err(|e| format!("Avvio automatico non riuscito: {e}"))
}

#[tauri::command]
fn refresh(state: State<AppState>) {
    publish(&state.0.lock().unwrap(), PUSHALL);
}

#[tauri::command]
fn print_command(app: AppHandle, state: State<AppState>, command: String) {
    if ["pause", "resume", "stop"].contains(&command.as_str()) {
        send_print_command(&app, &state.0, &command);
    }
}

#[tauri::command]
fn set_light(app: AppHandle, state: State<AppState>, on: bool) {
    let mut inner = state.0.lock().unwrap();
    if inner.conn != Conn::Connected {
        return;
    }
    let mode = if on { "on" } else { "off" };
    // Le H2 hanno una seconda luce in camera: le comandiamo insieme.
    let mut nodes = vec!["chamber_light"];
    if inner.status.has_second_light {
        nodes.push("chamber_light2");
    }
    for node in &nodes {
        publish(&inner, &format!(
            r#"{{"system":{{"sequence_id":"0","command":"ledctrl","led_node":"{node}","led_mode":"{mode}","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}}}"#
        ));
    }
    // Aggiornamento ottimistico.
    let mut lights: Vec<Value> = inner.raw.get("lights_report").and_then(|l| l.as_array()).cloned().unwrap_or_default();
    for node in &nodes {
        lights.retain(|l| l.get("node").and_then(|n| n.as_str()) != Some(node));
        lights.push(serde_json::json!({"node": node, "mode": mode}));
    }
    if let Some(map) = inner.raw.as_object_mut() {
        map.insert("lights_report".into(), Value::Array(lights));
    }
    inner.rebuild_status();
    publish_state(&app, &mut inner);
}

#[tauri::command]
async fn discover() -> Vec<discovery::Discovered> {
    tauri::async_runtime::spawn_blocking(|| discovery::search(6.0)).await.unwrap_or_default()
}

#[tauri::command]
fn camera_attach(app: AppHandle, state: State<AppState>) {
    let shared = state.0.clone();
    let mut inner = shared.lock().unwrap();
    inner.camera_viewers += 1;
    if inner.camera.is_some() || !inner.config.configured() {
        return;
    }
    let model = inner.model();
    inner.camera_rtsp = !model.is_empty() && !status::uses_jpeg_camera(&model);
    inner.camera_got_frame = false;
    start_camera(&app, &shared, &mut inner);
}

#[tauri::command]
fn camera_detach(state: State<AppState>) {
    let shared = state.0.clone();
    let mut inner = shared.lock().unwrap();
    inner.camera_viewers = inner.camera_viewers.saturating_sub(1);
    if inner.camera_viewers > 0 {
        return;
    }
    // Piccolo ritardo: chiudere e riaprire il pannello non riavvia la connessione.
    let generation = inner.camera_generation;
    drop(inner);
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(3));
        let mut inner = shared.lock().unwrap();
        if inner.camera_viewers == 0 && inner.camera_generation == generation {
            inner.camera = None;
            inner.camera_generation += 1;
        }
    });
}

#[tauri::command]
fn open_url(url: String) {
    if url.starts_with("https://") {
        let _ = tauri_plugin_opener::open_url(url, None::<&str>);
    }
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

// MARK: - Finestra

const WIN_W: f64 = 372.0;

fn show_window(app: &AppHandle, near: Option<(f64, f64, f64, f64)>) {
    let Some(window) = app.get_webview_window("main") else { return };
    if let Some(rect) = near {
        place_near(&window, rect);
    }
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
}

/// Posiziona la finestra accanto all'icona nel tray (sopra se la barra è in basso).
fn place_near(window: &WebviewWindow, (x, y, w, h): (f64, f64, f64, f64)) {
    let Ok(size) = window.outer_size() else { return };
    let Ok(Some(monitor)) = window.current_monitor().or_else(|_| window.primary_monitor()) else { return };
    let area = monitor.size();
    let origin = monitor.position();
    let (ww, wh) = (size.width as f64, size.height as f64);
    let mut px = x + w / 2.0 - ww / 2.0;
    let mut py = if y > origin.y as f64 + area.height as f64 / 2.0 { y - wh - 8.0 } else { y + h + 8.0 };
    px = px.clamp(origin.x as f64 + 8.0, origin.x as f64 + area.width as f64 - ww - 8.0);
    py = py.clamp(origin.y as f64 + 8.0, origin.y as f64 + area.height as f64 - wh - 8.0);
    let _ = window.set_position(PhysicalPosition::new(px, py));
}

/// Momento in cui la finestra è stata nascosta perché ha perso il focus (Windows):
/// il clic sull'icona del tray arriva subito dopo e non deve riaprirla.
static LAST_BLUR_HIDE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn toggle_window(app: &AppHandle, near: Option<(f64, f64, f64, f64)>) {
    if now_ms().saturating_sub(LAST_BLUR_HIDE.load(std::sync::atomic::Ordering::SeqCst)) < 400 {
        return;
    }
    if let Some(window) = app.get_webview_window("main") {
        if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false) {
            let _ = window.hide();
            return;
        }
    }
    show_window(app, near);
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_window(app, None)))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec!["--hidden"]),
        ))
        .invoke_handler(tauri::generate_handler![
            get_snapshot,
            get_config,
            save_config,
            set_notifications,
            set_show_camera,
            get_autostart,
            set_autostart,
            refresh,
            print_command,
            set_light,
            discover,
            camera_attach,
            camera_detach,
            open_url,
            quit
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            let config = load_config(&handle);
            let configured = config.configured();
            let shared: Shared = Arc::new(Mutex::new(Inner {
                config,
                conn: Conn::NotConfigured,
                raw: Value::Object(Default::default()),
                status: PrintStatus::default(),
                has_data: false,
                last_update: None,
                ams_models: HashMap::new(),
                command_message: None,
                pending_command: None,
                client: None,
                generation: 0,
                camera: None,
                camera_viewers: 0,
                camera_rtsp: false,
                camera_got_frame: false,
                camera_generation: 0,
            }));
            app.manage(AppState(shared.clone()));
            start_ui_thread(handle.clone());

            // Tray: clic sinistro apre il pannello (Windows); il menu funziona ovunque.
            let open = MenuItem::with_id(app, "open", "Apri BambuGo", true, None::<&str>)?;
            let refresh = MenuItem::with_id(app, "refresh", "Aggiorna", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "Esci", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &refresh, &PredefinedMenuItem::separator(app)?, &quit])?;
            let (rgba, w, h) = icon::draw(icon::state_color("", false, false), None, icon::Badge::None, true);
            let shared_menu = shared.clone();
            TrayIconBuilder::with_id("main")
                .icon(tauri::image::Image::new_owned(rgba, w, h))
                .tooltip("BambuGo")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(move |app, event| match event.id.as_ref() {
                    "open" => show_window(app, None),
                    "refresh" => publish(&shared_menu.lock().unwrap(), PUSHALL),
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, rect, .. } = event {
                        let app = tray.app_handle();
                        let scale = app
                            .get_webview_window("main")
                            .and_then(|w| w.scale_factor().ok())
                            .unwrap_or(1.0);
                        let pos = rect.position.to_physical::<f64>(scale);
                        let size = rect.size.to_physical::<f64>(scale);
                        toggle_window(app, Some((pos.x, pos.y, size.width, size.height)));
                    }
                })
                .build(app)?;

            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_size(tauri::LogicalSize::new(WIN_W, 720.0));
                #[cfg(target_os = "windows")]
                {
                    let _ = window.set_skip_taskbar(true);
                    let _ = window.set_always_on_top(true);
                }
                let started_hidden = std::env::args().any(|a| a == "--hidden");
                if !configured || !started_hidden {
                    let _ = window.show();
                }
            }

            connect(&handle, &shared);
            Ok(())
        })
        .on_window_event(|window, event| match event {
            // Chiudere la finestra la nasconde: l'app resta nel tray.
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            // Su Windows il pannello si comporta come un menu: si chiude cliccando altrove.
            #[cfg(target_os = "windows")]
            WindowEvent::Focused(false) => {
                if window.is_visible().unwrap_or(false) {
                    LAST_BLUR_HIDE.store(now_ms(), std::sync::atomic::Ordering::SeqCst);
                    let _ = window.hide();
                }
            }
            _ => {}
        })
        .run(tauri::generate_context!())
        .expect("errore all'avvio di BambuGo");
}
