//! Telecamera della stampante.
//! - P1 / A1 / A2: JPEG su TLS, porta 6000.
//! - X1 / X2 / P2 / H2 / H3 / R1: RTSP su TLS, porta 322, video H.264 (RTP interleaved su TCP),
//!   decodificato con OpenH264. Sulla stampante va attivata l'opzione "Liveview in LAN".
//! I fotogrammi arrivano all'interfaccia come JPEG in base64 (al massimo ~5 al secondo).

use crate::tls::{self, TlsStream};
use base64::Engine;
use md5::{Digest, Md5};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

pub enum Event {
    Frame(String),
    Error(String),
}

pub struct Stream {
    stop: Arc<AtomicBool>,
}

impl Drop for Stream {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

pub fn start<F>(host: String, access_code: String, rtsp: bool, on_event: F) -> Stream
where
    F: Fn(Event) + Send + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let flag = stop.clone();
    thread::spawn(move || {
        while !flag.load(Ordering::SeqCst) {
            let result = if rtsp {
                rtsp_session(&host, &access_code, &flag, &on_event)
            } else {
                jpeg_session(&host, &access_code, &flag, &on_event)
            };
            if flag.load(Ordering::SeqCst) {
                return;
            }
            if let Err(message) = result {
                on_event(Event::Error(message));
            }
            for _ in 0..50 {
                if flag.load(Ordering::SeqCst) {
                    return;
                }
                thread::sleep(Duration::from_millis(100));
            }
        }
    });
    Stream { stop }
}

fn b64(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

// MARK: - JPEG (porta 6000)

fn jpeg_session<F: Fn(Event)>(host: &str, code: &str, stop: &AtomicBool, on_event: &F) -> Result<(), String> {
    let mut stream = tls::connect(host, 6000, Duration::from_secs(8))
        .map_err(|e| format!("Telecamera non raggiungibile ({})", tls::describe(&e)))?;
    let mut auth = Vec::with_capacity(80);
    for v in [0x40u32, 0x3000, 0, 0] {
        auth.extend_from_slice(&v.to_le_bytes());
    }
    for text in ["bblp", code] {
        let mut field = text.as_bytes().iter().take(32).copied().collect::<Vec<u8>>();
        field.resize(32, 0);
        auth.extend_from_slice(&field);
    }
    stream.write_all(&auth).map_err(|e| e.to_string())?;
    stream.flush().ok();
    stream.sock.set_read_timeout(Some(Duration::from_millis(500))).ok();

    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 256 * 1024];
    let mut last_frame = Instant::now();
    loop {
        if stop.load(Ordering::SeqCst) {
            return Ok(());
        }
        match stream.read(&mut chunk) {
            Ok(0) => return Err("Telecamera disconnessa (access code errato?)".into()),
            Ok(n) => buffer.extend_from_slice(&chunk[..n]),
            Err(e) if tls::is_timeout(&e) => {}
            Err(e) => return Err(format!("Telecamera: {}", tls::describe(&e))),
        }
        while buffer.len() >= 16 {
            let size = u32::from_le_bytes([buffer[0], buffer[1], buffer[2], buffer[3]]) as usize;
            if size == 0 || size > 8_000_000 {
                buffer.clear();
                break;
            }
            if buffer.len() < 16 + size {
                break;
            }
            let jpeg = buffer[16..16 + size].to_vec();
            buffer.drain(..16 + size);
            last_frame = Instant::now();
            on_event(Event::Frame(b64(&jpeg)));
        }
        if last_frame.elapsed() > Duration::from_secs(12) {
            return Err("Nessuna immagine dalla telecamera".into());
        }
    }
}

// MARK: - RTSP (porta 322)

#[derive(PartialEq)]
enum Step {
    Describe,
    Setup,
    Play,
    Streaming,
}

struct Rtsp<'a> {
    stream: TlsStream,
    host: &'a str,
    code: &'a str,
    cseq: u32,
    session: Option<String>,
    base_url: String,
    digest: Option<(String, String)>,
    last_request: Option<(String, String, Vec<String>)>,
}

impl<'a> Rtsp<'a> {
    fn stream_url(&self) -> String {
        format!("rtsp://{}:322/streaming/live/1", self.host)
    }

