<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Icona di BambuGo"></p>

# BambuGo

[![Offrimi un caffè](https://img.shields.io/badge/☕_Offrimi_un_caffè-PayPal-0070ba?logo=paypal&logoColor=white)](https://www.paypal.me/lorenzogarbi)

App per la barra dei menu di macOS che mostra lo stato di una stampante Bambu Lab
(X1, P1, A1, H2D…), collegandosi **via cloud Bambu Lab** oppure **direttamente in rete locale**.

Nella barra: icona + `45% · 1h 12m` durante la stampa, `Pausa`, `Finita`, `Errore`;
solo icona quando è ferma. Cliccando si apre un pannello a schede con:

- **avanzamento**: anello con la percentuale, nome del lavoro, strato, tempo rimanente e ora di fine;
- **Pausa / Riprendi / Interrompi** (l'interruzione chiede conferma);
- **telecamera** in diretta, con interruttore della luce e apertura in una finestra sempre in primo piano;
- **temperature** di ugello, piatto e camera con l'obiettivo di riscaldamento;
- **bobine dell'AMS**: colore, materiale, residuo, slot in uso, umidità e temperatura;
- **errori e avvisi** della stampante e dell'AMS (codici HMS), con link alla spiegazione sul wiki Bambu Lab;
- qualità del Wi-Fi e velocità di stampa.

Notifiche a fine stampa, errore e pausa (es. filamento finito).

In più: **browser di modelli pronti** su MakerWorld, Printables e Thingiverse.

> BambuGo è un progetto indipendente e non è affiliato, approvato o sponsorizzato da Bambu Lab.
> "Bambu Lab" e i nomi delle stampanti sono marchi dei rispettivi proprietari.
> L'app usa interfacce non ufficiali. Gli unici comandi che invia sono pausa, ripresa,
> interruzione (con conferma) e luce della camera: con i firmware più recenti la stampante
> potrebbe rifiutarli se non è in modalità LAN + sviluppatore.

## Requisiti

- macOS 13 Ventura o successivo
- Command Line Tools di Xcode: `xcode-select --install` (Xcode completo non serve)

## Download

Scarica `BambuGo.zip` dall'ultima [release](https://github.com/ifeldr/BambuGo/releases/latest),
estrai l'app e spostala in *Applicazioni*. L'app non è firmata con un certificato Apple,
quindi al primo avvio macOS la blocca: apri *Impostazioni di Sistema → Privacy e sicurezza*
e premi **Apri comunque**, oppure da Terminale:

```bash
xattr -dr com.apple.quarantine /Applications/BambuGo.app
```

## Compilazione e installazione

```bash
cd BambuGo
chmod +x build.sh
./build.sh
cp -R build/BambuGo.app /Applications/
open /Applications/BambuGo.app
```

## Configurazione

Clicca l'icona nella barra dei menu e scegli la modalità in alto (si cambia quando vuoi dall'ingranaggio).

**Cloud** – funziona ovunque sia il Mac
1. Email e password dell'account Bambu Lab (server "Globale / Europa").
2. Codice a 6 cifre ricevuto via email (o dell'app di autenticazione, se hai la 2FA).
3. Scegli la stampante dall'elenco.

**Rete locale** – nessun passaggio da internet
1. IP della stampante (meglio riservarlo nel DHCP), numero di serie, access code
   (display: Impostazioni → Rete/WLAN).
2. Se hai già fatto il login cloud, "Compila dal cloud" inserisce seriale e access code.
3. Concedi il permesso **Rete locale** quando macOS lo chiede
   (Impostazioni di Sistema → Privacy e sicurezza → Rete locale).

## Compatibilità

| Funzione | P1P / P1S | A1 / A1 mini | X1C / X1E | H2D / H2S |
|---|---|---|---|---|
| Stato, temperature, AMS, errori | ✅ | ✅ | ✅ | ✅ |
| Pausa / Riprendi / Interrompi, luce | ✅ ¹ | ✅ ¹ | ✅ ¹ | ✅ ¹ |
| Telecamera | ✅ ² | ✅ ² | ✅ ² ³ | ✅ ² ³ |

1. Con i firmware più recenti Bambu Lab può bloccare i comandi inviati da app di terze parti:
   in quel caso il pannello lo segnala e serve la modalità LAN + sviluppatore.
2. Il video arriva solo in **rete locale**: il Mac deve raggiungere l'IP della stampante.
   In modalità cloud basta indicare l'IP una volta nella scheda Telecamera (l'access code
   viene preso dall'account).
3. X1 e H2 trasmettono in RTSP: sulla stampante va attivata l'opzione **Liveview in LAN**
   (*LAN Only Liveview*). Supporto nuovo, non ancora provato su queste stampanti: se non
   funziona apri una segnalazione. I video H.265 non sono supportati.

## Modelli online

Il pulsante **Modelli online** del pannello apre una finestra con MakerWorld, Printables
e Thingiverse (il login ai siti resta salvato). I file scaricati finiscono in *Download*
e una barra in basso permette di mostrarli nel Finder.

## Come funziona

| | Cloud | Rete locale |
|---|---|---|
| Server MQTT | `us.mqtt.bambulab.com:8883` | `<IP stampante>:8883` |
| Utente | `u_<id utente>` | `bblp` |
| Password | token di accesso | access code |
| Certificato TLS | verificato | self-signed, accettato |

In entrambi i casi l'app si iscrive a `device/<seriale>/report` e chiede lo stato
completo (`pushall`) alla connessione e quando premi "Aggiorna".
Password dell'account mai salvata; token e access code stanno nel Portachiavi.

## Note

- Il token cloud scade dopo circa 3 mesi: l'app chiede di accedere di nuovo.
- Dopo ogni ricompilazione macOS può chiedere di autorizzare l'accesso al Portachiavi
  (la firma ad-hoc cambia): scegli "Consenti sempre".
- Le API cloud non sono ufficiali e Bambu può cambiarle; l'app evita richieste frequenti.
- In rete locale, P1/A1 accettano poche connessioni MQTT contemporanee.
- Gli unici comandi inviati sono pausa, ripresa, interruzione e luce della camera.

## Supporto

Se BambuGo ti è utile, puoi offrirmi un caffè su PayPal: https://www.paypal.me/lorenzogarbi ☕
(anche dal pulsante ☕ in fondo al pannello dell'app).
