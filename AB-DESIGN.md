# Design: immagine Debian immutabile con aggiornamento A/B

**Stato (2026-10-10): amd64/GRUB implementato e provato in QEMU/UEFI, arm64 non implementato.** Vedi
"Stato dell'implementazione" in fondo. Il resto di questo documento è la proposta di partenza, dedotta dal codice
attuale (`PLAN.md`, `STATO.md`, `deploy/ota-engine.sh`, `unitotem/files/*`) e da documentazione nota dei
firmware; le voci che dipendono da un comportamento non provato sono marcate **[da verificare]**.

## Obiettivo (dall'utente)

- Restare su Debian. Niente `apt` a runtime; `dpkg` resta (verifica, inventario, `unitotem-ota-changes`).
- Si distribuiscono **immagini intere**: il dispositivo scarica l'immagine, la scrive, ci si riavvia sopra;
  i dati utente non si toccano.

## Cosa cambia rispetto a oggi

Oggi c'è **un solo ROOT**. L'aggiornamento avviene dal fallback in RAM, che *sovrascrive* ROOT in place
(partclone+netcat, spinto dall'host via SSH). Conseguenze: il sistema è fermo per tutta la scrittura; se
l'immagine è difettosa il vecchio ROOT non c'è più e il rollback è "rifare un OTA"; l'orchestrazione sta
sull'host, non sul dispositivo.

Con A/B ci sono **due slot ROOT**. Il sistema in esecuzione scrive lo slot inattivo mentre continua a
funzionare, poi cambia slot con un riavvio di prova. Il vecchio slot resta intatto fino a conferma.

Il fallback in RAM **resta** come soccorso (entrambi gli slot rotti, primo deploy, adozione di OS estranei) e
come percorso "da host". Non lo si toglie: è l'unico strumento che funziona quando A/B non basta.

## Layout

arm64 (era: FIRMWARE 1G, ROOT 8G, DATA resto):

| # | label | fs | note |
|---|---|---|---|
| 1 | `FIRMWARE` | FAT32 1 GiB | firmware Pi condiviso + `slota/` `slotb/` + `recovery*` |
| 2 | `ROOT_A` | ext4 6 GiB | |
| 3 | `ROOT_B` | ext4 6 GiB | |
| 4 | `DATA` | ext4 resto | |

amd64: `EFI`, `BOOT` (può restare per recovery), `ROOT_A`, `ROOT_B`, `DATA`, `BIOS` (ef02).

Dimensione slot: 6 GiB (era 5, scelta dell'utente 2026-10-11: con il manager 3.0 la ROOT amd64 arrivava al 95% di 5 GiB; nota: un dispositivo gia' distribuito con slot da 5 GiB non puo' ricevere un'immagine da 6 GiB senza ripartizionare). Il margine di crescita non e' una scelta neutra: **la dimensione dello slot è
l'unico vincolo davvero rigido del sistema**, perché ridimensionarla dopo significa ripartizionare e
spostare DATA. Totale immagine 8 → 11 GiB circa (`IMAGE_SIZE` ~14 GiB).

### Selezione dello slot

**arm64 [da verificare su Pi 4]**: `os_prefix=slota/` (o `slotb/`) in `config.txt` fa cercare a firmware
kernel, initramfs, dtb, overlay e `cmdline.txt` nella sottodirectory dello slot. Le parti condivise
(`start4.elf`, `fixup4.dat`, `bootcode.bin`) restano nella radice. `cmdline.txt` di ogni slot dichiara
`root=PARTLABEL=ROOT_x` (o LABEL). Il meccanismo `tryboot` che già usiamo (`tryboot.txt`) fa la prova:
`tryboot.txt` ha `os_prefix=` dell'altro slot, è **one-shot a livello firmware** (un power cut durante la
prova riporta da solo al vecchio slot, senza software). Pi 3/Zero 2 senza tryboot: resta il percorso
`rpi-legacy` già esistente più il contatore di boot.

**amd64**: kernel e initramfs dentro il ROOT di ciascuno slot (`/boot`), GRUB legge ext4;
`grub-reboot <slot>` = prova one-shot, `grub-set-default` = promozione. `grubenv` sull'ESP.