    fn authorization(&self, method: &str, uri: &str) -> String {
        if let Some((realm, nonce)) = &self.digest {
            let md5 = |s: String| format!("{:x}", Md5::digest(s.as_bytes()));
            let ha1 = md5(format!("bblp:{realm}:{}", self.code));
            let ha2 = md5(format!("{method}:{uri}"));
            let response = md5(format!("{ha1}:{nonce}:{ha2}"));
            format!(r#"Digest username="bblp", realm="{realm}", nonce="{nonce}", uri="{uri}", response="{response}""#)
        } else {
            format!("Basic {}", b64(format!("bblp:{}", self.code).as_bytes()))
        }
    }

    fn send(&mut self, method: &str, url: &str, headers: &[String]) -> Result<(), String> {
        self.cseq += 1;
        self.last_request = Some((method.into(), url.into(), headers.to_vec()));
        let mut lines = vec![
            format!("{method} {url} RTSP/1.0"),
            format!("CSeq: {}", self.cseq),
            "User-Agent: BambuGo".into(),
            format!("Authorization: {}", self.authorization(method, url)),
        ];
        if let Some(s) = &self.session {
            lines.push(format!("Session: {s}"));
        }
        lines.extend(headers.iter().cloned());
        let text = lines.join("\r\n") + "\r\n\r\n";
        self.stream.write_all(text.as_bytes()).map_err(|e| e.to_string())?;
        self.stream.flush().map_err(|e| e.to_string())
    }
}

fn header_value(header: &str, key: &str) -> Option<String> {
    let start = header.find(&format!("{key}=\""))? + key.len() + 2;
    let rest = &header[start..];
    Some(rest[..rest.find('"')?].to_string())
}

struct H264 {
    decoder: Option<openh264::decoder::Decoder>,
    sps: Option<Vec<u8>>,
    pps: Option<Vec<u8>>,
    nals: Vec<Vec<u8>>,
    fu: Option<Vec<u8>>,
    timestamp: Option<u32>,
    last_ui: Instant,
}

impl H264 {
    fn new() -> Self {
        H264 { decoder: None, sps: None, pps: None, nals: vec![], fu: None, timestamp: None, last_ui: Instant::now() - Duration::from_secs(1) }
    }

    fn append(&mut self, nal: Vec<u8>) {
        if nal.is_empty() {
            return;
        }
        match nal[0] & 0x1F {
            7 => self.sps = Some(nal),
            8 => self.pps = Some(nal),
            9 => {}
            _ => self.nals.push(nal),
        }
    }

    fn rtp<F: Fn(Event)>(&mut self, p: &[u8], on_event: &F) {
        if p.len() <= 12 {
            return;
        }
        let csrc = (p[0] & 0x0F) as usize;
        let extension = p[0] & 0x10 != 0;
        let padding = if p[0] & 0x20 != 0 { p[p.len() - 1] as usize } else { 0 };
        let marker = p[1] & 0x80 != 0;
        let ts = u32::from_be_bytes([p[4], p[5], p[6], p[7]]);
        let mut offset = 12 + csrc * 4;
        if extension {
            if p.len() < offset + 4 {
                return;
            }
            offset += 4 + (((p[offset + 2] as usize) << 8) | p[offset + 3] as usize) * 4;
        }
        let end = p.len().saturating_sub(padding);
        if offset >= end {
            return;
        }
        let payload = &p[offset..end];
        if let Some(cur) = self.timestamp {
            if cur != ts {
                self.flush(on_event);
            }
        }
        self.timestamp = Some(ts);

        match payload[0] & 0x1F {
            1..=23 => self.append(payload.to_vec()),
            24 => {
                let mut i = 1;
                while i + 2 <= payload.len() {
                    let size = ((payload[i] as usize) << 8) | payload[i + 1] as usize;
                    i += 2;
                    if size == 0 || i + size > payload.len() {
                        break;
                    }
                    self.append(payload[i..i + size].to_vec());
                    i += size;
                }
            }
            28 => {
                if payload.len() <= 2 {
                    return;
                }
                let header = payload[1];
                if header & 0x80 != 0 {
                    let mut nal = vec![(payload[0] & 0xE0) | (header & 0x1F)];
                    nal.extend_from_slice(&payload[2..]);
                    self.fu = Some(nal);
                } else if let Some(fu) = self.fu.as_mut() {
                    fu.extend_from_slice(&payload[2..]);
                }
                if header & 0x40 != 0 {
                    if let Some(nal) = self.fu.take() {
                        self.append(nal);
                    }
                }
            }
            _ => {}
        }
        if marker {
            self.flush(on_event);
        }
    }

