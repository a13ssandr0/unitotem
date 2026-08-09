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

## Verifica del 5 agosto (sera): apt coerente e OTA che avvisa prima di distruggere

L'OTA sostituisce ROOT per intero, quindi qualunque cosa installata o modificata sul dispositivo veniva
distrutta **in silenzio**: un aggiornamento e la perdita del lavoro altrui erano indistinguibili.

- **`unitotem-ota-changes`** (nuovo, `/usr/sbin/`) dice cosa è cambiato rispetto all'immagine e lo
  classifica: `clean`, `packages-only`, `mixed`. I file che appartengono a un pacchetto appena installato
  o aggiornato sono **attribuiti** a quell'operazione, non elencati come modifiche a sé — altrimenti un
  `apt install` di routine sarebbe indistinguibile da un binario modificato a mano.
- La **baseline** è generata a build time da *lo stesso script* che poi confronta. Due implementazioni di
  "quali file contano" divergerebbero, e la divergenza apparirebbe come modifiche fantasma su ogni
  dispositivo. Riscontro: la baseline arm64 conta 3.043 file non posseduti, la scansione sul dispositivo
  ne trovava 3.042 — e su un'installazione fresca il verdetto è `clean`.
- **`--accept-changes <digest>`**: conferma non interattiva che procede solo se l'insieme delle modifiche
  è ancora quello mostrato. È ciò che rende una conferma da interfaccia web sicura quanto un prompt.
- **`API-OTA.md`**: contratto per il frontend nell'altro progetto.
- **Database dpkg riportato su ROOT** (`initramfs-dpkg-pinned-to-root=yes`), timer `apt-daily*`
  mascherati, `kiosk-update` che ferma i servizi veri.

### Prove di quanto l'incoerenza fosse reale

Non era teorica: sul Pi il database dpkg su DATA aveva registrato `libpam0g` in stato **half-installed**,
uno stato che i file su ROOT read-only non potevano completare. Ha fatto **fallire la build nativa**. È
sparita da sé col deploy, che sostituisce ROOT e azzera l'upper di `/var`.

### Difetti trovati solo su hardware

1. **Un bind mount ha flag propri**: `kiosk-update enter` rimontava `/` in rw e `/var/lib/dpkg` restava
   `ro` nello stesso istante. apt non poteva prendere i lock, dpkg non poteva scrivere: installare un
   pacchetto era impossibile.
2. **Liste dei pacchetti azzerate** dall'OTA (stanno sull'overlay), quindi ogni `install` falliva con
   "Unable to locate package" su un dispositivo appena installato.
3. **1m31s invece dei ~15s stimati**: lo sha256 forkava un processo per file (3.043). Ora 11s. La stima
   che avevo scritto nel piano era sbagliata per il codice come l'avevo scritto.

Verificato end-to-end su Pi 4: `clean` da fresco → `packages-only` dopo `apt install sl` → `mixed` dopo
modifiche a file (incluso uno con spazi nel nome, che una versione precedente troncava) → digest stale
rifiutato → digest corretto accettato → modifiche effettivamente distrutte dal deploy, come annunciato.
Loopback: **arm64 136/136**, **amd64 74/74**.

## Verifica del 6 agosto: driver video amd64 per tutti e tre i fornitori

L'immagine amd64 non aveva **alcun** driver NVIDIA e nulla di abbastanza recente per le Intel ARC. Ora
porta Intel, AMD e NVIDIA insieme: è `libglvnd` a smistare GL verso il fornitore effettivamente presente,
ed è questo che permette a una sola immagine di funzionare su tutti e tre senza scegliere a build time.

**Le ARC sono la ragione per cui la base amd64 passa ai backports.** Sul kernel 6.1 di bookworm le DG2
stanno dietro `i915.force_probe` e Mesa 22.3 le regge a malapena: dichiararle supportate sarebbe stato vero
solo sulla carta. I backports portano kernel **6.12.95**, Mesa **25.0.7** e firmware **2025-04**, che
giovano anche a RDNA3 e alle Intel integrate recenti. Aggiungere la suite non cambia nulla di per sé
(backports è `NotAutomatic`): ogni pacchetto che ne proviene è richiesto per nome con `-t`.

NVIDIA è il driver proprietario, con due conseguenze dichiarate nel codice invece che scoperte dopo:
mette una blacklist su nouveau e il ramo 535 parte da Maxwell, quindi **una scheda pre-Maxwell resta senza
driver**; e il modulo è costruito da DKMS a build time. Quel secondo punto di solito è il punto debole di
DKMS, ma qui non può mordere: nulla viene aggiornato sul posto, un OTA sostituisce la partizione con
un'immagine il cui kernel e modulo sono stati costruiti insieme.

