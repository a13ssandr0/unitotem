# Stato del progetto — redesign OTA UniTotem (2026-08-04)

Documento di **solo stato attuale**: cosa è implementato, cosa è verificato e dove, cosa manca.
`PLAN.md` resta l'archivio storico con tutte le decisioni di design e il perché di ogni scelta.

## Cos'è

Deploy OTA a due stage per i kiosk UniTotem (Raspberry Pi arm64 + amd64): un fallback minimale residente
si installa per primo e diventa il default di boot, poi l'immagine vera arriva per partizione via
partclone+netcat, con DATA preservata. Codice: `deploy/ota-engine.sh` (motore condiviso fallback +
initramfs del sistema reale), `deploy/remote-deploy.sh` (orchestrazione host via SSH),
`kiosk/stage1-recovery-initrd.sh` (build del fallback), `work/loopback-test/` (regressione).

## Verificato su hardware reale (Pi 4 Model B Rev 1.5)

Un deploy **da zero**, partendo da una Raspberry Pi OS Lite vergine, eseguito end-to-end. Tutto quanto
segue è stato confermato sul sistema realmente avviato, non dedotto:

- **Deploy su target non-UniTotem** (percorso di arming "legacy", mai esercitato prima): armamento,
  riavvio nel fallback, ricostruzione tabella, restore, trial boot, promozione. Funziona.
- **Tryboot vero, a livello firmware.** Capability rilevata dal device-tree
  (`/proc/device-tree/chosen/bootloader/`), senza bisogno di `vcgencmd` né del pacchetto `rpi-eeprom`.
  Il trial boot è passato per `tryboot.txt` e `promote-default` ha ripulito i residui.
  Su board senza EEPROM bootloader (Pi 3 / Zero 2) resta automaticamente `rpi-legacy`.