    fn flush<F: Fn(Event)>(&mut self, on_event: &F) {
        let nals = std::mem::take(&mut self.nals);
        if nals.is_empty() {
            return;
        }
        if self.decoder.is_none() {
            if self.sps.is_none() || self.pps.is_none() {
                return;
            }
            match openh264::decoder::Decoder::new() {
                Ok(d) => self.decoder = Some(d),
                Err(_) => return,
            }
        }
        let mut annexb = Vec::new();
        let idr = nals.iter().any(|n| n[0] & 0x1F == 5);
        if idr {
            for ps in [&self.sps, &self.pps].into_iter().flatten() {
                annexb.extend_from_slice(&[0, 0, 0, 1]);
                annexb.extend_from_slice(ps);
            }
        }
        for nal in &nals {
            annexb.extend_from_slice(&[0, 0, 0, 1]);
            annexb.extend_from_slice(nal);
        }
        let Some(decoder) = self.decoder.as_mut() else { return };
        let Ok(Some(yuv)) = decoder.decode(&annexb) else { return };
        if self.last_ui.elapsed() < Duration::from_millis(200) {
            return;
        }
        self.last_ui = Instant::now();
        use openh264::formats::YUVSource;
        let (w, h) = yuv.dimensions();
        let mut rgb = vec![0u8; w * h * 3];
        yuv.write_rgb8(&mut rgb);
        let Some(img) = image::RgbImage::from_raw(w as u32, h as u32, rgb) else { return };
        // Basta una risoluzione adatta al pannello.
        let img = if w > 960 {
            image::imageops::resize(&img, 960, (h * 960 / w) as u32, image::imageops::FilterType::Triangle)
        } else {
            img
        };
        let mut jpeg = Vec::new();
        let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 75);
        if encoder.encode_image(&img).is_ok() {
            on_event(Event::Frame(b64(&jpeg)));
        }
    }
}

