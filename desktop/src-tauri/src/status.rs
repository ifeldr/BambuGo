//! Lettura dello stato inviato dalla stampante (topic `device/<seriale>/report`).
//! È la stessa logica di `PrintStatus.swift` della versione macOS.

use serde::Serialize;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};

// MARK: - Conversioni

pub fn num(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        _ => None,
    }
}

pub fn int(v: Option<&Value>) -> Option<i64> {
    num(v).map(|f| f as i64)
}

fn string(v: Option<&Value>) -> String {
    v.and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// Temperatura "impacchettata": parola bassa = attuale, parola alta = obiettivo.
fn packed(v: Option<&Value>) -> Option<(f64, f64)> {
    let raw = int(v)?;
    if raw < 0 {
        return None;
    }
    Some(((raw & 0xFFFF) as f64, ((raw >> 16) & 0xFFFF) as f64))
}

fn path<'a>(v: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    let mut cur = v;
    for k in keys {
        cur = cur.get(*k)?;
    }
    Some(cur)
}

/// Unione degli aggiornamenti parziali. Nel blocco "device" gli elenchi si uniscono per "id";
/// altrove l'elenco nuovo sostituisce il vecchio (uno slot svuotato non conserva il filamento).
pub fn deep_merge(base: &mut Value, update: &Value, merge_lists: bool) {
    let (Some(base_map), Some(update_map)) = (base.as_object_mut(), update.as_object()) else {
        *base = update.clone();
        return;
    };
    for (key, value) in update_map {
        let merge = merge_lists || key == "device";
        match base_map.get_mut(key) {
            Some(old) if old.is_object() && value.is_object() => deep_merge(old, value, merge),
            Some(old) if merge_lists && old.is_array() && value.is_array() => {
                let new_items = value.as_array().unwrap();
                let old_items = old.as_array().unwrap();
                let keyed = |items: &Vec<Value>| items.iter().all(|i| i.get("id").is_some());
                if new_items.is_empty() || !keyed(new_items) || !keyed(old_items) {
                    *old = value.clone();
                    continue;
                }
                let mut merged = old_items.clone();
                for item in new_items {
                    let id = item.get("id").unwrap().to_string().trim_matches('"').to_string();
                    if let Some(existing) = merged
                        .iter_mut()
                        .find(|m| m.get("id").unwrap().to_string().trim_matches('"') == id)
                    {
                        deep_merge(existing, item, true);
                    } else {
                        merged.push(item.clone());
                    }
                }
                *old = Value::Array(merged);
            }
            _ => {
                base_map.insert(key.clone(), value.clone());
            }
        }
    }
}

// MARK: - Modelli

pub fn model_from_serial(serial: &str) -> Option<&'static str> {
    let prefix: String = serial.to_uppercase().chars().take(3).collect();
    Some(match prefix.as_str() {
        "00M" => "X1C",
        "00W" => "X1",
        "03W" => "X1E",
        "20P" => "X2D",
        "01S" => "P1P",
        "01P" => "P1S",
        "22E" => "P2S",
        "030" => "A1 mini",
        "039" => "A1",
        "26A" => "A2L",
        "094" => "H2D",
        "239" => "H2D Pro",
        "093" => "H2S",
        "31B" => "H2C",
        "32X" => "H3C",
        "35F" => "R1",
        _ => return None,
    })
}

/// Codici usati da SSDP (DevModel) e da get_version (project_name).
pub fn model_from_code(code: &str) -> Option<&'static str> {
    let upper = code.to_uppercase();
    let base = upper.split("-V").next().unwrap_or(&upper).to_string();
    let lookup = |c: &str| -> Option<&'static str> {
        Some(match c {
            "BL-P001" => "X1C",
            "BL-P002" => "X1",
            "C13" => "X1E",
            "N6" => "X2D",
            "C11" => "P1P",
            "C12" => "P1S",
            "N7" => "P2S",
            "N1" => "A1 mini",
            "N2S" => "A1",
            "N9" => "A2L",
            "O1D" => "H2D",
            "O1E" => "H2D Pro",
            "O1S" => "H2S",
            "O1C" | "O1C2" => "H2C",
            "N10" => "H3C",
            "N8" => "R1",
            _ => return None,
        })
    };
    lookup(&upper).or_else(|| lookup(&base))
}

