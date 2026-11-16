# BambuGo

[![Offrimi un caffè](https://img.shields.io/badge/☕_Offrimi_un_caffè-PayPal-0070ba?logo=paypal&logoColor=white)](https://www.paypal.me/lorenzogarbi)

App per la barra dei menu di macOS che mostra lo stato di una stampante Bambu Lab
(X1, P1, A1, H2D…), collegandosi **via cloud Bambu Lab** oppure **direttamente in rete locale**.

Nella barra: icona + `45% · 1h 12m` durante la stampa, `Pausa`, `Finita`, `Errore`;
solo icona quando è ferma. Cliccando si apre un pannello con nome del lavoro,
avanzamento, strato, tempo rimanente, ora di fine, temperature di ugello/piatto/camera
e velocità. Notifiche a fine stampa, errore e pausa (es. filamento finito).

In più: **browser di modelli pronti** su MakerWorld, Printables e Thingiverse.

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

Ogni push su `main` compila l'app con GitHub Actions; per pubblicare una nuova release
basta creare un tag `vX.Y.Z` (es. `git tag v1.1.0 && git push --tags`).

## Compilazione e installazione

```bash
cd BambuGo
chmod +x build.sh
./build.sh
cp -R build/BambuGo.app /Applications/
open /Applications/BambuGo.app
```

## Configurazione

Clicca l'icona a cubo e scegli la modalità in alto (si cambia quando vuoi dall'ingranaggio).

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
- L'app legge solo lo stato della stampante, non invia comandi di stampa.

## Supporto

Se BambuGo ti è utile, puoi offrirmi un caffè su PayPal: https://www.paypal.me/lorenzogarbi ☕
(anche dal pulsante ☕ in fondo al pannello dell'app).