fn rtsp_session<F: Fn(Event)>(host: &str, code: &str, stop: &AtomicBool, on_event: &F) -> Result<(), String> {
    let hint = " Sulla stampante attiva «Liveview in LAN».";
    let stream = tls::connect(host, 322, Duration::from_secs(8))
        .map_err(|e| format!("Telecamera non raggiungibile ({}).{hint}", tls::describe(&e)))?;
    stream.sock.set_read_timeout(Some(Duration::from_millis(500))).ok();
    let mut rtsp = Rtsp {
        stream,
        host,
        code,
        cseq: 0,
        session: None,
        base_url: String::new(),
        digest: None,
        last_request: None,
    };
    let url = rtsp.stream_url();
    rtsp.base_url = url.clone();
    rtsp.send("DESCRIBE", &url, &["Accept: application/sdp".into()])?;

    let mut step = Step::Describe;
    let mut auth_retried = false;
    let mut h264 = H264::new();
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 256 * 1024];
    let mut last_packet = Instant::now();
    let mut last_keepalive = Instant::now();

    loop {
        if stop.load(Ordering::SeqCst) {
            return Ok(());
        }
        match rtsp.stream.read(&mut chunk) {
            Ok(0) => return Err("Telecamera disconnessa".into()),
            Ok(n) => buffer.extend_from_slice(&chunk[..n]),
            Err(e) if tls::is_timeout(&e) => {}
            Err(e) => return Err(format!("Telecamera: {}", tls::describe(&e))),
        }

        loop {
            if buffer.is_empty() {
                break;
            }
            if buffer[0] == b'$' {
                if buffer.len() < 4 {
                    break;
                }
                let len = ((buffer[2] as usize) << 8) | buffer[3] as usize;
                if buffer.len() < 4 + len {
                    break;
                }
                let channel = buffer[1];
                let packet: Vec<u8> = buffer[4..4 + len].to_vec();
                buffer.drain(..4 + len);
                last_packet = Instant::now();
                if channel == 0 {
                    h264.rtp(&packet, on_event);
                }
            } else if buffer[0] == b'R' {
                let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") else {
                    if buffer.len() > 64 * 1024 {
                        buffer.clear();
                    }
                    break;
                };
                let head = String::from_utf8_lossy(&buffer[..end]).to_string();
                let mut lines = head.split("\r\n");
                let status_line = lines.next().unwrap_or("");
                let mut headers = std::collections::HashMap::new();
                for line in lines {
                    if let Some((k, v)) = line.split_once(':') {
                        headers.insert(k.trim().to_lowercase(), v.trim().to_string());
                    }
                }
                let body_len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
                if buffer.len() < end + 4 + body_len {
                    break;
                }
                let body = String::from_utf8_lossy(&buffer[end + 4..end + 4 + body_len]).to_string();
                buffer.drain(..end + 4 + body_len);
                let status: u32 = status_line.split(' ').nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
                last_packet = Instant::now();

                if step == Step::Streaming {
                    continue; // risposte ai keep-alive
                }
                if status == 401 {
                    let Some((method, url, hdrs)) = rtsp.last_request.clone().filter(|_| !auth_retried) else {
                        return Err("Access code rifiutato dalla telecamera".into());
                    };
                    auth_retried = true;
                    if let Some(h) = headers.get("www-authenticate").filter(|h| h.to_lowercase().starts_with("digest")) {
                        rtsp.digest = Some((header_value(h, "realm").unwrap_or_default(), header_value(h, "nonce").unwrap_or_default()));
                    }
                    rtsp.send(&method, &url, &hdrs)?;
                    continue;
                }
                if !(200..300).contains(&status) {
                    return Err(format!("La telecamera ha risposto {status}.{hint}"));
                }
                auth_retried = false;
                match step {
                    Step::Describe => {
                        let mut base = headers.get("content-base").cloned().unwrap_or_else(|| rtsp.stream_url());
                        if base.ends_with('/') {
                            base.pop();
                        }
                        rtsp.base_url = base.clone();
                        let track = parse_sdp(&body, &base, &mut h264)?;
                        step = Step::Setup;
                        rtsp.send("SETUP", &track, &["Transport: RTP/AVP/TCP;unicast;interleaved=0-1".into()])?;
                    }
                    Step::Setup => {
                        if let Some(s) = headers.get("session") {
                            rtsp.session = s.split(';').next().map(|s| s.to_string());
                        }
                        step = Step::Play;
                        let base = rtsp.base_url.clone();
                        rtsp.send("PLAY", &base, &["Range: npt=0.000-".into()])?;
                    }
                    Step::Play => step = Step::Streaming,
                    Step::Streaming => {}
                }
            } else {
                // byte non riconosciuti: si riallinea
                match buffer.iter().position(|b| *b == b'$' || *b == b'R') {
                    Some(next) if next > 0 => {
                        buffer.drain(..next);
                    }
                    _ => buffer.clear(),
                }
            }
        }

        if last_packet.elapsed() > Duration::from_secs(15) {
            return Err("Nessuna immagine dalla telecamera".into());
        }
        if step == Step::Streaming && last_keepalive.elapsed() > Duration::from_secs(25) {
            last_keepalive = Instant::now();
            let base = rtsp.base_url.clone();
            rtsp.send("GET_PARAMETER", &base, &[])?;
        }
    }
}

/// Legge l'SDP: URL della traccia video e parametri SPS/PPS.
fn parse_sdp(sdp: &str, base: &str, h264: &mut H264) -> Result<String, String> {
    let mut in_video = false;
    let mut control: Option<String> = None;
    let mut codec = String::new();
    for raw in sdp.lines() {
        let line = raw.trim();
        if line.starts_with("m=") {
            in_video = line.starts_with("m=video");
            continue;
        }
        if !in_video {
            continue;
        }
        if let Some(c) = line.strip_prefix("a=control:") {
            control = Some(c.to_string());
        } else if line.starts_with("a=rtpmap:") {
            codec = line.to_uppercase();
        } else if line.starts_with("a=fmtp:") {
            if let Some(pos) = line.find("sprop-parameter-sets=") {
                let sets = line[pos + 21..].split(';').next().unwrap_or("");
                for part in sets.split(',') {
                    if let Ok(nal) = base64::engine::general_purpose::STANDARD.decode(part.trim()) {
                        if !nal.is_empty() {
                            h264.append(nal);
                        }
                    }
                }
            }
        }
    }
    if codec.contains("H265") || codec.contains("HEVC") {
        return Err("Il video H.265 di questa stampante non è ancora supportato.".into());
    }
    Ok(match control {
        None => base.to_string(),
        Some(c) if c == "*" => base.to_string(),
        Some(c) if c.to_lowercase().starts_with("rtsp://") => c,
        Some(c) => format!("{base}/{c}"),
    })
}
