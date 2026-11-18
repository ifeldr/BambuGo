<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Icona di BambuGo"></p>

# BambuGo

[![Offrimi un caffè](https://img.shields.io/badge/☕_Offrimi_un_caffè-PayPal-0070ba?logo=paypal&logoColor=white)](https://www.paypal.me/lorenzogarbi)
[![Licenza MIT](https://img.shields.io/badge/licenza-MIT-green)](LICENSE)

App per **macOS, Windows e Linux** che mostra nella barra dei menu (o nel tray) lo stato di una macchina Bambu Lab
(tutte le stampanti 3D, dalla A1 mini alla H3C, e l'incisore laser R1) collegandosi
**direttamente in rete locale**: nessun account, nessun cloud, nessun dato che esce dalla tua rete.

Nella barra compare una piccola stampante (su Windows e Linux un'icona colorata nel tray): durante la stampa l'oggetto sul piatto cresce
con l'avanzamento, accanto a `45% · 1h 12m`; un simbolo indica pausa, fine o errori.
Cliccando si apre un pannello a schede con:

- **avanzamento**: anello con la percentuale, nome del lavoro, strato, tempo rimanente e ora di fine;
- **Pausa / Riprendi / Interrompi** (l'interruzione chiede conferma);
- **telecamera** in diretta, con interruttore della luce e apertura in una finestra sempre in primo piano;
- **temperature** di ugello (entrambi, sulle stampanti a doppio ugello), piatto e camera con l'obiettivo di riscaldamento;
- **bobine** di tutte le unità collegate — AMS, AMS lite, AMS 2 Pro, AMS HT, AMS 3H — e delle bobine esterne:
  colore, materiale, residuo, slot in uso, ugello in cui è caricata, umidità, temperatura ed essiccazione in corso;
- **modulo laser e lama** (H2D, H2S, H2C…): modulo montato e modalità laser/taglio, con stati e notifiche dedicati;
- **errori e avvisi** della stampante e dell'AMS (codici HMS), con link alla spiegazione sul wiki Bambu Lab;
- qualità del Wi-Fi e velocità di stampa.

Notifiche a fine stampa, errore e pausa (es. filamento finito).

In più: **browser di modelli pronti** su MakerWorld, Printables e Thingiverse
(su Windows e Linux i siti si aprono nel browser predefinito).

> BambuGo è un progetto indipendente e non è affiliato, approvato o sponsorizzato da Bambu Lab.
> "Bambu Lab" e i nomi delle stampanti sono marchi dei rispettivi proprietari.
> L'app comunica solo con la stampante nella tua rete locale, tramite il protocollo che la
> stampante stessa espone in modalità LAN. È fornita "così com'è", senza garanzie:
> **la usi a tuo rischio** (vedi [LICENSE](LICENSE)).

## Requisiti

- **macOS** 13 Ventura o successivo
- **Windows** 10 o 11 (64 bit)
- **Linux** a 64 bit: Ubuntu 22.04+, Debian 12+, Fedora 39+, Arch Linux e derivate
- Il computer deve raggiungere la stampante (stessa rete, oppure VPN verso casa)

## Download

Tutti i pacchetti sono nell'ultima [release](https://github.com/ifeldr/BambuGo/releases/latest).

| Sistema | File | Installazione |
|---|---|---|
| macOS | `BambuGo.zip` | estrai e sposta l'app in *Applicazioni* (vedi sotto) |
| Windows | `BambuGo_…_x64-setup.exe` oppure `BambuGo_…_x64_it-IT.msi` | doppio clic |
| Ubuntu / Debian | `BambuGo_…_amd64.deb` | `sudo apt install ./BambuGo_*_amd64.deb` |
| Fedora | `BambuGo-…x86_64.rpm` | `sudo dnf install ./BambuGo-*.x86_64.rpm` |
| Arch e altre distro | `BambuGo_…_amd64.AppImage` | `chmod +x BambuGo_*.AppImage` e avvialo |

**macOS** — l'app non è firmata con un certificato Apple, quindi al primo avvio macOS la blocca:
apri *Impostazioni di Sistema → Privacy e sicurezza* e premi **Apri comunque**, oppure da Terminale:

```bash
xattr -dr com.apple.quarantine /Applications/BambuGo.app
```

**Windows** — l'installer non è firmato: se compare SmartScreen scegli *Ulteriori informazioni →
Esegui comunque*. Al primo avvio consenti BambuGo nel firewall (serve per la ricerca in rete).
Clicca l'icona nel tray (eventualmente nella freccia ^ accanto all'orologio) per aprire il pannello.

**Linux** — l'icona compare nell'area di notifica; il clic apre un menu con *Apri BambuGo*.
Su **GNOME** (Ubuntu ha già l'estensione, Fedora no) serve l'estensione
[AppIndicator](https://extensions.gnome.org/extension/615/appindicator-support/); in alternativa
riapri BambuGo dal menu delle applicazioni e il pannello si mostra. Su Arch, per l'icona nel tray
serve il pacchetto `libayatana-appindicator`.

## Compilazione

**macOS** — servono i Command Line Tools di Xcode (`xcode-select --install`, Xcode completo non serve).

```bash
cd BambuGo
chmod +x build.sh
./build.sh
cp -R build/BambuGo.app /Applications/
open /Applications/BambuGo.app
```

**Windows e Linux** — la versione per questi sistemi è nella cartella [`desktop/`](desktop) ed è fatta con
[Tauri](https://tauri.app) (Rust + interfaccia web). Servono Rust, Node.js e, su Linux, le librerie di WebKitGTK
(su Ubuntu/Debian: `sudo apt install libwebkit2gtk-4.1-dev libayatana-appindicator3-dev librsvg2-dev`).

```bash
cd desktop
npm ci
npx tauri build      # pacchetti in src-tauri/target/release/bundle/
```

Le release per tutti i sistemi le compila GitHub Actions.

## Configurazione

1. Clicca l'icona nella barra dei menu e premi **Cerca in rete**: le stampanti che si
   annunciano in rete compaiono in elenco con nome, modello e IP. Se non ne trova,
   inserisci a mano IP e numero di serie.
2. Inserisci l'**access code** (display della stampante: Impostazioni → Rete/WLAN).
3. Su macOS concedi il permesso **Rete locale** quando lo chiede
   (Impostazioni di Sistema → Privacy e sicurezza → Rete locale); su Windows consenti l'accesso
   nel firewall.

Conviene riservare l'IP della stampante nel DHCP del router, così non cambia.

## Compatibilità

| Funzione | A1 / A1 mini / A2L | P1P / P1S | P2S | X1 / X1C / X1E / X2D | H2D / H2D Pro / H2S / H2C | H3C | R1 (laser) |
|---|---|---|---|---|---|---|---|
| Stato, avanzamento, errori HMS | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ ³ |
| Temperature | ✅ | ✅ | ✅ | ✅ | ✅ doppio ugello | ✅ | — |
| AMS e bobine esterne | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| Modulo laser / lama | ✅ ⁴ | — | — | — | ✅ | — | ✅ |
| Pausa / Riprendi / Interrompi, luce | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ |
| Telecamera | ✅ JPEG | ✅ JPEG | ✅ ² | ✅ ² | ✅ ² | ✅ ² | ✅ ² ³ |

Unità di alimentazione riconosciute: **AMS**, **AMS lite**, **AMS 2 Pro**, **AMS HT** e **AMS 3H**, anche
più unità insieme (fino a 4 AMS + 8 AMS HT sulle H2), con l'indicazione dell'ugello a cui sono collegate
sulle stampanti a doppio ugello (H2D, H2D Pro, H2C, X2D).

1. Con i firmware più recenti la macchina accetta comandi da app di terze parti solo con
   la **modalità LAN** e la **modalità sviluppatore** attive sul display; altrimenti il
   pannello segnala che il comando è stato rifiutato. La lettura dello stato funziona comunque.
2. Queste macchine trasmettono in RTSP: va attivata l'opzione **Liveview in LAN**
   (*LAN Only Liveview*). I video H.265 non sono supportati. Se il protocollo non risponde
   l'app prova automaticamente l'altro.
3. R1, H3C, A2L, X2D e P2S non sono ancora state provate su una macchina reale: i dati seguono
   il protocollo usato da Bambu Studio. Se qualcosa non torna apri una segnalazione.
4. A2L: i moduli per lama e penna vengono mostrati come "modulo accessorio".

## Modelli online

Il pulsante **Modelli online** del pannello apre una finestra con MakerWorld, Printables
e Thingiverse (il login ai siti resta salvato). I file scaricati finiscono in *Download*
e una barra in basso permette di mostrarli nel Finder. Rispetta la licenza di ciascun modello.

## Come funziona

| | Porta | Accesso |
|---|---|---|
| Stato e comandi (MQTT su TLS) | 8883 | utente `bblp`, password = access code |
| Telecamera P1 / A1 / A2 (JPEG su TLS) | 6000 | access code |
| Telecamera X1 / X2 / P2 / H2 / H3 / R1 (RTSP su TLS) | 322 | utente `bblp`, password = access code |
| Ricerca in rete (SSDP) | UDP 2021 | — |

L'app si iscrive a `device/<seriale>/report` e chiede lo stato completo (`pushall`) alla
connessione e quando premi "Aggiorna". I certificati della stampante sono self-signed e
vengono accettati. Su macOS l'access code è conservato nel Portachiavi.

## Note

- Dopo ogni ricompilazione macOS può chiedere di autorizzare l'accesso al Portachiavi
  (la firma ad-hoc cambia): scegli "Consenti sempre".
- Su Windows e Linux le impostazioni sono in un file nella cartella di configurazione dell'utente
  (`%APPDATA%\it.ifeldr.bambugo` oppure `~/.config/it.ifeldr.bambugo`); su Linux il file è leggibile solo dall'utente.
- P1 e A1 accettano poche connessioni MQTT contemporanee: se hai già altre app collegate
  (es. Home Assistant) BambuGo potrebbe non riuscire a connettersi.
- Gli unici comandi inviati alla stampante sono pausa, ripresa, interruzione e luce della camera.

## Licenza

Distribuito con licenza [MIT](LICENSE).

## Supporto

Se BambuGo ti è utile, puoi offrirmi un caffè su PayPal: https://www.paypal.me/lorenzogarbi ☕
(anche dal pulsante ☕ in fondo al pannello dell'app).
