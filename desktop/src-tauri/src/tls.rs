//! Connessioni TLS verso la stampante: il certificato è self-signed, quindi non viene verificato.

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{ClientConfig, ClientConnection, DigitallySignedStruct, SignatureScheme, StreamOwned};
use std::io;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

pub type TlsStream = StreamOwned<ClientConnection, TcpStream>;

#[derive(Debug)]
struct AcceptAny(Arc<rustls::crypto::CryptoProvider>);

impl ServerCertVerifier for AcceptAny {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Ok(HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

fn config() -> Arc<ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("versioni TLS")
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAny(provider)))
        .with_no_client_auth();
    Arc::new(config)
}

/// Apre una connessione TLS con timeout di connessione e handshake.
pub fn connect(host: &str, port: u16, timeout: Duration) -> io::Result<TlsStream> {
    let addr = (host, port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "indirizzo non valido"))?;
    let mut sock = TcpStream::connect_timeout(&addr, timeout)?;
    sock.set_nodelay(true).ok();
    sock.set_read_timeout(Some(timeout))?;
    sock.set_write_timeout(Some(timeout))?;

    let name = ServerName::try_from(host.to_string())
        .unwrap_or_else(|_| ServerName::try_from("bambulab".to_string()).unwrap());
    let mut conn = ClientConnection::new(config(), name)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e.to_string()))?;
    while conn.is_handshaking() {
        conn.complete_io(&mut sock)?;
    }
    Ok(StreamOwned::new(conn, sock))
}

/// Errore di lettura dovuto solo al timeout (nessun dato per ora).
pub fn is_timeout(e: &io::Error) -> bool {
    matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut)
}

/// Descrizione leggibile di un errore di rete.
pub fn describe(e: &io::Error) -> String {
    match e.kind() {
        io::ErrorKind::ConnectionRefused => "connessione rifiutata".into(),
        io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => "nessuna risposta".into(),
        io::ErrorKind::HostUnreachable | io::ErrorKind::NetworkUnreachable => "rete non raggiungibile".into(),
        io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset => "connessione chiusa".into(),
        _ => e.to_string(),
    }
}