`fstab` perde la riga `/` (il root viene da `root=` in `cmdline`); l'`initramfs` e `ota-local-bottom-verify`
smettono di usare `blkid -L ROOT` e usano il root passato dal bootloader.

### DATA e gli overlay: uno stato per slot

Oggi `/etc`, `/root`, `/var` sono overlay su `DATA/upper/*`, e un OTA sposta l'upper in `history/` reimportando
solo la whitelist. Con due slot **l'upper deve essere per-slot** (`upper/etc.a`, `upper/etc.b`, ...):
altrimenti l'aggiornamento distrugge lo stato di cui il vecchio slot ha bisogno per un rollback pulito.
All'applicazione: lo slot nuovo parte da un upper vuoto + whitelist importata (`ota-preserve.list`) dall'upper
dello slot corrente. Lo slot vecchio conserva il suo upper intatto.

Dati che devono essere **condivisi** tra slot stanno fuori dagli overlay, in `DATA/unitotem/persist/`
(vedi `unitotem-persist-paths`: `uploaded/`, `crontabs/`) e `ssh-host-keys/`.

**Rischio per il manager**: se il manager nuovo migra `/etc/unitotem/*` in un formato che il vecchio non
legge, il rollback porta a uno slot che non capisce i dati condivisi. Regola: i file in `persist/` e le
config condivise devono restare **retrocompatibili di una versione**, o il manager deve fare uno snapshot
prima di migrare.

## Niente apt a runtime, dpkg sì

Nello stage finale della build: `dpkg-divert` di `/usr/bin/apt*` e dei suoi helper (non `dpkg --purge`,
che con `--force-depends` lascia il database incoerente), e rimozione di `/etc/apt/sources.list*` e
`/var/lib/apt/lists`. Il database dpkg è già ancorato a ROOT (`overlayfs-hook.sh`), quindi viaggia con
l'immagine. Chi usava `apt` a runtime (`manager/utils/system/apt.py`, `unitotem-maintenance`) va ritirato.
`unitotem-ota-changes` resta utile: dice cosa è stato modificato nello slot attivo e che andrà perso
all'aggiornamento successivo.

## Consegna dell'immagine

Per release, un manifest firmato:

```json
{ "schema": 1, "version": "2026.10.1", "arch": "arm64", "layout": 2,
  "min_updater": 1, "channel": "stable",
  "parts": [ {"label":"ROOT","fstype":"ext4","used_bytes":..,"url":"..","sha256":"..","stream_sha256":".."},
             {"label":"BOOTFILES","kind":"tar","url":"..","sha256":".."} ],
  "notes_url": "..", "signature": "<ed25519 su tutto il resto>" }
```

- La **chiave pubblica** è nell'immagine (`/usr/share/unitotem/update-key.pub`); la firma è verificata
  **prima** di scrivere. Un hash senza firma protegge dalla corruzione, non da un server compromesso.