- **LED PWR/ACT alternati** durante la sessione OTA, campionati dal vivo nel fallback: `delay_on`/
  `delay_off` 500/500 su entrambi e alternanza pulita (uno acceso mentre l'altro è spento).
- **Overlay DATA su `/etc` e `/root`: funzionante.** `/proc/mounts` mostra entrambi gli overlay `rw` con
  root montata `ro`; scrivendo in `/etc` il file compare in `/mnt/data/upper/etc/`. L'upperdir contiene
  già stato reale (`machine-id`, `resolv.conf`, `ssh`, `X11`).
- **Host key SSH persistita su DATA**, servizio attivo.
- **KMS attivo**: `card0`/`card1` con due uscite HDMI.
- **Adozione completa di un dispositivo estraneo, da utente non-root.** Partendo da una Raspberry Pi OS
  Lite (Debian 13) con root SSH rifiutato e `sudo` con password, il deploy è andato a fondo come utente
  `pi`: probe, `scp_root` verso `/boot/firmware`, `arm_rpi`, riavvio, sequenza OTA, trial boot, promozione.
  È il percorso che non era mai stato esercitato.
- **Flash di Raspberry Pi OS attraverso il fallback OTA.** Il fallback gira in RAM e ha `dd`/`unxz`, quindi
  può riscrivere l'intero disco via rete (~3 GB, 20 MB/s). Usato per rimettere il Pi in stato "vergine" e
  poterlo poi adottare. L'immagine va preconfigurata prima (`ssh`, `userconf.txt`, `enable_uart=1`).
- **Canale di soccorso via IPv6 link-local.** Un profilo NetworkManager di ultima istanza garantisce che un
  link cablato abbia sempre una connessione attiva, e quindi sempre un `fe80::…` raggiungibile via SSH anche
  con IPv4 rotto. Verificato con il firewall IPv6 attivo. L'indirizzo risulta derivato in EUI-64 dal MAC
  (`d8:3a:dd:45:f9:37` → `fe80::da3a:ddff:fe45:f937`), quindi **calcolabile in anticipo**: dà la capacità
  "raggiungi il dispositivo conoscendone il MAC" senza aggiungere un demone di gestione non cifrato.
- **Firewall IPv6**: prima assente del tutto — IPv4 in `DROP` e IPv6 completamente aperto. Ora rispecchia le
  regole IPv4, con ICMPv6 accettato perché senza Neighbour Discovery IPv6 non funziona affatto.
- **Display senza bande**: `disable_fw_kms_setup=1` + `disable_overscan=1`, entrambi presenti in Raspberry Pi
  OS e assenti da noi. Misurato prima/dopo: da 48/46/48/56 pixel a zero.
- **Console seriale**: `console=ttyS0` (con i DTB Raspberry la UART del connettore è `ttyS0`, non `ttyS1`).
  Ogni boot UniTotem era muto sulla seriale, il che ha tolto diagnostica proprio durante un guasto.
- **Diagnostica media**: `vcgencmd` (`throttled=0x0`) e `gst-inspect-1.0` ora presenti.

## Due bug reali trovati in questa sessione

1. **`ssh` divorava il manifest** (il più grave). `ota_ssh` non passava `-n`, quindi dentro
   `while read_kv_block ... done < parts.manifest` il primo `restore-part` si mangiava il resto del file:
   il blocco DATA non veniva mai letto, `data-op` non girava, e DATA restava **con il nome GPT ma senza
   filesystem**. Da lì a cascata: `blkid -L DATA` non trovava nulla → overlay saltato → `/etc` read-only →
   `unitotem-ssh-hostkey` fallito. Invisibile su target già installati, dove DATA aveva già un filesystem.
   Corretto due volte: `ssh -n` **e** manifest spostato su fd 9, così nessun comando aggiunto in futuro a
   quel loop può riarmare la trappola.
2. **`enable_uart=1` mancante in `arm_rpi`**, l'unico writer di `config.txt` che non lo metteva: il
   fallback sarebbe partito con la seriale muta, proprio nel punto in cui è l'unica diagnostica disponibile.

**Nota sul "bug overlay" storico**: non era un problema di propagazione dei mount attraverso `switch_root`,
come documentato per settimane. Era il bug #1 — su un'installazione da zero non è mai esistito un
filesystem DATA da cui fare overlay. Il commento fuorviante è stato sostituito da un marker auto-verificante
(`/mnt/data/.unitotem-overlay-status`).

## Non fatto / limiti noti

| Gap | Note |
|---|---|
| **amd64 fermo al 30 luglio** | Nessun rebuild da allora. I fix sono nel sorgente condiviso ma mai verificati su immagine/deploy amd64. È il gap più grosso rimasto. |
| `unitotem-ota-arm` falso negativo | Il reboot chiude la sessione SSH prima che l'exit 0 sia letto, quindi `remote-deploy.sh deploy` riporta un fallimento benché l'arming sia riuscito. Aggirato a mano ogni volta; andrebbe reso robusto. |
| Build nativa sul Pi | Implementata, mai eseguita per una build reale completa. |
| `inside-real-sd.sh` | Harness su SD fisica, non ha lo scenario "Round 2". Obsoleto da quando l'OTA via rete funziona. |
| Flash di OS estranei: solo via `dd`, non via parts set | `parts-lib.sh` classifica le partizioni per label (`FIRMWARE`/`ROOT`/`DATA`) e i passi di boot scrivono `config.txt` in formato UniTotem, con la promozione affidata a `unitotem-boot-ok`. Per un'immagine estranea si usa il fallback + `dd` dell'immagine intera. |
| **Un nuovo sottocomando del motore è utilizzabile solo un OTA dopo** | Il fallback che esegue un OTA è quello installato in precedenza, caricato in RAM all'avvio; lo Stage 1 riscrive la copia su disco, che entra in gioco al giro successivo. Osservato dal vivo: `apply-network`, aggiunto oggi, ha risposto `Sottocomando sconosciuto` durante il deploy odierno (fallimento non fatale, deploy completato). Conseguenza pratica: `apply-network` è verificato solo in loopback, non ancora su hardware. |
| Round 2 del loopback maschera i bug di stdin | Sostituisce `ota_ssh` con un `eval` che non tocca stdin. Ora coperto da due guard espliciti, ma resta una limitazione strutturale del mock. |

## Da fare subito

- **Riattivare il watchdog di rete** sul Pi di prova: `ENABLED=0` in `/etc/unitotem/net-watchdog.conf` è
  stato messo a mano per non farlo scattare durante le verifiche, non è il default dell'immagine.
- **Stato e progresso dell'OTA a schermo via whiptail.** Oggi non si vede nulla, per due cause distinte:
  `cmd_serve_fallback` scrive l'interfaccia su `/dev/console`, che con `console=tty1 console=ttyS0` è la
  **seriale** e non lo schermo (va usato `/dev/tty1` esplicito), e `--infobox` ritorna subito senza
  persistere. Le funzioni `gauge_start`/`gauge_feed`/`gauge_stop` previste in PLAN.md §9 non sono mai state
  scritte. Approccio: ogni sottocomando pubblica fase e percentuale su un file in `/run`, e `serve-fallback`
  tiene un ciclo che ridisegna un `whiptail --gauge`; la percentuale da `pv -n`, già nel payload.

## Prossimi passi consigliati

1. **Rebuild e verifica amd64** — allineare l'architettura rimasta indietro.
2. Rendere robusto `unitotem-ota-arm` (o il suo chiamante) rispetto alla chiusura della sessione SSH.
3. Estendere `inside-real-sd.sh` con lo scenario "Round 2", quando serve di nuovo l'harness su SD fisica.

Nota di metodo emersa più volte oggi: `should_run()` in `build-kiosk.sh` confronta i timestamp a livello di
**directory** (`kiosk/files/*`), quindi un file modificato *durante* una build risulta più vecchio
dell'artefatto che avrebbe dovuto invalidare, e la build successiva lo salta silenziosamente. È costato tre
cicli sprecati. Rimedio immediato: `FORCE_STAGE=2`. Rimedio strutturale da valutare: confrontare gli hash
dei file invece dei timestamp.
