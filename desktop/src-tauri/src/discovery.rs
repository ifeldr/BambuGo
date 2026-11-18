//! Ricerca delle stampanti in rete: si annunciano con messaggi SSDP sulla porta UDP 2021.

use crate::status::{model_from_code, model_from_serial};
use serde::Serialize;
use socket2::{Domain, Protocol, Socket, Type};
use std::collections::HashMap;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::time::{Duration, Instant};

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Discovered {
    pub id: String,
    pub host: String,
    pub name: String,
    pub model: String,
}

pub fn search(seconds: f64) -> Vec<Discovered> {
    let Ok(socket) = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP)) else {
        return vec![];
    };
    socket.set_reuse_address(true).ok();
    #[cfg(all(unix, not(target_os = "solaris")))]
    socket.set_reuse_port(true).ok();
    socket.set_broadcast(true).ok();
    socket.set_read_timeout(Some(Duration::from_millis(500))).ok();
    let bind: SocketAddr = SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, 2021).into();
    if socket.bind(&bind.into()).is_err() {
        return vec![];
    }
    let socket: std::net::UdpSocket = socket.into();

    // Richiesta di ricerca: alcune stampanti rispondono subito invece di aspettare l'annuncio.
    let request = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1990\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\nST: urn:bambulab-com:device:3dprinter:1\r\n\r\n";
    for target in ["239.255.255.250:1990", "255.255.255.255:2021"] {
        let _ = socket.send_to(request.as_bytes(), target);
    }

    let mut found: HashMap<String, Discovered> = HashMap::new();
    let mut buf = [0u8; 4096];
    let deadline = Instant::now() + Duration::from_secs_f64(seconds);
    while Instant::now() < deadline {
        let Ok((n, sender)) = socket.recv_from(&mut buf) else { continue };
        let text = String::from_utf8_lossy(&buf[..n]);
        if let Some(p) = parse(&text, sender) {
            found.insert(p.id.clone(), p);
        }
    }
    let mut list: Vec<Discovered> = found.into_values().collect();
    list.sort_by(|a, b| a.name.cmp(&b.name));
    list
}

fn parse(text: &str, sender: SocketAddr) -> Option<Discovered> {
    let mut headers: HashMap<String, String> = HashMap::new();
    for line in text.split("\r\n") {
        if let Some((k, v)) = line.split_once(':') {
            headers.insert(k.trim().to_lowercase(), v.trim().to_string());
        }
    }
    let serial = headers.get("usn").filter(|s| !s.is_empty())?.clone();
    let is_bambu = headers.contains_key("devmodel.bambu.com")
        || headers.get("nt").map_or(false, |nt| nt.contains("bambulab"));
    if !is_bambu {
        return None;
    }
    let host = headers
        .get("location")
        .filter(|h| !h.is_empty())
        .cloned()
        .unwrap_or_else(|| sender.ip().to_string());
    let code = headers.get("devmodel.bambu.com").cloned().unwrap_or_default();
    let model = model_from_code(&code)
        .or_else(|| model_from_serial(&serial))
        .map(String::from)
        .unwrap_or(code);
    let name = headers
        .get("devname.bambu.com")
        .filter(|n| !n.is_empty())
        .cloned()
        .unwrap_or_else(|| model.clone());
    Some(Discovered { id: serial, host, name, model })
}