- La build **fallisce** se il modulo NVIDIA non viene costruito: apt segnala i fallimenti DKMS come
  semplici avvisi, e senza questa guardia ne uscirebbe un'immagine apparentemente sana e priva di NVIDIA.
- Gli headers del kernel sono **volutamente conservati** (94 MiB, misurati, e il modulo sopravvive al loro
  purge): servono a DKMS se qualcuno aggiorna il kernel in place con `kiosk-update`, che è un percorso che
  l'immagine ora supporta esplicitamente.
- Costo: immagine amd64 da **774 a 1057 MiB** compressi. Su un OTA quella differenza viaggia in rete a
  ogni deploy.
- Loopback amd64 **92/92**, con nove controlli dedicati: kernel 6.12+, Mesa 25.x, modulo NVIDIA, driver X
  NVIDIA e amdgpu, VAAPI su NVDEC, iHD per ARC, radeonsi per AMD, firmware 2025.

**Nulla di tutto questo tocca arm64**: backports e driver stanno interamente dentro rami `amd64`. Anzi,
arm64 è stata ripulita in senso opposto — non installa più `libva2`/`libva-drm2`/`vainfo` né
`gstreamer1.0-vaapi`. Erano lì da sempre, con un commento che ne ammetteva l'inutilità («inerti, tenuti
perché il ramo amd64 condivide i consumatori»), che non è una ragione per spedirli: VideoCore non ha
alcun driver VAAPI e la decodifica passa dai dispositivi V4L2 mem2mem. `gstreamer1.0-vaapi` in particolare
andava spostato nel ramo amd64, altrimenti avrebbe ritrascinato `libva` per dipendenza vanificando la
rimozione. Su arm64 restano solo strumenti di diagnosi — `v4l-utils`, `gstreamer1.0-tools`, `raspi-utils` —
che non sono driver.

## Verifica del 7 agosto: codec, accelerazione del browser, e una cache che mentiva

**Il motore di riproduzione è Chromium, non GStreamer.** Il manager ha `PyChromeDevTools` e nessun CEF:
pilota il browser via DevTools protocol, e `qt6-multimedia` non è nemmeno installato. Quindi codec e
accelerazione che decidono la resa sono quelli di Chromium — lo stack GStreamer dell'immagine conta molto
meno di quanto la lista dei pacchetti suggerisca.

**Codec, misurati interrogando il browser** (`MediaSource.isTypeSupported`), non dedotti: H.264, AAC, MP3,
VP9, AV1, Opus tutti supportati. **HEVC no.**

**L'accelerazione video non era attiva.** Chromium su Linux la tiene spenta di default; l'immagine aveva
solo `--enable-gpu-rasterization` (default Debian), che copre il compositing e non il video. Un H.264 1080p
veniva decodificato in CPU su una scheda con un decoder hardware fermo. Ora `/etc/chromium.d/50-unitotem-accel`
(il wrapper Debian legge quella directory, quindi il manager non va toccato) aggiunge
`AcceleratedVideoDecodeLinuxGL` + variante zero-copy, più `VaapiVideoDecoder` **solo su amd64** — sul Pi non
c'è driver VAAPI dietro e chiederlo rischierebbe di far rinunciare Chromium invece di ripiegare su V4L2.

I nomi delle feature sono stati **letti dal binario**: cambiano tra versioni e uno sbagliato viene ignorato
in silenzio, il che è indistinguibile dall'accelerazione non disponibile. stage2 fa fallire la build se il
segnaposto non viene sostituito.

### Il bug più grave di questa fase: la cache di build restituiva immagini sbagliate

La prima pulizia VAAPI **non è mai entrata nell'immagine**, ed era già stata deployata sul Pi. `should_run`
confrontava ogni stage solo con i propri sorgenti, **mai col tarball dello stage precedente**: stage1 si
ricostruiva con la modifica, stage2 si saltava, stage3 assemblava da un tarball del giorno prima. L'unico
indizio era il conteggio pacchetti identico. Corretto; dopo il fix il conteggio è sceso da 915 a 912, cioè
i tre pacchetti effettivamente rimossi.

È la quarta volta che la cache produce un'immagine plausibile e sbagliata, ma le prime tre erano granularità
dei timestamp: questa era un **arco mancante nel grafo delle dipendenze**.

### Altri due difetti trovati e chiusi

- Il remount del bind `/var/lib/dpkg` mancava in `build-kiosk.sh` (avevo corretto solo `kiosk-update`):
  rompeva la build nativa con un errore di lock di apt.
