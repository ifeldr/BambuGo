//! Client MQTT 3.1.1 minimo (QoS 0) su TLS, porta 8883: è tutto ciò che serve con la stampante.

use crate::tls;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

pub enum Event {
    Connected,
    Disconnected(String),
    AuthRejected,
    Message(Vec<u8>),
}

pub struct Handle {
    stop: Arc<AtomicBool>,
    outgoing: Sender<(String, Vec<u8>)>,
}

impl Handle {
    pub fn publish(&self, topic: &str, payload: &[u8]) {
        let _ = self.outgoing.send((topic.to_string(), payload.to_vec()));
    }
}

impl Drop for Handle {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
    }
}

pub fn start<F>(host: String, password: String, client_id: String, topic: String, on_event: F) -> Handle
where
    F: Fn(Event) + Send + 'static,
{
    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = channel();
    let flag = stop.clone();
    thread::spawn(move || run(host, password, client_id, topic, flag, rx, on_event));
    Handle { stop, outgoing: tx }
}

fn run<F: Fn(Event)>(
    host: String,
    password: String,
    client_id: String,
    topic: String,
    stop: Arc<AtomicBool>,
    outgoing: Receiver<(String, Vec<u8>)>,
    on_event: F,
) {
    while !stop.load(Ordering::SeqCst) {
        match session(&host, &password, &client_id, &topic, &stop, &outgoing, &on_event) {
            Ok(()) => {}
            Err(SessionError::Auth) => {
                on_event(Event::AuthRejected);
                return;
            }
            Err(SessionError::Other(message)) => {
                if stop.load(Ordering::SeqCst) {
                    return;
                }
                on_event(Event::Disconnected(message));
            }
        }
        // Riprova dopo qualche secondo (controllando spesso se ci hanno fermati).
        for _ in 0..50 {
            if stop.load(Ordering::SeqCst) {
                return;
            }
            thread::sleep(Duration::from_millis(100));
        }
        // Svuota i comandi accodati mentre eravamo scollegati.
        while outgoing.try_recv().is_ok() {}
    }
}

enum SessionError {
    Auth,
    Other(String),
}

fn err(e: std::io::Error) -> SessionError {
    SessionError::Other(format!("Stampante non raggiungibile ({})", tls::describe(&e)))
}

fn encode_length(mut len: usize, out: &mut Vec<u8>) {
    loop {
        let mut byte = (len % 128) as u8;
        len /= 128;
        if len > 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if len == 0 {
            break;
        }
    }
}

fn packet(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut out = vec![kind];
    encode_length(body.len(), &mut out);
    out.extend_from_slice(body);
    out
}

fn string(s: &str, out: &mut Vec<u8>) {
    out.extend_from_slice(&(s.len() as u16).to_be_bytes());
    out.extend_from_slice(s.as_bytes());
}

fn session<F: Fn(Event)>(
    host: &str,
    password: &str,
    client_id: &str,
    topic: &str,
    stop: &AtomicBool,
    outgoing: &Receiver<(String, Vec<u8>)>,
    on_event: &F,
) -> Result<(), SessionError> {
    let mut stream = tls::connect(host, 8883, Duration::from_secs(8)).map_err(err)?;

    // CONNECT: protocollo MQTT 3.1.1, sessione pulita, utente e password, keep-alive 30 s.
    let mut body = Vec::new();
    string("MQTT", &mut body);
    body.push(4);
    body.push(0b1100_0010);
    body.extend_from_slice(&30u16.to_be_bytes());
    string(client_id, &mut body);
    string("bblp", &mut body);
    string(password, &mut body);
    stream.write_all(&packet(0x10, &body)).map_err(err)?;
    stream.flush().map_err(err)?;

    stream.sock.set_read_timeout(Some(Duration::from_millis(500))).ok();
    let mut buffer: Vec<u8> = Vec::new();
    let mut chunk = vec![0u8; 64 * 1024];
    let mut connected = false;
    let started = Instant::now();
    let mut last_rx = Instant::now();
    let mut last_ping = Instant::now();
    let mut packet_id: u16 = 1;

    loop {
        if stop.load(Ordering::SeqCst) {
            let _ = stream.write_all(&[0xE0, 0]); // DISCONNECT
            return Ok(());
        }

        match stream.read(&mut chunk) {
            Ok(0) => return Err(SessionError::Other("Connessione chiusa dalla stampante".into())),
            Ok(n) => {
                buffer.extend_from_slice(&chunk[..n]);
                last_rx = Instant::now();
            }
            Err(e) if tls::is_timeout(&e) => {}
            Err(e) => return Err(err(e)),
        }

        // Pacchetti completi nel buffer.
        loop {
            if buffer.len() < 2 {
                break;
            }
            let mut len: usize = 0;
            let mut mult: usize = 1;
            let mut i = 1;
            let mut complete = false;
            while i < buffer.len() && i <= 4 {
                let b = buffer[i];
                len += (b & 0x7F) as usize * mult;
                mult *= 128;
                i += 1;
                if b & 0x80 == 0 {
                    complete = true;
                    break;
                }
            }
            if !complete {
                if buffer.len() > 5 {
                    return Err(SessionError::Other("Dati MQTT non validi".into()));
                }
                break;
            }
            if buffer.len() < i + len {
                break;
            }
            let kind = buffer[0] >> 4;
            let flags = buffer[0] & 0x0F;
            let body: Vec<u8> = buffer[i..i + len].to_vec();
            buffer.drain(..i + len);

            match kind {
                2 => {
                    // CONNACK
                    let code = body.get(1).copied().unwrap_or(0);
                    if code == 4 || code == 5 {
                        return Err(SessionError::Auth);
                    }
                    if code != 0 {
                        return Err(SessionError::Other(format!("Connessione rifiutata (codice {code})")));
                    }
                    let mut sub = Vec::new();
                    sub.extend_from_slice(&packet_id.to_be_bytes());
                    packet_id = packet_id.wrapping_add(1).max(1);
                    string(topic, &mut sub);
                    sub.push(0);
                    stream.write_all(&packet(0x82, &sub)).map_err(err)?;
                    connected = true;
                    on_event(Event::Connected);
                }
                3 => {
                    // PUBLISH
                    if body.len() < 2 {
                        continue;
                    }
                    let topic_len = u16::from_be_bytes([body[0], body[1]]) as usize;
                    let mut start = 2 + topic_len;
                    if (flags >> 1) & 0x3 > 0 {
                        start += 2; // identificativo del pacchetto (QoS 1/2)
                    }
                    if start <= body.len() {
                        on_event(Event::Message(body[start..].to_vec()));
                    }
                }
                _ => {} // SUBACK, PINGRESP…
            }
        }

        if !connected && started.elapsed() > Duration::from_secs(10) {
            return Err(SessionError::Other("La stampante non risponde (MQTT)".into()));
        }
        if last_rx.elapsed() > Duration::from_secs(70) {
            return Err(SessionError::Other("Nessun dato dalla stampante".into()));
        }

        if connected {
            while let Ok((topic, payload)) = outgoing.try_recv() {
                let mut body = Vec::new();
                string(&topic, &mut body);
                body.extend_from_slice(&payload);
                stream.write_all(&packet(0x30, &body)).map_err(err)?;
            }
            if last_ping.elapsed() > Duration::from_secs(20) {
                stream.write_all(&[0xC0, 0]).map_err(err)?;
                last_ping = Instant::now();
            }
            stream.flush().map_err(err)?;
        }
    }
}
