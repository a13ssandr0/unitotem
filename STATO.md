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

## Verifica del 4 agosto (sera): interfaccia a schermo, amd64, fault injection

- **Interfaccia OTA a schermo: funzionante, fotografata durante un OTA reale.** `whiptail --gauge` resta su
  per l'intera sessione (~3 minuti continuativi nella cattura), con motivo, indirizzo, porta, fase e
  percentuale presa da `pv`. Prima non compariva nulla.
- **amd64 riallineato**: immagine ricostruita il 4 agosto (era ferma al 30 luglio), parts set rigenerato,
  loopback §11.1 **44/44**.
- **arm64**: rebuild, parts set, loopback §11.1 **100/100**.
- **Fault injection §11.5 livello 4**: nuovo harness `work/loopback-test/{run,inside}-bootcount.sh`, **10/10**.
  Copre `cmd_init_premount`, che nessun test raggiungeva: tre avvii non confermati cadono nel fallback, un
  trial con contatore alto si avvia comunque e riparte da 1, `/boot-ota` non resta montato, ROOT assente
  innesca il fallback.
- **Due deploy consecutivi su hardware**, entrambi completati: `UNITOTEM_ETC_MIGRATED=1` (il bug `date` è
  chiuso) e `UNITOTEM_NET_APPLIED=1` al primo giro, `skip-esistente` al secondo — il percorso di scrittura
  del profilo di rete è quindi verificato su hardware **e** idempotente.
- **Copertura complementare di `pv`** senza costruirla apposta: il container di test arm64 ha `pv`, quello
  amd64 no, quindi i due loopback esercitano entrambi i rami del restore.

### Tre bug trovati e chiusi in questa fase