- Una build interrotta lascia i bind di chroot dentro il rootfs, e il successivo `rm -rf` fallisce con
  "Directory not empty" — messaggio che non nomina i mount. Il percorso nativo ora li smonta prima di
  partire.

Il ripiego automatico su qemu ha assorbito in silenzio **quattro** guasti diversi della build nativa: continua
a produrre immagini valide, e nel farlo nasconde perché la strada veloce non parte mai.

## Verifica dell'8 agosto: amd64 su Debian 13 (trixie)

L'immagine amd64 era su **oldstable**, e l'impalcatura `bookworm-backports` costruita il giorno prima
esisteva solo per compensarlo. Su trixie quegli stessi pacchetti arrivano da stable, alla stessa versione
o più recenti, quindi l'impalcatura è stata rimossa invece che trascinata avanti.

| | bookworm + backports | trixie (ora) |
|---|---|---|
| kernel | 6.12.95 | **6.12.101** |
| Mesa | 25.0.7 | 25.0.7 |
| NVIDIA | 535.261 | **550.163** |
| Intel media (ARC) | 23.1.1 | **25.2.3** |

DKMS di NVIDIA 550.163.01 compilato contro il 6.12.101 di trixie, `unitotem-manager 2.3.0` installato
senza errori. Loopback **98/98**, con controlli espliciti che il codename dell'immagine e le sue
`sources.list` coincidano e che non sopravviva alcuna lista backports. Immagine da 1057 a **1072 MiB**.

**arm64 resta di proposito su bookworm.** Ci guadagnerebbe poco: l'archivio Raspberry Pi spedisce già un
kernel 6.12 lì, quindi il problema che ha forzato la mano ad amd64 non si pone. E il rischio aperto del
salto è l'ambiente Python del manager, oggi 3.11, che su trixie incontrerebbe 3.13: tenere il Pi dov'è
lascia un dispositivo di riferimento funzionante mentre quel punto si chiarisce nel progetto del manager.

La suite ora viene da `$RELEASE` ovunque, anche nelle `sources.list` che finiscono dentro l'immagine. Con
due architetture su due release, una suite cablata avrebbe fatto il bootstrap di una base puntando apt
all'altra — disallineamento che salta fuori molto dopo, come dipendenze irrisolvibili o come apt che
propone un mezzo aggiornamento al primo `kiosk-update enter`.

Nota di percorso: la prima build si è incastrata dentro `debootstrap` (log fermo 15 minuti, shell in
`wait4` senza figli). Un `debootstrap trixie` pulito nello stesso container riusciva, quindi era uno stallo
di rete transitorio: ripetuta, è andata.

## Verifica del 9 agosto: arm64 su Debian 13 (trixie), avviato per davvero

`amd64` era passata a trixie il giorno prima; arm64 era rimasta di proposito su bookworm perché sembrava
bloccata dalla chiave dell'archivio Raspberry Pi. Non lo era: era l'URL legacy `raspberrypi.gpg.key` a
essere non aggiornato (auto-firma SHA1, rifiutata da trixie dal 2026-02-01). Il pacchetto
`raspberrypi-archive-keyring` — quello che usa pi-gen stesso, vendorizzato in questo repo — ha una versione
per trixie (`2025.1+rpt1`) con la stessa chiave rifirmata SHA512. Confermato scaricandola e ispezionandola,
non assunto. Vedi la memoria `verify-upstream-repos-first`, scritta proprio per questo episodio.

Quattro bug distinti, ognuno trovato solo perché la build è stata portata fino in fondo invece di fermarsi
al primo errore plausibile:

1. **SIGPIPE sotto `pipefail`.** Il fetch del keyring usava `awk '...{print; exit}'` dentro una pipe con
   `curl | gzip -dc`: l'uscita anticipata di awk manda SIGPIPE a monte, `pipefail` lo trasforma in fallimento
   di pipeline, `set -e` interrompe lo script **senza alcun messaggio** — il valore era già stato catturato
   correttamente. Riprodotto isolatamente (`seq 1 200000 | awk '/^100$/{print;exit}'` sotto `set -e
   pipefail` esce 141 senza output) prima di toccare il codice.
2. **`raspberrypi-bootloader` non esiste più su trixie**, non rinominato, nessun pacchetto di transizione.
   Verificato leggendo il vero `postinst` di `raspi-firmware`: da trixie contiene lui stesso
   `bootcode.bin`/`start*.elf`/`fixup*.dat` e li copia in `/boot/firmware/` — la riga `if ischroot; then
   true # skip mount point check` conferma che lo fa anche dentro il nostro chroot di build.