/// "Bambu Lab X1-Carbon" → "X1C".
pub fn model_from_product(product: &str) -> Option<String> {
    let name = product.trim().strip_prefix("Bambu Lab")?.trim();
    if name.is_empty() {
        return None;
    }
    Some(match name.to_lowercase().as_str() {
        "x1-carbon" | "x1 carbon" => "X1C".into(),
        _ => name.to_string(),
    })
}

/// P1, A1 e A2 trasmettono JPEG sulla porta 6000; le altre RTSP sulla 322.
pub fn uses_jpeg_camera(model: &str) -> bool {
    let m = model.to_uppercase();
    m.starts_with("P1") || m.starts_with("A1") || m.starts_with("A2")
}

pub fn is_laser_machine(model: &str) -> bool {
    model.to_uppercase().starts_with("R1")
}

pub fn lacks_chamber_sensor(model: &str) -> bool {
    uses_jpeg_camera(model) || is_laser_machine(model)
}

pub fn wiki_section(model: &str) -> &'static str {
    let m = model.to_uppercase();
    if m.starts_with('H') {
        "h2"
    } else if m.starts_with("P2") {
        "p2s"
    } else if m.starts_with("X2") {
        "x2d"
    } else if m == "A1 MINI" {
        "a1-mini"
    } else if m.starts_with('A') {
        "a1"
    } else {
        "x1"
    }
}

/// Unità AMS tra i moduli di get_version (es. "n3f/0" = AMS 2 Pro, unità A).
pub fn ams_unit_from_module(module: &Value) -> Option<(i64, &'static str)> {
    let name = string(module.get("name"));
    let prefixes = [
        ("ams_f1/", "AMS lite"),
        ("ams/", "AMS"),
        ("n3f/", "AMS 2 Pro"),
        ("n3s/", "AMS HT"),
        ("n10a/", "AMS 3H"),
    ];
    for (prefix, model) in prefixes {
        if let Some(rest) = name.strip_prefix(prefix) {
            return rest.parse::<i64>().ok().map(|id| (id, model));
        }
    }
    if name == "n10a" {
        return Some((int(module.get("id")).unwrap_or(-1), "AMS 3H"));
    }
    None
}