1. **La prima versione dell'interfaccia sollevava un errore vero** dentro `serve-fallback` su hardware
   (`ERRORE: errore inatteso alla riga 949`, fino all'ERR trap e al gestore di rollback). Il commento che la
   dichiarava best-effort non aveva nulla che lo rendesse vero; ora è chiamata in contesto `||`, che
   sopprime `errexit` e l'ERR trap per tutto il corpo della funzione.
2. **Il falso negativo di `unitotem-ota-arm` era bloccante**, non cosmetico: `die` interrompeva il deploy a
   ogni giro benché l'arming fosse riuscito. Corretto ai due estremi — il chiamante non usa più l'exit
   status di ssh come verdetto (lo è `wait_ota_reachable`), e lo script sul target ritarda il reboot dentro
   la sessione staccata.
3. **La build nativa sul Pi non era mai partita**: `debootstrap` rifiuta `/tmp` perché montato `nodev` (e
   sono 256 MB). `ROOTFS` era cablato; ora è sovrascrivibile e punta su DATA. Stage0 nativo verificato
   `RC=0`. Il ripiego automatico su Docker+qemu funzionava, e per questo il problema era invisibile.

## Verifica del 5 agosto: `/var` in overlay, build nativa, terza immagine

Il root read-only stava **mangiando scritture in silenzio**. `/etc` e `/root` erano in overlay, `/var` no: la
sua scrivibilità era affidata a un elenco di tmpfs in `fstab` compilato a mano, che per costruzione poteva
coprire solo le directory già viste fallire. Non copriva `/var/log/journal`, quindi journald ripiegava su
`/run` e **ogni riavvio buttava via tutti i log** — proprio la diagnostica che serve dopo un guasto in campo,
e `journald.conf` chiedeva `Storage=persistent` da sempre. Stessa causa, danno minore: `logrotate`,
`dpkg-db-backup` e 11 record `wtmp` persi per avvio.

`/var` è ora in overlay accanto a `etc` e `root`. L'obiezione in `fstab` contro un tmpfs su tutto `/var/lib`
resta valida ed è conservata — nasconderebbe il database dpkg e i 78 MB di `/var/unitotem-venv` — ma è
un'obiezione al **tmpfs**, non alla scrivibilità: un overlay lascia visibile il livello inferiore e devia solo
le scritture. `/var/cache` e `/var/tmp` restano tmpfs di proposito (puro ricambio, nessun motivo di consumare
la SD).

Verificato su hardware dopo il deploy:

| Prima | Dopo |
|---|---|
| `degraded`, 2 unit fallite | **`running`, 0 fallite** |
| journal in `/run` (volatile) | journal in `/var/log/journal`, **boot precedente leggibile dopo il riavvio** |
| `wtmp` non scrivibile | scrivibile |
| — | dpkg integro (915 pacchetti), venv visibile, upper `/var` = 11 MB su DATA |

`migrate-etc-overlay` azzera ora anche l'upper di `/var`: senza, dopo un OTA il database dpkg e il venv della
**vecchia** immagine coprirebbero quelli nuovi. Il vecchio contenuto finisce in `history/`, non è perso.

- **Build nativa sul Pi: completata end-to-end per la prima volta.** Restava un secondo bloccante dopo
  `ROOTFS`: stage3 montava l'immagine in costruzione su `/mnt`, che sull'appliance è dove sta DATA — si
  copriva da solo l'albero di build, e `rsync` falliva su un rootfs perfettamente presente. `IMG_MNT` è ora
  sovrascrivibile come `ROOTFS`.
- Loopback: **arm64 120/120**, **amd64 58/58** (erano 100 e 44; la differenza sono i controlli nuovi).
- `migrate-etc-overlay` veniva invocata **senza alcuna asserzione**: poteva non fare nulla e restare verde.
  Ora è verificata su entrambe le architetture.

## Non fatto / limiti noti

| Gap | Note |
|---|---|
| `MaxLevelStore=warning` limita cosa viene salvato | Ora che i log persistono, vale la pena rivedere la soglia: `info`/`notice` non finiscono su disco, quindi parte della cronologia di un guasto manca comunque. Scelta deliberata per l'usura della SD, ma da ripesare con l'overlay attivo. |
| L'immagine amd64 non è mai stata avviata | Ricostruita e verificata in loopback (58/58), ma nessun avvio reale: l'overlay `/var` è dimostrato solo su arm64. |
| `inside-real-sd.sh` | Harness su SD fisica, non ha lo scenario "Round 2". Obsoleto da quando l'OTA via rete funziona. |
| Flash di OS estranei: solo via `dd`, non via parts set | `parts-lib.sh` classifica le partizioni per label (`FIRMWARE`/`ROOT`/`DATA`) e i passi di boot scrivono `config.txt` in formato UniTotem, con la promozione affidata a `unitotem-boot-ok`. Per un'immagine estranea si usa il fallback + `dd` dell'immagine intera. |
| **Un nuovo sottocomando del motore è utilizzabile solo un OTA dopo** | Il fallback che esegue un OTA è quello installato in precedenza, caricato in RAM all'avvio; lo Stage 1 riscrive la copia su disco, che entra in gioco al giro successivo. È la ragione per cui ogni verifica a schermo richiede **due** deploy, e per cui i tre fix qui sopra non sono ancora in un'immagine. |
| Round 2 del loopback maschera i bug di stdin | Sostituisce `ota_ssh` con un `eval` che non tocca stdin. Ora coperto da due guard espliciti, ma resta una limitazione strutturale del mock. |

## Prossimi passi consigliati

1. **Una build che incorpori i tre fix** e un deploy di conferma — chiude sia il gauge completo sia
   l'arming pulito sul target.
2. Completare la build nativa sul Pi end-to-end, ora che stage0 passa.
3. Estendere `inside-real-sd.sh` con lo scenario "Round 2", quando serve di nuovo l'harness su SD fisica.

Nota di metodo emersa più volte oggi: `should_run()` in `build-kiosk.sh` confronta i timestamp a livello di
**directory** (`kiosk/files/*`), quindi un file modificato *durante* una build risulta più vecchio
dell'artefatto che avrebbe dovuto invalidare, e la build successiva lo salta silenziosamente. È costato tre
cicli sprecati. Rimedio immediato: `FORCE_STAGE=2`. Rimedio strutturale da valutare: confrontare gli hash
dei file invece dei timestamp.