3. **L'initramfs non è uno stream compresso solo**: `mkinitramfs` concatena segmenti — un cpio grezzo
   iniziale (hook di `raspi-firmware`, nuovo su trixie) seguito dal corpo compresso vero. Il controllo di
   build-ability leggeva solo i primi byte, quindi vedeva sempre e solo il formato del segmento piccolo. Tre
   tentativi prima di quello giusto: prima ho esteso il rilevamento a più formati per magic (ancora
   sbagliato, stesso errore concettuale), poi sono passato a `unmkinitramfs` (lo strumento reale che il
   kernel stesso userebbe), verificandolo però contro una riproduzione minimale che appiattiva tutto — e
   quella riproduzione mentiva: il file vero (pacchetti completi: X11, Chromium, pipewire) produce
   `early/`+`main/` con `/init` dentro `main/`. Scoperto tirando giù il file vero rimasto sul Pi dopo il
   fallimento ed estraendolo lì, non ricostruendo un'approssimazione.
4. **`build-kiosk.sh` non rimontava il bind di `/var/lib/dpkg`** per il percorso nativo — stessa asimmetria
   già corretta in `kiosk-update`, mancata la prima volta perché è un secondo chiamante.

**Risultato**: build nativa sul Pi, tutti e quattro gli stage senza ripiego su qemu. Loopback **136/136**.
Deploy sul Pi riuscito, e il dispositivo è **tornato su con Debian 13, kernel 6.18.39, `running`, 0 unit
fallite** — la prova che conta di più, perché il controllo di build-ability da solo dimostra che
l'immagine è coerente, non che il kernel reale sa avviarla.

`unitotem-manager` va ancora in crash-loop, ma **non per Python 3.13**: il traceback reale (catturato
eseguendo il manager in foreground, perché journald non cattura il suo stdout/stderr) è
`OSError: [Errno 30] Read-only file system: '/usr/share/unitotem-manager/static/uploaded'` — tenta un
`makedirs` sotto ROOT, fuori da qualunque overlay (`/etc`, `/root`, `/var` sono scrivibili, `/usr` no). Bug
dell'altro progetto, preesistente, non causato né risolto da questo lavoro; ora però con la causa esatta
invece di un sintomo generico.

## Non fatto / limiti noti

| Gap | Note |
|---|---|
| **Due fix sono in sorgente ma non nell'immagine sul Pi** | Il remount del bind dpkg in `kiosk-update` e lo sha256 batch. Verificati su hardware copiando gli script a mano; entrano in un'immagine solo alla prossima build. Stessa proprietà di ritardo di un giro di sempre. |
| `iso/installer.sh` è disallineato dal repo | Indipendente da questo lavoro: installa `chromium-flags-amd64`, che non esiste più in `kiosk/files/`. Con `set -euo pipefail` l'installer si fermerebbe lì. Non è nella pipeline di `build-kiosk.sh`, quindi non blocca nulla oggi. |
| `unitotem-manager.service` in crash-loop sul Pi | Causa nota con precisione ora: `OSError` scrivendo sotto `/usr/share/...`, ROOT read-only e non overlaid. Bug del progetto manager, non di questo repo. |
| **Immagine amd64 trixie mai avviata** | Costruita e verificata in loopback (98/98), ma nessun avvio reale: non ho hardware amd64 su cui provarla. arm64 su trixie invece **è** stata avviata (9 agosto), quindi il gap è ormai specifico ad amd64. |
| **HEVC non riproducibile** | Chromium non ha `PlatformHEVCDecoderSupport` compilata e GStreamer non espone `v4l2slh265dec`: il decoder HEVC del Pi 4 (`/dev/video19`) resta irraggiungibile da entrambe le strade. Servirebbe una build diversa di Chromium. |
| **Accelerazione: cablaggio verificato, resa no** | I flag sono assemblati correttamente dal wrapper, ma non ho riprodotto un video misurando l'uso della CPU. Manca la prova che il decoder hardware venga davvero ingaggiato. |
| `avdemux_asf` assente | I decoder WMV/VC-1 ci sono via libav, ma il contenitore ASF non si apre. Irrilevante finché la riproduzione passa da Chromium. |
| **Driver video amd64 verificati solo in loopback** | Nessuna prova su hardware reale con GPU NVIDIA, AMD o ARC: la verifica dice che i pezzi sono nell'immagine, non che guidano lo schermo. |
| Schede NVIDIA pre-Maxwell senza driver | Conseguenza accettata del proprietario, che blacklista nouveau. Servirebbe una variante d'immagine o una blacklist condizionata. |
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