- Il ROOT è lo stesso stream partclone+xz di oggi; DATA **non è mai** nell'immagine.
- Download diretto in streaming nello slot inattivo (`curl | xz -d | partclone.restore`), senza staging
  su DATA. Niente resume a metà stream: se cade, si ricomincia (lo slot inattivo è marcato non valido
  all'inizio, quindi nessun riavvio può finirci). Se si vuole resume, serve staging su DATA con `Range` —
  scelta rimandata.
- Verifica dopo scrittura: `fsck`, label, sha256 dello stream, `/sbin/init` presente.

Mentre si scrive, **il rollback non esiste** (lo slot di rollback è quello che si sta scrivendo). Va
mostrato all'operatore.

## Contratto per il manager (pagina Updates)

Un solo comando sul dispositivo, `/usr/sbin/unitotem-update`, tutto con `--json`. Le operazioni lunghe
girano in un'unità systemd transiente (`systemd-run`), così sopravvivono al riavvio del manager. Il manager
**avvia** e **interroga**, non resta collegato.

| Sottocomando | Fa |
|---|---|
| `status` | slot attivo/inattivo, versione di ciascuno, `trial` (siamo in prova?), `pending_confirm`, `boot_count`, `last_result`, `rollback_available`, `op` in corso |
| `check [--manifest-url U]` | scarica e verifica il manifest; `available`, `version`, `size`, `needs_layout_migration`, `changes` |
| `fetch [--accept-changes DIGEST]` | verifica firma, scrive lo slot inattivo, verifica; **non** cambia boot |
| `apply [--reboot]` | arma la prova (tryboot / grub-reboot) e riavvia |
| `confirm` | promuove lo slot di prova a default (di norma lo fa il boot-ok da solo) |
| `rollback [--reboot]` | rimette come default lo slot precedente (se `rollback_available`) |
| `cancel` | interrompe `fetch` e marca lo slot inattivo non valido |

Codici di uscita: `0` ok · `10` niente da fare · `11` conferma modifiche richiesta (`--accept-changes`) ·
`12` operazione già in corso · `13` nessun rollback disponibile · `2` fallito · `127` assente (immagine
vecchia). Come per `unitotem-ota-changes`: ogni codice ha un significato, nessuno è "errore generico".

**Avanzamento**: `/run/unitotem-update.progress`, **una riga JSON** riscritta in modo atomico (tmp+rename):

```json
{"op":"fetch","phase":"write","percent":42,"bytes":1234567890,"total":2937000000,"eta_s":95,"state":"running"}
```

`phase ∈ check | download | verify | write | arm | reboot`; `state ∈ running | done | failed | cancelled`;
in caso di errore `error` e `error_code`. Il riavvio azzera `/run`: dopo il reboot la verità è in `status`
(`last_result`, persistito su DATA), non nel file di avanzamento.

**Conferma**: `unitotem-boot-ok` oggi conferma a `multi-user.target`. Per A/B deve attendere che
`unitotem-manager` risponda al suo healthcheck, altrimenti una release con manager rotto si "conferma"
comunque e il rollback automatico non scatta. Tre prove non confermate → ritorno automatico allo slot
vecchio (contatore già esistente in `cmd_init_premount`).

## Cosa va toccato nel codice

`unitotem/common.sh` e `stage3-image.sh` (layout, label, `os_prefix`/GRUB), `unitotem/files/fstab-*`,
`ota-init-premount`, `ota-local-bottom-verify`, `overlayfs-hook.sh` (upper per-slot),
`deploy/parts-lib.sh` (label `ROOT_A/B`), `deploy/ota-engine.sh` (slot-aware, arming/promote), nuovo
`unitotem-update`, `unitotem-boot-ok`, e i test di loopback (nuovo scenario "aggiornamento in sede").

## Migrazione dei dispositivi esistenti

Il layout cambia: DATA cambia posizione. Una tantum, via fallback: copiare DATA sull'host (è piccolo),
riscrivere la tabella, ripristinare DATA. È un OTA "con relocazione di DATA", mai provato. **[da verificare
prima di promettere che i dati utente sopravvivano]** — in particolare con il power cut a metà: serve il
backup su host prima di toccare la tabella.

## Release e chiavi di firma su GitHub

Fatti verificati: il repo è `a13ssandr0/unitotem` ed è **pubblico**; `gh` è autenticato; non esiste ancora
`.github/`. Le immagini attuali pesano ~1.1 GB (`unitotem-*-amd64.img.xz`), sotto il limite di **2 GiB per
asset** delle GitHub Release (limite noto da documentazione, non provato qui). Se un ROOT lo superasse, il
manifest dichiara più `parts` per lo stesso label e il dispositivo le concatena.

**Distribuzione**
- Una Release per versione (`v2026.10.1`); `prerelease` = canale `beta`, il resto = `stable`. Asset:
  `manifest.json`, `manifest.json.sig`, gli stream delle partizioni, `SHA256SUMS`.
- Il dispositivo scarica da `https://github.com/<repo>/releases/latest/download/manifest.json` e dagli URL di
  download: **non** da `api.github.com`, che senza token ha 60 richieste/ora per IP e più chioschi dietro lo
  stesso NAT lo esaurirebbero.
- Build e pubblicazione con GitHub Actions: la pipeline Docker+qemu è lenta e privilegiata (loop device),
  quindi un runner **self-hosted** su questo host, non i runner ospitati. L'immagine di build può stare su
  GHCR. Il job di rilascio usa un *Environment* con approvazione manuale prima di firmare.
- Attestazione di provenienza (`actions/attest-build-provenance`) come tracciabilità aggiuntiva, non come
  sostituto della firma: il dispositivo non verifica Sigstore.
- **Repo pubblico = ogni immagine è pubblica.** Prima della prima release va controllato che l'immagine non
  contenga segreti (la password SSH di default dei test, certificati, token). Se contiene qualcosa che non
  deve essere pubblico, serve un repo privato con token sul dispositivo, che è estraibile: peggio.

**Il problema vero è la perdita della chiave, non la custodia**

Con una sola chiave Ed25519, perderla significa che **nessun dispositivo già installato accetta più un
aggiornamento firmato** (fidano solo di quella): resta il reflash dal fallback, uno per uno. Quindi la
difesa principale non è "fare più backup" ma **non dipendere da un solo segreto**:

1. Due chiavi pubbliche nell'immagine (`/usr/share/unitotem/update-keys/`):
   - **chiave di rilascio**: usata dalla CI, vive come *secret* dell'Environment GitHub. Se si perde o
     compromette, si sostituisce.
   - **chiave radice di recupero**: offline, non toccata dalla CI. Autorizza una nuova lista di chiavi
     (un `keys.json` firmato dalla radice, scaricato insieme al manifest), così si **ruota** la chiave di
     rilascio su tutta la flotta senza reflash.
2. Perdere la sola chiave di rilascio diventa quindi un incidente recuperabile. Perdere la radice **e**
   la chiave di rilascio no: per questo la radice va salvata bene.
3. Backup della radice (e della chiave di rilascio): ogni copia cifrata con passphrase (`age -p`), mai in
   chiaro, mai nel repo in chiaro. Almeno tre posti indipendenti dal PC: gestore di password,
   chiavetta/disco offline in un altro luogo, stampa su carta con la passphrase separata.
   Una copia cifrata può stare in un repo **privato** su GitHub, ma con una passphrase forte e sapendo che
   protegge dal guasto del PC, non da un attaccante che ha l'account GitHub.
4. I *secret* di GitHub sono scrivibili ma **non leggibili**: non sono un backup, solo un luogo d'uso.
5. Verificare il ripristino: una volta, da una copia, firmare un manifest di prova e farlo accettare dal VM.
   Un backup mai ripristinato è un'ipotesi.

Alternativa scartata per ora: firma keyless Sigstore (OIDC di GitHub) che elimina la chiave privata, ma il
dispositivo dovrebbe validare certificati e il log Rekor, con una radice di fiducia che ruota; troppo per
un'immagine offline-first. Riconsiderabile.

## Fattibilità Alpine (nota breve, **non verificata sul campo**)

Conoscenza generale, nessuna prova eseguita qui. CEF 147 distribuito come binari/wheel è costruito per
**glibc**: su musl richiede uno strato di compatibilità (`gcompat`) fragile, soprattutto con GPU e
accelerazione video. Il driver proprietario NVIDIA è **solo glibc**: sulla GTX 1060 resterebbe nouveau.
PySide6 su Alpine esiste come pacchetto ma non l'ho controllato. Conclusione provvisoria: nessun vantaggio
che giustifichi il rischio, e già in contrasto con la scelta di restare su Debian. Non approfondito.

## Domande aperte per l'utente

1. Slot da 5 GiB va bene (disco minimo cresce di ~3 GiB)? È l'unico vincolo difficile da cambiare dopo.
2. Resume del download (staging su DATA) o ricominciare da capo se cade?
3. ~~Chiave di firma~~ → vedi "Release e chiavi di firma su GitHub"; resta da decidere dove si custodisce la chiave radice (gestore di password, chiavetta, carta).

## Stato dell'implementazione (2026-10-10, sera)

Attivo con `AB_LAYOUT=1` in `build-unitotem.sh` (spento di default: il layout a ROOT singolo resta quello supportato).
Le architetture si costruiscono ora in parallelo e i pacchetti vengono scaricati con aria2 in una cache persistente
(`work/apt-cache`); le immagini amd64/arm64 A/B si ottengono con
`AB_LAYOUT=1 RELEASE_VERSION=x.y.z ARCHES="amd64 arm64" ./build-unitotem.sh`.

**Provato in QEMU/UEFI (amd64), non su hardware:**
- Primo deploy da host (`remote-deploy.sh` + `ota-engine.sh`, modalita' A/B): harness loopback `work/loopback-test/run-ab.sh`
  (27 controlli) e poi avvio del disco risultante: GRUB trova la sua configurazione grazie al volid FAT preservato,
  prova lo slot A (one-shot), il fallback resta il default finche' `unitotem-boot-ok` non conferma.
- Aggiornamento in sede con `unitotem-update`: check, fetch, apply, prova, conferma, rollback manuale, rollback
  automatico se `/health` non risponde, annullamento, rifiuto con `busy`.
- 21 scenari di spegnimento forzato (`work/loopback-test/powercut-ab.sh`, `kill -9` di QEMU a ogni punto critico di
  fetch/apply/prova/conferma/rollback, durante l'avvio dello slot nuovo e con grubenv corrotto). Hanno trovato
  e fatto correggere: (1) per tutta la scrittura dello slot inattivo esisteva un secondo filesystem con etichetta
  `ROOT_A` e UUID dello slot A, che `root=LABEL=ROOT_A` o GRUB potevano scegliere: lo stream di release ha ora
  etichetta neutra `ROOT_NEW` e lo slot prende la sua etichetta solo a scrittura verificata; (2) un nuovo `fetch`
  dopo il taglio non trovava lo slot (ricerca per etichetta): ora per nome di partizione GPT; (3) i file di stato su
  DATA non erano fsync'ati e dopo un taglio comparivano vuoti o assenti: ora fsync del file e della directory, e
  `os.sync()` prima di marcare `valid`; (4) con grubenv illegibile GRUB sceglieva il fallback invece di uno slot:
  la voce di fallback e' ora l'ultima; (5) il file di whitelist si copiava non atomicamente.
  (6) il piu' grave: DATA era creata senza journal (`^has_journal`, scelta per risparmiare la SD) e senza fsck all'avvio.
  Dopo un taglio un file mai toccato (`slots.json`) si rileggeva come byte nulli: blocchi liberati e riusati mentre
  la bitmap su disco li diceva ancora liberi. Ora il journal resta (stage3, `data-op mkfs`), l'initramfs lo aggiunge
  alle DATA esistenti (`tune2fs -O has_journal` a filesystem smontato) ed esegue `e2fsck -p` prima del mount.
  Sulle ROOT (journal di default) non c'era il problema.
- Risultato finale su immagine 2026.10.6 + release 2026.10.7 (stessi artefatti consegnati): **21 scenari, 103 controlli,
  0 falliti** (`work/loopback-test/powercut-ab.sh par 6 all`, circa 25 minuti con 6 VM in parallelo).
- Principio adottato (richiesta dell'utente): dopo qualsiasi interruzione si RIPETE l'operazione (idempotente) invece
  di fidarsi di un flag. `apply` rifa' un fsck in sola lettura e controlla l'etichetta dello slot prima di armare.

**Raspberry Pi (arm64): scritto, NON provato su una scheda.** Backend `os_prefix` + `tryboot` dietro la stessa interfaccia
di GRUB, release con asset `bootfiles` (kernel/initramfs/dtb/overlay dello slot), `apply` richiede `--reboot` perche'
il tryboot esiste solo con il riavvio contestuale. Testato solo in modo "a secco" (`tools/release/test_rpi_backend.py`,
22 controlli con una directory finta al posto della FAT). Non so se il firmware della Pi 4 rispetta `os_prefix` per tutti
i file ne' come si comporta `tryboot.txt` con `os_prefix`; la Pi di test (<pi-host>) non era raggiungibile.
Il deploy da host A/B e' implementato solo per amd64/UEFI.

**Non provato / non scritto:**
- Hardware amd64 reale (UEFI e BIOS legacy).
- Il modello di spegnimento usato (kill di QEMU) non simula la cache volatile di un disco fisico ne' il riordino delle
  scritture, ne' un taglio dentro una singola scrittura di blocco.
- Migrazione di un dispositivo a ROOT singolo verso il layout A/B (DATA cambia posizione).
- `--accept-changes` e' accettato e ignorato: lo slot corrente non viene distrutto dall'aggiornamento.

## Raspberry Pi 4 reale (osservato il 2026-10-11)
Pi 4 Model B rev 1.5, EEPROM 2026/05/17, immagine arm64 A/B 2026.10.6/10.7 (manager 2.x del repository, health gate disattivato).
- Primo deploy da host in A/B (tabella ricreata, FAT riformattata, fallback in RAM, ROOT_A, ROOT_B vuota, DATA): ha richiesto la correzione di `prepare-bootfs` (mkfs.fat con la FAT montata su /boot-ota).
- `os_prefix=slota/` e `tryboot` FUNZIONANO sul Pi 4: avvio di prova da `slota/`, conferma automatica, `config.txt` promosso a `os_prefix=slota/` + `kernel8.img`, `tryboot.txt` rimosso.
- Aggiornamento in sede A->B (fetch di 744 MB dal finto GitHub, scrittura di ROOT_B, bootfiles in `slotb/`, `apply --reboot` con tryboot, conferma) e rollback manuale B->A: riusciti.
- Errori trovati solo sull'hardware: dtb/overlays spostati invece che copiati (fallback senza device tree = arcobaleno), scadenza della verifica di salute su orologio di sistema (nessun RTC), tar con chown su vfat (rc=2).
- NON verificato: nessun taglio di corrente sul Pi (vietato); HDMI: il kernel segnala HDMI-A-1/2 `disconnected` e la cattura e' nera, quindi nessuna immagine vista; manager 2.x non utilizzabile come kiosk su root in sola lettura; Pi 3/Zero 2 (senza tryboot) non coperti.

## Aggiornamento automatico (politica sul dispositivo, 2026-10-27)

`unitotem-update-auto.timer` (ogni 10 minuti, 10 dopo l'avvio) esegue `unitotem-update --json auto` a priorità minima (Nice=19, I/O idle).
La politica sta in `<stato>/auto.json` e si legge/imposta con `unitotem-update --json policy [--set-mode MODE] [--time HH:MM]`
(la pagina impostazioni del manager la chiama); lo stato dell'ultimo giro è in `status` (`auto.policy`, `auto.state`, `staged`).

| modo | cosa fa quando trova una release più nuova |
|---|---|
| `off` (default) | niente |
| `download` | scarica nello slot inattivo e si ferma |
| `stage` | scarica e "arma" l'avvio di prova **senza riavviare**: il sistema nuovo parte al prossimo riavvio |
| `reboot` | scarica, arma e riavvia subito |
| `scheduled` | scarica e arma; riavvia solo nella finestra di un'ora che inizia a `time` (ora locale), al massimo una volta al giorno |

Regole: mai mentre gira un'altra operazione o una prova d'avvio, mai nei primi 10 minuti dopo l'avvio, domanda al server al massimo ogni 6 ore,
backoff esponenziale (1 h … 24 h) dopo un errore di rete o di download, mai in automatico se la release richiede una migrazione di layout.
Un update armato ("staged") rifà ogni 10 minuti la fusione di account e /etc, così le modifiche fatte nell'attesa arrivano nello slot nuovo.

Differenza tra i due backend per `stage`/`scheduled`: **GRUB** (PC) avvia il sistema nuovo al prossimo riavvio di qualunque tipo (next_entry è
one-shot). **Raspberry**: il firmware legge `tryboot.txt` solo se il riavvio è richiesto con il flag tryboot, quindi l'update armato parte solo con
`unitotem-update reboot` (usato dalla politica `reboot`/`scheduled` e da chiunque lo chiami, es. il pulsante Riavvia del manager); un riavvio normale
o un taglio di corrente avvia lo slot vecchio e l'update resta armato (`staged`), senza essere scambiato per una prova fallita.
