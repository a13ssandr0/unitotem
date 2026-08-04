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
- **Deploy su target non-root**, con `sudo` e root SSH disabilitato (il caso realistico di
  adozione di un dispositivo esistente): probe, comandi composti privilegiati, copia file su
  percorsi solo-root, pulizia dell'helper. Verificato nel caso ostile — sudo *con* password.

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
| Round 2 del loopback maschera i bug di stdin | Sostituisce `ota_ssh` con un `eval` che non tocca stdin. Ora coperto da due guard espliciti, ma resta una limitazione strutturale del mock. |

## Prossimi passi consigliati

1. **Rebuild e verifica amd64** — allineare l'architettura rimasta indietro.
2. Rendere robusto `unitotem-ota-arm` (o il suo chiamante) rispetto alla chiusura della sessione SSH.
3. Il percorso di arming "legacy" (`push_recovery_kernel` + `arm_rpi`, per target non-UniTotem) non è
   ancora stato esercitato *da utente non-root*: il target è UniTotem da quando sudo è stato implementato,
   quindi passa per `unitotem-ota-arm`. `scp_root` è stato verificato in isolamento su percorso solo-root.
