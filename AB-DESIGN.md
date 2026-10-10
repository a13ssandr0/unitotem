# Design: immagine Debian immutabile con aggiornamento A/B

**Stato: proposta, nulla implementato né verificato su hardware.** Tutto ciò che segue è deduzione dal codice
attuale (`PLAN.md`, `STATO.md`, `deploy/ota-engine.sh`, `kiosk/files/*`) e da documentazione nota dei
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
| 2 | `ROOT_A` | ext4 5 GiB | |
| 3 | `ROOT_B` | ext4 5 GiB | |
| 4 | `DATA` | ext4 resto | |

amd64: `EFI`, `BOOT` (può restare per recovery), `ROOT_A`, `ROOT_B`, `DATA`, `BIOS` (ef02).

Dimensione slot: ROOT usa oggi 2.93 GiB. 5 GiB lasciano margine di crescita; **la dimensione dello slot è
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
l'immagine. Chi usava `apt` a runtime (`manager/utils/system/apt.py`, `kiosk-update`) va ritirato.
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

`kiosk/common.sh` e `stage3-image.sh` (layout, label, `os_prefix`/GRUB), `kiosk/files/fstab-*`,
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
`.github/`. Le immagini attuali pesano ~1.1 GB (`kiosk-*-amd64.img.xz`), sotto il limite di **2 GiB per
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