// MARK: - Strutture per l'interfaccia

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Nozzle {
    pub id: i64,
    pub current: Option<f64>,
    pub target: Option<f64>,
    pub side_name: String,
    pub side_letter: String,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Tray {
    pub id: String,
    pub label: String,
    pub slot: i64,
    #[serde(rename = "type")]
    pub kind: String,
    pub color: String,
    pub remain: Option<i64>,
    pub active: bool,
    pub loaded_on: Option<String>,
    pub empty: bool,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Unit {
    pub id: i64,
    pub model: String,
    pub letter: String,
    pub humidity: Option<i64>,
    pub temperature: Option<f64>,
    pub drying_minutes: i64,
    pub nozzle: Option<String>,
    pub single_slot: bool,
    pub trays: Vec<Tray>,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Alert {
    pub code: String,
    pub module: String,
    pub detail: Option<String>,
    pub severity: i64,
    pub severity_name: String,
    pub is_ams: bool,
    pub url: String,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct Tool {
    pub name: String,
    pub icon: String,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct PrintStatus {
    pub gcode_state: String,
    pub percent: i64,
    pub remaining_minutes: i64,
    pub layer: i64,
    pub total_layers: i64,
    pub nozzle: Option<f64>,
    pub nozzle_target: Option<f64>,
    pub nozzles: Vec<Nozzle>,
    pub active_extruder: i64,
    pub bed: Option<f64>,
    pub bed_target: Option<f64>,
    pub chamber: Option<f64>,
    pub chamber_target: Option<f64>,
    pub task_name: String,
    pub print_error: i64,
    pub speed_level: i64,
    pub wifi_signal: Option<i64>,
    pub ams_units: Vec<Unit>,
    pub external_spools: Vec<Tray>,
    pub hms: Vec<Alert>,
    pub light_on: Option<bool>,
    pub has_second_light: bool,
    /// "fdm", "laser" o "cut"
    pub work_mode: String,
    pub tool_module: Option<Tool>,
    pub dual_nozzle: bool,
}

fn letter(unit: i64) -> String {
    let index = if unit >= 128 { unit - 128 } else { unit % 16 };
    ((b'A' + index.clamp(0, 25) as u8) as char).to_string()
}

fn slot_label(unit: i64, slot: i64) -> String {
    if unit >= 128 {
        format!("HT-{}", letter(unit))
    } else {
        format!("{}{}", letter(unit), slot + 1)
    }
}

fn decode_snow(value: i64) -> Option<(i64, i64)> {
    let unit = (value >> 8) & 0xFF;
    let slot = value & 0xFF;
    if slot == 0xFF {
        return None;
    }
    if unit >= 254 {
        return Some((unit, 0));
    }
    Some((unit, slot))
}

fn decode_tray_now(value: i64) -> Option<(i64, i64)> {
    match value {
        255 => None,
        254 => Some((254, 0)),
        128..=253 => Some((value, 0)),
        _ => Some((value >> 2, value & 0x3)),
    }
}

fn tray_from(dict: &Value, id: String, label: String, active: bool, loaded_on: Option<String>) -> Tray {
    let kind = string(dict.get("tray_type")).trim().to_string();
    let remain = int(dict.get("remain")).filter(|r| *r >= 0);
    Tray {
        id,
        label,
        slot: int(dict.get("id")).unwrap_or(0),
        empty: kind.is_empty(),
        kind,
        color: string(dict.get("tray_color")),
        remain,
        active,
        loaded_on,
    }
}

impl PrintStatus {
    pub fn parse(dict: &Value, model: &str, ams_models: &HashMap<i64, String>) -> PrintStatus {
        let mut s = PrintStatus {
            gcode_state: string(dict.get("gcode_state")).to_uppercase(),
            percent: int(dict.get("mc_percent")).unwrap_or(0),
            remaining_minutes: int(dict.get("mc_remaining_time")).unwrap_or(0),
            layer: int(dict.get("layer_num")).unwrap_or(0),
            total_layers: int(dict.get("total_layer_num")).unwrap_or(0),
            print_error: int(dict.get("print_error")).unwrap_or(0),
            speed_level: int(dict.get("spd_lvl")).unwrap_or(0),
            work_mode: "fdm".into(),
            ..Default::default()
        };
        if let Some(wifi) = dict.get("wifi_signal").and_then(|v| v.as_str()) {
            let digits: String = wifi.chars().filter(|c| c.is_ascii_digit() || *c == '-').collect();
            s.wifi_signal = digits.parse().ok();
        }

        let empty = Value::Object(Map::new());
        let device = dict.get("device").unwrap_or(&empty);

        // Temperature (blocco "device", valori impacchettati) con ripiego sui campi storici.
        let extruder = device.get("extruder").unwrap_or(&empty);
        let mut info: Vec<&Value> = extruder
            .get("info")
            .and_then(|v| v.as_array())
            .map(|a| a.iter().filter(|e| int(e.get("id")).map_or(false, |i| (0..16).contains(&i))).collect())
            .unwrap_or_default();
        info.sort_by_key(|e| int(e.get("id")).unwrap_or(0));
        s.nozzles = info
            .iter()
            .map(|e| {
                let id = int(e.get("id")).unwrap_or(0);
                let p = packed(e.get("temp"));
                Nozzle {
                    id,
                    current: p.map(|p| p.0),
                    target: p.map(|p| p.1),
                    side_name: if id == 1 { "Sinistro".into() } else { "Destro".into() },
                    side_letter: if id == 1 { "S".into() } else { "D".into() },
                }
            })
            .collect();
        let state = int(extruder.get("state")).unwrap_or(0);
        if s.nozzles.len() > 1 || (state & 0xF) > 1 {
            s.active_extruder = if (state >> 4) & 0xF == 1 { 1 } else { 0 };
        }
        s.dual_nozzle = s.nozzles.len() > 1;
        if s.dual_nozzle {
            let active = s.nozzles.iter().find(|n| n.id == s.active_extruder).unwrap_or(&s.nozzles[0]);
            s.nozzle = active.current;
            s.nozzle_target = active.target;
        } else if let Some(single) = s.nozzles.first().filter(|n| n.current.is_some()) {
            s.nozzle = single.current;
            s.nozzle_target = single.target;
        } else {
            s.nozzle = num(dict.get("nozzle_temper"));
            s.nozzle_target = num(dict.get("nozzle_target_temper"));
        }
        if let Some((cur, tar)) = packed(path(device, &["bed", "info", "temp"])) {
            s.bed = Some(cur);
            s.bed_target = Some(tar);
        } else {
            s.bed = num(dict.get("bed_temper"));
            s.bed_target = num(dict.get("bed_target_temper"));
        }
        if let Some((cur, tar)) = packed(path(device, &["ctc", "info", "temp"])) {
            s.chamber = Some(cur);
            s.chamber_target = if tar > 0.0 { Some(tar) } else { None };
        } else {
            s.chamber = num(dict.get("chamber_temper"));
        }

        // Modalità di lavoro (bitmask): 0x1 stampa, 0x10 laser, 0x100 taglio.
        let mode = int(device.get("type")).unwrap_or(1);
        if mode & 0x10 != 0 {
            s.work_mode = "laser".into();
        } else if mode & 0x100 != 0 {
            s.work_mode = "cut".into();
        }
        if is_laser_machine(model) && s.work_mode == "fdm" {
            s.work_mode = "laser".into();
        }
        if let Some(tool) = device.get("ext_tool") {
            if int(tool.get("mount")) == Some(1) {
                let (name, icon) = match string(tool.get("type")).to_uppercase().as_str() {
                    "LB00" => ("Laser 10 W", "laser"),
                    "LB01" => ("Laser 40 W", "laser"),
                    "CP00" => ("Lama da taglio", "cut"),
                    _ => ("Modulo accessorio", "tool"),
                };
                s.tool_module = Some(Tool { name: name.into(), icon: icon.into() });
            }
        }

        s.parse_filaments(dict, &info, model, ams_models);

        s.hms = dict
            .get("hms")
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        let attr = int(item.get("attr"))?;
                        let code = int(item.get("code"))?;
                        Some(alert(attr, code, model))
                    })
                    .collect()
            })
            .unwrap_or_default();

        if let Some(lights) = dict.get("lights_report").and_then(|v| v.as_array()) {
            if let Some(light) = lights.iter().find(|l| string(l.get("node")) == "chamber_light") {
                s.light_on = Some(string(light.get("mode")) == "on");
            }
            s.has_second_light = lights.iter().any(|l| string(l.get("node")) == "chamber_light2");
        }

        let mut name = string(dict.get("subtask_name"));
        if name.is_empty() {
            name = string(dict.get("gcode_file"));
        }
        for ext in [".gcode.3mf", ".3mf", ".gcode"] {
            if name.to_lowercase().ends_with(ext) {
                name.truncate(name.len() - ext.len());
                break;
            }
        }
        s.task_name = name;
        s
    }

    fn parse_filaments(&mut self, dict: &Value, info: &[&Value], model: &str, ams_models: &HashMap<i64, String>) {
        let empty = Value::Object(Map::new());
        let ams = dict.get("ams").unwrap_or(&empty);

        let mut loaded: HashMap<(i64, i64), i64> = HashMap::new();
        let mut active_ref: Option<(i64, i64)> = None;
        if info.iter().any(|e| e.get("snow").is_some()) {
            let snows: Vec<(i64, (i64, i64))> = info
                .iter()
                .filter_map(|e| Some((int(e.get("id"))?, decode_snow(int(e.get("snow"))?)?)))
                .collect();
            for (id, r) in &snows {
                loaded.insert(*r, *id);
                if *id == self.active_extruder || snows.len() == 1 {
                    active_ref = Some(*r);
                }
            }
        } else if let Some(r) = int(ams.get("tray_now")).and_then(decode_tray_now) {
            loaded.insert(r, 0);
            active_ref = Some(r);
        }
        let dual = self.dual_nozzle;
        let loaded_on = |r: (i64, i64)| -> Option<String> {
            if !dual {
                return None;
            }
            loaded.get(&r).map(|n| if *n == 1 { "S".to_string() } else { "D".to_string() })
        };

        let mut units: Vec<Unit> = Vec::new();
        let mut seen = HashSet::new();
        for (index, unit) in ams.get("ams").and_then(|v| v.as_array()).cloned().unwrap_or_default().iter().enumerate() {
            let unit_id = int(unit.get("id")).unwrap_or(index as i64);
            if unit_id < 0 || !seen.insert(unit_id) {
                continue;
            }
            let zones: Vec<Value> = unit.get("zone_info").and_then(|v| v.as_array()).cloned().unwrap_or_default();
            let mut trays: Vec<Tray> = unit
                .get("tray")
                .and_then(|v| v.as_array())
                .map(|list| {
                    list.iter()
                        .enumerate()
                        .map(|(si, t)| {
                            let slot = int(t.get("id")).unwrap_or(si as i64);
                            let r = (unit_id, slot);
                            tray_from(t, format!("{unit_id}-{slot}"), slot_label(unit_id, slot),
                                      Some(r) == active_ref, loaded_on(r))
                        })
                        .collect()
                })
                .unwrap_or_default();
            trays.sort_by_key(|t| t.slot);

            let mut humidity = int(unit.get("humidity_raw")).filter(|h| (1..=100).contains(h));
            if humidity.is_none() {
                humidity = zones.iter().filter_map(|z| int(z.get("humidity_raw"))).filter(|h| (1..=100).contains(h)).max();
            }
            let mut temperature = num(unit.get("temp")).filter(|t| *t > 0.0);
            if temperature.is_none() {
                temperature = zones.iter().filter_map(|z| num(z.get("temp"))).filter(|t| *t > 0.0).reduce(f64::max);
            }
            let mut drying = int(unit.get("dry_time")).unwrap_or(0);
            if drying <= 0 {
                drying = zones.iter().filter_map(|z| int(z.get("dry_time"))).max().unwrap_or(0);
            }
            let mut nozzle = None;
            if dual {
                let value = match unit.get("info") {
                    Some(Value::String(s)) => i64::from_str_radix(s, 16).ok(),
                    other => int(other),
                };
                nozzle = match value.map(|v| (v >> 8) & 0xF) {
                    Some(0) => Some("Destro".to_string()),
                    Some(1) => Some("Sinistro".to_string()),
                    Some(0xE) => Some("Selettore".to_string()),
                    _ => None,
                };
            }
            let single_slot = unit_id >= 128 || trays.len() == 1;
            let model_name = ams_models
                .get(&unit_id)
                .cloned()
                .or_else(|| if trays.len() > 4 { ams_models.get(&-1).cloned() } else { None })
                .unwrap_or_else(|| {
                    if unit_id >= 128 {
                        "AMS HT".into()
                    } else if trays.len() > 4 {
                        "AMS 3H".into()
                    } else if model.to_uppercase().starts_with('A') {
                        "AMS lite".into()
                    } else {
                        "AMS".into()
                    }
                });
            units.push(Unit {
                id: unit_id,
                model: model_name,
                letter: letter(unit_id),
                humidity,
                temperature,
                drying_minutes: drying.max(0),
                nozzle,
                single_slot,
                trays,
            });
        }
        units.sort_by_key(|u| u.id);
        self.ams_units = units;

        // Bobine esterne: "vt_tray" (un ugello) o "vir_slot" (una per ugello).
        let external: Vec<Value> = if let Some(slots) = dict.get("vir_slot").and_then(|v| v.as_array()) {
            slots.clone()
        } else if let Some(vt) = dict.get("vt_tray").filter(|v| v.is_object()) {
            vec![vt.clone()]
        } else {
            vec![]
        };
        let count = external.len();
        let mut spools: Vec<Tray> = external
            .iter()
            .map(|t| {
                let id = int(t.get("id")).unwrap_or(254);
                let label = if dual {
                    match id {
                        254 => "Est. S".to_string(),
                        255 => "Est. D".to_string(),
                        _ => "Est.".to_string(),
                    }
                } else if count > 1 {
                    format!("Est. {}", 256 - id)
                } else {
                    "Est.".to_string()
                };
                let r = (id, 0);
                tray_from(t, format!("ext-{id}"), label, Some(r) == active_ref, loaded_on(r))
            })
            .collect();
        spools.sort_by(|a, b| a.id.cmp(&b.id));
        self.external_spools = spools;
    }

    pub fn is_active(&self) -> bool {
        matches!(self.gcode_state.as_str(), "RUNNING" | "PAUSE" | "PREPARE" | "SLICING")
    }

    pub fn state_name(&self) -> String {
        let fdm = self.work_mode == "fdm";
        match self.gcode_state.as_str() {
            "RUNNING" => match self.work_mode.as_str() {
                "laser" => "Laser in funzione",
                "cut" => "Taglio in corso",
                _ => "In stampa",
            }
            .into(),
            "PAUSE" => "In pausa".into(),
            "PREPARE" => "Preparazione".into(),
            "SLICING" => "Slicing".into(),
            "FINISH" => if fdm { "Stampa completata" } else { "Lavoro completato" }.into(),
            "FAILED" => if fdm { "Stampa fallita" } else { "Lavoro non riuscito" }.into(),
            "IDLE" => "Pronta".into(),
            "" => "Sconosciuto".into(),
            other => {
                let mut c = other.to_lowercase();
                if let Some(first) = c.get_mut(0..1) {
                    first.make_ascii_uppercase();
                }
                c
            }
        }
    }

    pub fn speed_name(&self) -> Option<String> {
        if self.work_mode != "fdm" {
            return None;
        }
        Some(
            match self.speed_level {
                1 => "Silenziosa",
                2 => "Standard",
                3 => "Sport",
                4 => "Ludicrous",
                _ => return None,
            }
            .into(),
        )
    }

    /// Ci sono errori o avvisi gravi da segnalare.
    pub fn has_problems(&self) -> bool {
        self.print_error != 0 || self.hms.iter().any(|a| a.severity <= 2)
    }
}

fn alert(attr: i64, code: i64, model: &str) -> Alert {
    let module_id = (attr >> 24) & 0xFF;
    let full = format!(
        "{:04X}_{:04X}_{:04X}_{:04X}",
        (attr >> 16) & 0xFFFF,
        attr & 0xFFFF,
        (code >> 16) & 0xFFFF,
        code & 0xFFFF
    );
    let module = match module_id {
        0x03 => "Movimento",
        0x05 => "Scheda madre",
        0x07 => "AMS",
        0x08 => "Testina",
        0x0C => "Telecamera / AI",
        0x12 => "AMS lite",
        0x18 => "AMS HT",
        _ => "Stampante",
    };
    let is_ams = matches!(module_id, 0x07 | 0x12 | 0x18);
    let detail = if is_ams {
        let unit = (attr >> 16) & 0xFF;
        let slot = (attr >> 8) & 0xFF;
        Some(if module_id == 0x18 {
            format!("AMS HT {}", letter(128 + unit))
        } else if slot < 4 {
            format!("{module} {}, slot {}", letter(unit), slot + 1)
        } else {
            format!("{module} {}", letter(unit))
        })
    } else {
        None
    };
    let severity = (code >> 16) & 0xFFFF;
    Alert {
        url: format!("https://wiki.bambulab.com/en/{}/troubleshooting/hmscode/{full}", wiki_section(model)),
        code: full,
        module: module.into(),
        detail,
        severity,
        severity_name: match severity {
            1 => "Fatale",
            2 => "Grave",
            3 => "Avviso",
            _ => "Info",
        }
        .into(),
        is_ams,
    }
}

/// Titolo e codice dell'errore di stampa ("print_error").
pub fn print_error_info(code: i64, model: &str, work_mode: &str) -> (String, String, String) {
    let short = format!("{:04X}_{:04X}", (code >> 16) & 0xFFFF, code & 0xFFFF);
    let module = (code >> 24) & 0xFF;
    let ams = matches!(module, 0x07 | 0x12 | 0x18);
    let title = if code == 0x0300_400C {
        "Stampa annullata"
    } else if ams && code & 0xFFFF == 0x8011 {
        "Filamento esaurito"
    } else if ams {
        "Problema dell'AMS"
    } else if work_mode == "fdm" {
        "Errore di stampa"
    } else {
        "Errore del lavoro"
    };
    let url = format!("https://wiki.bambulab.com/en/{}/troubleshooting/hmscode/{short}", wiki_section(model));
    (title.into(), short, url)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Prova con i dati di esempio di ha-bambulab: BAMBU_MOCKS=<cartella mock_data> cargo test
    #[test]
    fn parse_mock_data() {
        let Ok(dir) = std::env::var("BAMBU_MOCKS") else { return };
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            let data: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            let mut models = HashMap::new();
            let mut model = String::new();
            if let Some(mods) = path_val(&data, &["get_version", "info", "module"]).and_then(|m| m.as_array()) {
                for m in mods {
                    if let Some((id, name)) = ams_unit_from_module(m) {
                        models.insert(id, name.to_string());
                    } else if m.get("name").and_then(|n| n.as_str()) == Some("ota") {
                        if let Some(p) = m.get("product_name").and_then(|p| p.as_str()).and_then(model_from_product) {
                            model = p;
                        }
                    }
                }
            }
            let mut raw = Value::Object(Map::new());
            deep_merge(&mut raw, path_val(&data, &["pushall", "print"]).unwrap(), false);
            let s = PrintStatus::parse(&raw, &model, &models);
            println!("== {} [{}] {} {}% mode={} tool={:?} dual={} active={}",
                path.file_name().unwrap().to_string_lossy(), model, s.state_name(), s.percent, s.work_mode,
                s.tool_module.as_ref().map(|t| t.name.clone()), s.dual_nozzle, s.active_extruder);
            println!("   nozzle {:?}/{:?} nozzles {:?} bed {:?}/{:?} chamber {:?}/{:?}",
                s.nozzle, s.nozzle_target, s.nozzles.iter().map(|n| (n.side_letter.clone(), n.current, n.target)).collect::<Vec<_>>(),
                s.bed, s.bed_target, s.chamber, s.chamber_target);
            for u in &s.ams_units {
                println!("   {} {} nozzle={:?} hum={:?} dry={} trays={:?}", u.model, u.letter, u.nozzle, u.humidity, u.drying_minutes,
                    u.trays.iter().map(|t| format!("{}:{}{}{}", t.label, if t.empty {"-".into()} else {t.kind.clone()},
                        if t.active {"*"} else {""}, t.loaded_on.clone().map(|l| format!("[{l}]")).unwrap_or_default())).collect::<Vec<_>>());
            }
            for t in &s.external_spools {
                println!("   ext {} {} active={} loaded={:?}", t.label, t.kind, t.active, t.loaded_on);
            }
        }
    }

    fn path_val<'a>(v: &'a Value, keys: &[&str]) -> Option<&'a Value> {
        path(v, keys)
    }

    #[test]
    fn merge_keeps_second_nozzle() {
        let mut raw: Value = serde_json::json!({"device": {"extruder": {"info": [{"id": 0, "temp": 200}, {"id": 1, "temp": 100}]}}});
        deep_merge(&mut raw, &serde_json::json!({"device": {"extruder": {"info": [{"id": 1, "temp": 150}]}}}), false);
        let info = raw["device"]["extruder"]["info"].as_array().unwrap();
        assert_eq!(info.len(), 2);
        assert_eq!(info[1]["temp"], 150);
        let mut raw: Value = serde_json::json!({"ams": {"ams": [{"id": "0", "tray": [{"id": "0", "tray_type": "PLA"}]}]}});
        deep_merge(&mut raw, &serde_json::json!({"ams": {"ams": [{"id": "0", "tray": [{"id": "0"}]}]}}), false);
        assert!(raw["ams"]["ams"][0]["tray"][0].get("tray_type").is_none());
    }
}
