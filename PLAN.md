# Deploy OTA a due stage con immagine di fallback residente

## Context

Il deploy attuale (`deploy/remote-deploy.sh` + `deploy/flasher/unitotem-flash`, commit `d1c598c`) scrive
l'immagine **intera** con `dd bs=4M`: 12 GiB su ogni target, contro un'occupazione reale **misurata di
2.95 GiB** (FIRMWARE 21.7 MiB, ROOT 2.93 GiB, DATA 24 KiB). Su SD di un Pi 4 sono ~10-12 minuti quasi
tutti spesi a scrivere zeri. Il test su hardware reale ha esposto due problemi indipendenti:

1. **L'immagine arm64 non si avvia sul Pi.** Il `dd` era corretto (label FIRMWARE/ROOT/DATA giuste, DATA
   espansa, `/etc/kiosk` presente) ma la FIRMWARE non contiene `kernel8.img` né i `.dtb`:
   `/etc/kernel/postinst.d/z50-raspi-firmware` calcola `flavour="${kernel_version#*-rpi-}"` e con il
   kernel Debian generico `6.1.0-49-arm64` non matcha il suo case `v8|v8-rt|2712|v6|v7|v7l`, quindi esce
   senza copiare nulla. Risultato: loop di lampeggi del LED, macchina irraggiungibile.
2. **Un fallimento a metà scrittura lascia la macchina morta**, senza alcuna via di recupero remota.

Inoltre `kiosk/files/overlayfs-hook.sh:20-32` usa **DATA come upperdir degli overlay di `/etc` e
`/root`**: il `dd` whole-disk distrugge la configurazione della macchina ad ogni deploy.

**Esito voluto.** Deploy in **due stage**: prima un'immagine di **fallback** minimale (nessun UniTotem,
solo il necessario per ricevere OTA) che viene resa avviabile **immediatamente**, così ogni perdita di
alimentazione successiva riporta la macchina in stato ricevente; poi l'immagine UniTotem vera, per
partizione, con partclone, preservando DATA. La priorità assoluta è che **l'immagine Pi sia avviabile**:
il piano prevede asserzioni di build e gate di verifica espliciti per questo, e la verifica su hardware
reale è strutturata per riuscire **al primo colpo**, dato che l'utente non dispone di supporti di scorta.

Questa revisione incorpora una seconda tornata di verifiche tecniche esplicitamente richieste (pi-gen
upstream, PINN/NOOBS, comportamento reale di `partclone.restore`, precedente di Clonezilla) — vedi §2 e
§4.2 per i dettagli e le fonti.

### Decisioni prese (non rimetterle in discussione)

| Tema | Decisione |
|---|---|
| Forma del fallback | **Kernel + initramfs autosufficiente** sulla partizione FAT di boot (ESP su amd64, FIRMWARE su arm64), **generato dallo stage 1** della build (non un artefatto separato). Niente rootfs da corrompere, niente fsck. |
| Trasferimento | Per partizione, **partclone** (quello che spediamo noi nel payload, non quello eventualmente già installato sul target) + xz. Il guadagno è nei **byte scritti** (12 GiB → ~3 GiB), non nella banda. |
| Connessioni | Due, come richiesto: **controllo = SSH** (dropbear nel payload; dice quale partizione arriva tramite il comando eseguito), **dati = netcat puro**. Non un protocollo binario inventato da zero — vedi §4.2. |
| Rete | Sonda **prima** del trasferimento: DHCP o statico, cablata **o WiFi (WPA2-PSK)**. Il segreto WiFi **non viene cancellato**: resta nella config di rete finché serve, esattamente come resterebbe comunque in chiaro nel rootfs (NetworkManager/netplan non cifrano i segreti). |
| DATA | Preservata di default (`--wipe-data` per l'installazione pulita). Nuovo sistema → tabella ricreata; sistema già UniTotem → tabella intatta, DATA preservata. **L'`/etc` della nuova immagine vince sempre**: la whitelist da DATA è additiva su valori operativi, mai sostitutiva. |
| Switch di boot | Il sistema reale diventa default **solo dopo avvio confermato**; fino a quel momento il default è il fallback. |
| Layout | **Ricostruibile** con dimensioni adeguate, vincolo: ogni partizione deve restare **copiabile con partclone** (quindi solo ext4 e FAT32, nessun LUKS/btrfs/LVM). |
| Modo `part` | Eliminato. Modo sorgente **locale** (`ram`) mantenuto come alternativa alla rete. |
| Diagnostica | `gdisk`/`parted`/altre utility disco **restano nel payload** anche se il percorso automatico non le usa: costano poco, e l'unica volta che servono sono preziose. |
| arm64 | Fix manuale della FIRMWARE **ora**; passaggio a `linux-image-rpi-v8` come step successivo separato. |

---

## Step 0 — Rendere avviabile la SD attuale (subito, a mano)

La SD è montata sull'host e contiene già l'immagine kiosk scritta correttamente. **Non serve riflashare
Raspberry Pi OS**: `ROOT/boot/vmlinuz-6.1.0-49-arm64` è un **Image arm64 non compresso** (magic `ARMd` a
0x38, confermato con `file` e `xxd`), quindi il firmware del Pi lo avvia direttamente.

1. `ROOT/boot/vmlinuz-6.1.0-49-arm64` → `FIRMWARE/kernel8.img`
2. `ROOT/usr/lib/linux-image-6.1.0-49-arm64/broadcom/bcm27*.dtb` → `FIRMWARE/` (11 file, incluso
   `bcm2711-rpi-4-b.dtb`)
3. `ROOT/boot/initrd.img-6.1.0-49-arm64` → `FIRMWARE/initramfs8`, più `initramfs initramfs8 followkernel`
   e `kernel=kernel8.img` in `config.txt`
4. Commentare `dtoverlay=vc4-kms-v3d`/`-pi5`: il pacchetto kernel Debian **non contiene `overlays/`**,
   quelle righe non possono funzionare. Il Pi si avvia a console + X su fbdev, **senza KMS**.

Accesso al sistema avviato: `root`/`unitotem` (`kiosk/common.sh:11`, `kiosk/files/sshd_config`). Serve
come target SSH per tutto il resto. **Questo è l'unico intervento manuale sulla SD reale**: tutto il
resto del piano si verifica su loop device/VM prima di toccarla di nuovo (§11.4).

---

## 1. Nuovo layout delle partizioni

Vincolo dell'utente: tutto copiabile con partclone → solo **ext4** e **FAT32**. La partizione FAT di boot
deve ospitare **due** coppie kernel+initrd (fallback + reale).

| # | amd64 | tipo | dim. | # | arm64 | tipo | dim. |
|---|---|---|---|---|---|---|---|
| 1 | `EFI` | FAT32 `ef00` | **1 GiB** | 1 | `FIRMWARE` | FAT32 | **1 GiB** |
| 2 | `BOOT` | ext4 | 1 GiB | 2 | `ROOT` | ext4 | **8 GiB** |
| 3 | `ROOT` | ext4 | **8 GiB** | 3 | `DATA` | ext4 | resto |
| 4 | `DATA` | ext4 | resto | | | | |
| 5 | `BIOS` | `ef02` | sett. 34-2047 | | | | |

`IMAGE_SIZE` 12 GiB → **11 GiB** (ROOT da 10 a 8 GiB: 2.93 GiB usati, resta ampio margine), così il
disco minimo richiesto scende e più target qualificano. La ef02 resta nascosta nel gap pre-2048 come già
fa `kiosk/stage3-image.sh:27-31`, così nessun offset si sposta. Modificare `kiosk/common.sh:15-19`.

**La partizione FAT di boot viene popolata a livello di file, non con partclone.** È la scelta che rende
possibile la garanzia richiesta: lo stage 2 deve scriverci il kernel/initrd del sistema reale **senza
cancellare quelli del fallback**. Costa poco (~50-100 MB di contenuto, copia da mount) e vale la
proprietà. Tutte le altre partizioni (BOOT, ROOT) vanno con partclone, che è dove sta il guadagno.

Contenuto della FAT di boot dopo un deploy completo:

```
arm64 FIRMWARE/                          amd64 EFI/
  bootcode.bin, start*.elf, fixup*.dat     EFI/BOOT/BOOTX64.EFI      (GRUB --removable)
  bcm27*.dtb, overlays/                    unitotem/recovery-vmlinuz
  recovery8.img                            unitotem/recovery-initrd.img
  recovery-initrd.img                      unitotem/recovery.sha256
  recovery.sha256                          unitotem-ota.conf
  kernel8.img        <- sistema reale      unitotem-ota.state
  initramfs8         <- sistema reale
  config.txt         <- seleziona chi avvia
  unitotem-ota.conf  <- parametri di rete
  unitotem-ota.state <- stage/trial/boot-ok
```

---

## 2. Il fallback è lo stage 1 della build, non un artefatto separato

### 2.1 Perché (verificato su pi-gen upstream, vendorizzato in questo stesso repo)

Come richiesto, ho verificato il comportamento di pi-gen upstream invece di assumerlo: questo repository
contiene **letteralmente** l'albero pi-gen originale (`stage0/`, `stage1/`, `stage2/`, `export-image/`,
`build.sh`, `scripts/common`), separato dal nuovo sistema `kiosk/`. Leggendo `build.sh:93-150` e
`scripts/common:31-36`:

- ogni stage ha una propria `ROOTFS_DIR` che nasce da un **`rsync -aHAXx --exclude var/cache/apt/archives`
  della rootfs dello stage precedente** (`scripts/common:36`), poi riceve le proprie modifiche — non è un
  tarball ricreato da zero, è un incremento cumulativo;
- un file `SKIP` dentro una directory di stage salta **l'intero stage** (build.sh:118, la rootfs esistente
  viene riusata così com'è); un file `SKIP_IMAGES` salta solo l'esportazione dell'immagine ma continua a
  costruire la rootfs (build.sh:113), perché l'export è il passo costoso separato dalla costruzione;
- un file `EXPORT_IMAGE` in una directory di stage la marca come **punto di esportazione**: pi-gen può
  produrre un'immagine flashabile da **qualunque stage intermedio**, non solo dall'ultimo (`stage2/
  EXPORT_IMAGE` è l'unico presente in questo repo: la build vendorizzata esportava solo da stage2, ma il
  meccanismo supporta stage multipli, incluso `EXPORT_NOOBS` per bundle NOOBS-compatibili).

Questo conferma esattamente l'idea del punto 2: **il fallback può essere l'immagine di uno stage
intermedio su cui il resto si costruisce sopra**, e la build può essere strutturata per ricostruire solo
gli strati più esterni quando cambia poco. Il sistema `kiosk/` (nuovo, non-pi-gen) oggi non ha questo
meccanismo — estrae ogni stage da un tarball statico via `tar -C "${ROOTFS}" -xzf` (`kiosk/stage2-configure.sh`
e affini) senza `SKIP`/rsync incrementale. Applicando lo stesso principio:

- `kiosk/stage1-packages.sh` guadagna i pacchetti OTA (partclone, dropbear, wpasupplicant, whiptail —
  quest'ultimo già presente) **e basta**: nessuna configurazione kiosk-specifica;
- **il kernel+initrd del fallback si costruisce a fine stage1**, con `mkinitramfs` lanciato contro la
  rootfs di stage1 così com'è, includendo l'hook OTA — nessuna build separata, nessun `Dockerfile.parts`
  per il fallback, nessun `deploy/recovery/*`;
- stage2/stage3 continuano a costruire l'immagine UniTotem completa **sopra** la stessa rootfs di stage1
  (già oggi `kiosk/stage2-configure.sh` estrae da `work/$ARCH/stage1.tar.gz`, quindi la dipendenza esiste
  già — manca solo la generazione del kernel/initrd di recovery come sotto-prodotto di stage1);
- **cache**: aggiungere a `kiosk/common.sh` un controllo "se `work/$ARCH/stage1.tar.gz` esiste ed è più
  recente di `kiosk/stage1-packages.sh`, salta la ricostruzione" (l'equivalente pratico di `SKIP` di
  pi-gen, dato che il sistema `kiosk/` non ha overlay incrementale rsync ma tarball per stage). Un cambio
  a `stage2-configure.sh`/`stage3-image.sh` (temi, sway, chromium) non tocca più né i pacchetti né il
  fallback e non richiede mai di rigenerare `stage1.tar.gz` né il suo initrd — **solo gli strati esterni
  si ricostruiscono**, esattamente come richiesto.

### 2.2 Perché la build arm64 sotto qemu era lenta — e come evitarlo (verificato, non ipotizzato)

La diagnosi precedente (in questa stessa sessione) aveva individuato lo stallo: `mkinitramfs` con
`MODULES=most` copiava firmware AMD irrilevante (`amdgpu/navi14_pfp_wks.bin`) sotto traduzione
`qemu-aarch64`. Punto chiave, verificabile: **nessun binario viene ricompilato** in nessuna delle due
pipeline (pi-gen o `kiosk/`) — i pacchetti sono `.deb` arm64 già pronti scaricati dal mirror; qemu-user-static
serve solo a eseguire gli script maintainer (`postinst`/`triggers`) e i tool che girano durante l'installazione
(`depmod`, `ldconfig`, e soprattutto `mkinitramfs` stesso). Il costo è quindi tutto nell'**esecuzione emulata**
di programmi che enumerano il filesystem (migliaia di piccole `stat`/`open`), non nella compilazione. Due
mitigazioni concrete, entrambe già validate in questa sessione:
1. **`mkinitramfs` va eseguito nativamente**, su un Pi reale via SSH (già provato: ~10 min contro 12+ min
   e incompleto sotto qemu) oppure su un runner arm64 nativo se disponibile. Solo l'installazione dei
   pacchetti (download + unpack, non l'esecuzione di `mkinitramfs`) può restare sotto qemu se serve.

**Correzione post-implementazione (verificata con un fallimento reale, non solo ipotizzata): `MODULES=most`
non va sostituito.** Il tentativo di passare a `MODULES=dep` + un elenco mirato di driver è stato
implementato e poi **fallito immediatamente alla prima build reale** con
`mkinitramfs: failed to determine device for /`: `MODULES=dep` funziona facendo un probe del device di
`/` **della macchina di build**, per capire quali moduli servono — dentro un chroot Docker non esiste un
device reale dietro `/`, quindi il probe non trova nulla e la build fallisce sempre, non solo sotto qemu.
`MODULES=most` non ha questo problema perché non ha bisogno di sapere nulla sul device di build — è
anche la scelta corretta per questo initrd, che deve avviarsi su hardware non noto in anticipo. La vera
causa dello stallo resta la mitigazione 1 sopra (esecuzione nativa, non sotto qemu): `MODULES=most`
stesso non è il problema, lo è eseguirlo sotto emulazione.
`deploy/build-flasher.sh`/`flasher-image.sh`/`Dockerfile.flasher` restano eliminati come da §9; la loro
funzione si sposta dentro `kiosk/stage1-packages.sh` con queste due correzioni.

### 2.3 Contenuto del fallback (= rootfs di stage1 + hook OTA)

bash, partclone (`extfs`/`fat`/`dd`/`restore`/`info`), **`gdisk`/`sgdisk`, `parted`** (tenuti per
diagnosi manuale, vedi tabella decisioni), `sfdisk`, `partx`, `blockdev`, `blkid`, e2fsprogs, `mkfs.fat`/
`fatlabel`, `xz`/`unxz`, `pv`, `whiptail` (+ libnewt/libslang), **`dropbear-bin`** (client+server SSH,
motivazione in §4.2), `netcat-traditional` (canale dati), `sha256sum`/`base64`/`awk`,
`wpa_supplicant`+`wpa_passphrase`+firmware `brcm80211`, terminfo, e su amd64 `efibootmgr`+`grub-install`.

**`busybox-initramfs` è INEVITABILE — verificato, non un'ipotesi da eliminare.** Controllo diretto:
`apt-cache show initramfs-tools-core` riporta `Depends: ... busybox-initramfs` (dipendenza dura, non
Recommends). Qualunque immagine capace di generare un proprio initramfs lo ha già, con o senza `udhcpc`.
La causa dei bug già diagnosticati su `mke2fs` ("applet not found") e `dd` (`conv=`/`oflag=` rifiutati) è
il suo hook `zz-busybox-initramfs`, che hardlinka busybox su ogni nome che dichiara di implementare e che
non trova già presente al momento in cui gira (sempre per ultimo). **Il ciclo di `cp -a` forzato che
sostituisce con il binario reale `mke2fs`/`dd`** (pattern già in `deploy/flasher/hook:46-53`) resta quindi
una parte **permanente** dell'hook OTA, non un workaround temporaneo legato a `udhcpc` — va esteso a ogni
binario copy_exec'd il cui nome coincide con un applet busybox (`mount`, `umount`, `losetup`, `mkfifo`
inclusi, per la collisione klibc simmetrica già nota).

**terminfo e `TERM` — bug latente da correggere.** L'initrd attuale non contiene **alcun** terminfo,
quindi il `dialog --gauge` aggiunto di recente (`unitotem-flash:366-374`) non può disegnare, e il suo
fallback scatta solo se il **binario manca**, non se **erra**. Fix: `copy_file` di
`/lib/terminfo/{l/linux,v/vt220,v/vt100}` (verificati presenti nel rootfs), `export
TERMINFO=/lib/terminfo`, `TERM=linux` per console framebuffer e **`TERM=vt220` quando `console=` nomina
`ttyS*`/`ttyAMA*`** (come si guarda il Pi da seriale), più `LINES=24 COLUMNS=80` perché lo stdin del
gauge è una FIFO e newt non può dedurne le dimensioni. E `gauge_start` deve verificare `kill -0 $pid`
dopo 0.5 s e **degradare a testo su errore**, non sull'assenza del binario; tutto il sottosistema gauge
va isolato perché un suo fallimento non possa far scattare il trap `ERR` e abortire un flash in corso.

Stima dimensione: dropbear-bin ~130 KB, partclone ~1.9 MB, gdisk+parted ~1.5 MB, wpasupplicant+firmware
~4 MB, resto come già stimato — totale ~8-9 MB su un rootfs di 2.93 GiB, irrilevante.

---

## 3. Sonda di rete e parametri passati al fallback

Prima di qualunque trasferimento, `remote-deploy.sh` interroga via SSH il target **in esecuzione** e
determina come raggiungere l'host. Tutto in un unico round-trip, estendendo `do_probe`
(`remote-deploy.sh:60-142`):

- interfaccia usata per raggiungere l'host: `ip -o route get <host-ip>` (idioma già presente a `:436`);
- tipo di collegamento: `/sys/class/net/<if>/wireless` esistente → WiFi, altrimenti cablata (stesso test
  di `iso/installer.sh:143-152`);
- indirizzo/prefisso/gateway/DNS correnti: `ip -j addr show <if>`, `ip -j route`, `/etc/resolv.conf`;
- **DHCP o statico**: presenza di un lease (`/var/lib/dhcp/*.leases`, `/run/systemd/netif/leases/*`,
  `nmcli -t -f IP4.DHCP4 device show <if>`) → DHCP; altrimenti statico e si registrano i valori;
- se WiFi: SSID e PSK da `/etc/NetworkManager/system-connections/*`, `/etc/netplan/*`,
  `/etc/wpa_supplicant/*.conf` (in quest'ordine).

Il risultato finisce in `unitotem-ota.conf` sulla FAT di boot, con la stessa grammatica `KEY=VALUE`
irrobustita usata altrove:

```
OTA_NET_IFACE=eth0            OTA_NET_LINK=wired|wifi
OTA_NET_MODE=dhcp|static      OTA_NET_ADDR=<pi-host>/24
OTA_NET_GW=192.168.1.1        OTA_NET_DNS=192.168.1.1
OTA_WIFI_SSID_B64=...         OTA_WIFI_PSK_B64=...
OTA_HOST=<dev-pc>         OTA_CTRL_PORT=9700
```

Il fallback prova, in ordine: i parametri del file → DHCP sull'interfaccia indicata → DHCP su ogni
interfaccia → prompt whiptail su console. In WiFi genera al volo la config di `wpa_supplicant` da SSID e
PSK.

**Gestione del segreto WiFi — corretta rispetto alla bozza precedente.** `OTA_WIFI_PSK_B64` **non viene
cancellato** dopo l'uso. Motivo (indicato esplicitamente): cancellarlo non aumenta la sicurezza reale,
perché lo stesso segreto resta comunque in chiaro nel rootfs del sistema reale
(`/etc/NetworkManager/system-connections/*`, `/etc/wpa_supplicant/*.conf` — né NetworkManager né netplan
cifrano le credenziali WiFi), quindi cancellarlo dalla FAT di boot non elimina un'esposizione, elimina
solo un percorso di recupero. Tenendolo, un totem **solo-WiFi con ROOT distrutta e senza console** resta
recuperabile via OTA: è esattamente il limite che la bozza precedente dichiarava irrisolvibile, e non lo
è. Il file viene comunque **aggiornato** (non append-only) ad ogni sonda, così una PSK cambiata sul
target si propaga.

---

## 4. Parts set e canali di trasferimento

### 4.1 Parts set
`deploy/make-parts.sh <image.img.xz>` → `deploy/$ARCH/<base>.parts/`. Decorrelato dalla build del kiosk,
perché il formato cambierà più volte e ogni modifica deve essere ritestabile sulle immagini **già
costruite** senza rebuild da 40 minuti. Un blocco opzionale `MAKE_PARTS` in `kiosk/stage3-image.sh` (fra
`umount /mnt` alla riga 141 e `losetup -d` alla 142) userà la stessa libreria.

- `xz -dc | dd conv=sparse` su uno scratch in `work/`, poi `losetup -r --partscan`, riusando il pattern
  `cleanup_loop` di `kiosk/stage3-image.sh:43-60`.
- **partclone va pinnato fra generatore e payload, non contro un target pre-esistente.** Punto corretto
  rispetto alla bozza precedente: il payload OTA porta **il proprio** `partclone.restore` (§2.3), il
  target non ha e non deve avere un partclone preinstallato di cui preoccuparsi. Il vincolo reale è che
  chi **genera** gli stream (`make-parts.sh`) e chi li **legge** (il payload) usino lo stesso formato
  immagine. Questo host ha 0.3.44, bookworm (l'OS sia del payload sia del target) ha 0.3.23: la
  generazione gira quindi in `Dockerfile.parts` (`FROM debian:bookworm`) per essere sicuramente coerente
  col partclone che lo stage1 spedisce, non per inseguire una versione "del target". **Nessun qemu**:
  partclone legge ext4/FAT indipendentemente dall'architettura del contenuto, quindi lo stesso container
  serve amd64 e arm64 (~2 min per immagine).
- Il manifest registra `UNITOTEM_PARTCLONE_IMG_FORMAT`; il payload lo confronta col proprio
  `partclone.restore -v` e **aborta prima di toccare il disco** in caso di mismatch.

Nomi file `p<N>-<LABEL>.<fstype|dd>.pc.xz`, **solo caratteri `[A-Za-z0-9_.-]`** — esattamente il charset
che il parser già accetta (`unitotem-flash:148`), così l'hardening non va allentato.

| Partizione | fs | trattamento |
|---|---|---|
| p1 `EFI`/`FIRMWARE` | FAT32 | **file-level** (mount + copia), per non cancellare il fallback |
| amd64 p2 `BOOT`, p3 `ROOT` / arm64 p2 `ROOT` | ext4 | `partclone.extfs` |
| amd64 p5 `BIOS` (ef02) | — | `partclone.dd`, ~507 KiB, per avere **un solo** percorso di restore |
| `DATA` | ext4 | **mai trasferita**: preservata o `mkfs.ext4 -F -L DATA -O ^has_journal` |

`bootcode.bin` = primi 440 byte dell'immagine (lo stage MBR di GRUB i386-pc, **fuori** da ogni
partizione). Con `bootcode.bin` + lo stream ef02 + la tabella identica, un target BIOS diventa avviabile
**senza chroot e senza `grub-install`**.

Manifest: convenzione `UNITOTEM_*` di `deploy/lib.sh:107-116`, un blocco header + un blocco per
partizione separati da riga vuota. Header: `_PARTS_PROTO`, `_ARCH`, `_SET_NAME`, `_RAW_SIZE`,
`_MIN_DISK_BYTES`, `_TABLE_FILE`, `_BOOTCODE_FILE`, `_NPARTS`, `_DATA_PART`, `_HAS_ESP`, `_BOOTFS_PART`,
`_KERNEL_FILE`, `_INITRD_FILE`, `_PARTCLONE_IMG_FORMAT`, `_TOTAL_USED_BYTES`. Per partizione: `_PART`,
`_PART_LABEL`, `_PART_FSTYPE`, `_PART_CLONER`, `_PART_ACTION` (`restore|filecopy|data|raw`),
`_PART_START`, `_PART_SECTORS`, `_PART_USED_BYTES` (**vedi §7.3: è il campo che conta**),
`_PART_STREAM_FILE`, `_PART_STREAM_BYTES`, `_PART_STREAM_SHA256`, `_PART_COMP`.

Generazione: `partclone.<cloner> -c -s "${LOOP}p${N}" -o - | xz -T0 -9 --check=sha256`. Il
`--check=sha256` fa verificare l'integrità a `unxz` sul target: un troncamento fallisce
**rumorosamente**, non in silenzio.

### 4.2 Controllo via SSH, dati via netcat — non un protocollo inventato da zero

Domanda posta esplicitamente: è davvero necessario inventare un protocollo? Cosa fa Clonezilla?
**Verificato, non assunto**: ho controllato il meccanismo di rete di Clonezilla (`ocs-onthefly`,
`ocs-live-netcfg`, l'integrazione DRBL — codice sorgente su `stevenshiau/clonezilla`). La sua modalità
"clone via rete" non ha un protocollo di controllo formale a sé stante: avvia due macchine come client
DRBL/PXE in un ambiente già di per sé condiviso/fidato, e per il caso punto-a-punto più semplice incanala
lo stream di `partclone.imagefile` **direttamente dentro una sessione SSH già autenticata** — SSH stessa
fa da canale di controllo (l'invocazione del comando remoto) e da trasporto. Non esiste quindi uno
standard esterno con la forma esatta richiesta (controllo a righe + dati netcat puri), ma il principio di
Clonezilla — **non autenticare/parsare da zero quando SSH è già disponibile** — si applica direttamente:

- **Canale di controllo = SSH**, con `dropbear-bin` nel payload (§2.3) invece di un socket TCP grezzo con
  una grammatica `KEY=VALUE` scritta da zero. L'host esegue comandi sul target
  (`ssh_t "unitotem-ota-engine <sottocomando> <argomenti>"`, stesso helper già in `deploy/lib.sh:68-72`
  usato per tutto il resto): **è il comando stesso a dire quale partizione sta arrivando**, e l'esito
  arriva come exit code + stdout della sessione ssh — niente parser da irrobustire contro un canale non
  autenticato, perché SSH lo autentica già.
- **Canale dati = netcat puro**, esattamente come richiesto: per ogni partizione, una connessione TCP
  dedicata, delimitata da EOF, nessun framing. Motivo per **non** mettere anche i dati dentro SSH: la
  cifratura di SSH ha un costo di CPU non trascurabile su un Pi senza accelerazione AES hardware
  affidabile per gigabyte di traffico continuo, mentre il contenuto (blocchi filesystem) non è segreto —
  il segreto (§3) viaggia solo sul canale di controllo, dove il volume è irrilevante.
- **Chiave host effimera, non condivisa fra i dispositivi.** Punto di sicurezza da correggere rispetto a
  un uso "di default" di `dropbear-initramfs`: quel pacchetto normalmente genera la chiave host **al
  momento della build dell'initrd** e la incorpora staticamente — dato che qui un solo initrd viene
  spedito dentro **ogni** immagine UniTotem, userebbe la **stessa** chiave su tutti i dispositivi, un
  vero regresso di sicurezza (chiunque estragga la chiave da un'immagine pubblica potrebbe impersonare il
  fallback di qualunque altro totem). Il nostro `init-premount` genera invece la chiave **ad ogni avvio**
  con `dropbearkey -t ed25519` in un tmpfs, mai persistita: ogni sessione OTA è TOFU (trust-on-first-use)
  proprio come un normale primo collegamento SSH, e l'impronta viene mostrata sulla schermata whiptail
  per conferma visiva quando c'è un operatore davanti allo schermo.
- **Direzione**: se l'host conosce l'indirizzo del target (caso comune: `remote-deploy.sh deploy
  user@host`), l'host si collega **in** al dropbear del target, esattamente come fa oggi con SSH per
  tutto il resto. Se il target è in modalità fallback con indirizzo sconosciuto all'host (DHCP,
  recupero), il target apre un tunnel inverso (`ssh -R <porta_host>:localhost:<porta_dropbear_locale>
  <host>`) verso l'host memorizzato in `unitotem-ota.conf`: pattern collaudato, non nuovo, lo stesso che
  usano gli strumenti di supporto remoto. Se anche l'host è sconosciuto, il fallback resta in ascolto
  locale e mostra IP+porta+impronta sulla schermata whiptail per un collegamento manuale
  (`remote-deploy.sh recover`).

Cosa **sparisce** rispetto alla bozza precedente: `deploy/session.sh` (macchina a stati custom),
`deploy/ota-protocol.md` come grammatica normativa (resta solo come elenco dei sottocomandi
`unitotem-ota-engine`, breve), `socat`/`ss` sull'host per il canale di controllo (restano solo per
predisporre il listener del canale **dati**), tutta la whitelist/charset-hardening del parser
`read_manifest_lines` applicata al controllo (resta per leggere **file locali**: `unitotem-ota.conf`,
`unitotem-ota.state`, il manifest — dove ha senso, contro input non fidato da rete no).

**Cosa resta invariato dalla richiesta originale**: due connessioni, la prima dice quale partizione sta
arrivando, la seconda è netcat puro per i dati. Cambia solo *come* è fatta la prima — un trasporto già
esistente e già hardenizzato nel codice, non uno nuovo.

**Negoziazione DATA** (via il comando SSH `unitotem-ota-engine probe`, non più un blocco `HELLO`):
`HAVE_DATA=1` solo se sul disco scelto esiste, allo start sector previsto, una partizione il cui
superblocco ext4 si legge (`dumpe2fs -h`); `HAVE_UNITOTEM=1` se esiste anche una ROOT con `/etc/kiosk`.
Sistema **già UniTotem** → tabella intatta, DATA preservata; sistema **nuovo o layout diverso** → tabella
ricreata, DATA formattata. `--wipe-data` forza il formato in ogni caso.

**Abort dipendente dalla fase** — il punto che regge la garanzia di fallback:
- **prima** della scrittura della tabella: rollback completo e reboot sul sistema precedente
  (comportamento di `fail()`, `unitotem-flash:88-105`, riusato);
- **dopo la barriera di fine stage 1**: il fallback è già avviabile e default, quindi si **riavvia sul
  fallback**, che richiamerà casa e riprenderà dallo stage 2 — la barriera stessa è il codice di uscita
  della sessione ssh `unitotem-ota-engine stage1` (ritorna 0 solo a `sync` avvenuto e verifica passata:
  niente messaggio separato da inventare, l'esito sincrono di un comando ssh è già un barrier affidabile);
- **fra i due**: mai riavviare su un disco scritto a metà — si entra nella console di fallback in RAM.

---

## 5. La sequenza a due stage

**Stage 1 — installazione del fallback (breve, ~10 MB oltre a quanto già residente, secondi)**
1. Il payload gira sul target (kernel+initrd spinti via SSH per un target legacy, oppure il fallback già
   residente per un target preparato — entrambi ora invocabili con `ssh_t`, dato che il fallback stesso
   parla SSH).
2. `ssh_t unitotem-ota-engine probe` risolve il disco (`resolve_disk`, riusato) e classifica: nuovo / già
   UniTotem.
3. Se nuovo: `ssh_t unitotem-ota-engine restore-table` scrive la tabella da `layout.sfdisk`, con
   `last-lba:` **rimosso** e `size=` di DATA **ricalcolato** (§7.4).
4. `mkfs.fat -F32` sulla partizione di boot (o mount di quella esistente).
5. Copia di `recovery-vmlinuz` + `recovery-initrd.img` + `recovery.sha256` sulla FAT, `sync`.
6. **Verifica sha256 dei file appena scritti rileggendoli dal disco**, non dalla cache.
7. Bootloader configurato con il **fallback come default**:
   - arm64: `config.txt` → `kernel=recovery8.img`, `initramfs recovery-initrd.img followkernel`
   - amd64 UEFI: `grub-install --removable` + `grub.cfg` con la voce recovery come default; voce
     `efibootmgr` best-effort
   - amd64 BIOS: `bootcode.bin` nei primi 440 byte **dopo** la tabella (libfdisk azzera il boot code del
     MBR protettivo), stream ef02, `grub.cfg`
8. Scrittura di `unitotem-ota.conf` (§3) e `unitotem-ota.state` con `STAGE=1 DONE`.
9. `sync`. Il comando ssh `stage1` ritorna 0: **da qui ogni perdita di alimentazione riavvia sul
   fallback, che riprende l'OTA.**

**Stage 2 — immagine UniTotem reale**
10. Restore di ROOT (e BOOT su amd64) con partclone, letto dal canale dati netcat.
11. Popolamento **file-level** della FAT di boot con kernel/initrd/dtb/blob del sistema reale, **senza
    toccare i file del fallback**.
12. DATA: preservata (default) o `mkfs`; migrazione dell'overlay `/etc` (§7.2, con precedenza sempre
    all'`/etc` della nuova immagine).
13. Verifica: `fsck` pulito su ogni partizione ripristinata, label attese presenti, **sha256 di
    `kernel8.img`/`initramfs8` riletti dal disco**.
14. Il sistema reale viene messo in **avvio di prova**, il default resta il fallback:
    - amd64: voce one-shot GRUB (`grub-reboot`), semantica già usata e commentata a
      `remote-deploy.sh:289-296` (prefisso `99_`)
    - arm64 Pi 4 EEPROM 2021+/Pi 5: `tryboot.txt` + `systemctl reboot "0 tryboot"`
    - arm64 senza tryboot (Pi 3, Pi 4 pre-2021, firmware datato): **verificato via il meccanismo di PINN**
      (successore attivo di NOOBS — vedi riquadro sotto) — `autoboot.txt` con `boot_partition=` per
      selezionare quale set di `config.txt`/`cmdline.txt` avviare, letto direttamente da `bootcode.bin`
      **prima** che qualunque kernel Linux giri, quindi disponibile anche su firmware molto vecchio.
      `config.txt` passa al sistema reale **solo dopo** la verifica sha256 del passo 13.
15. Reboot.
16. Il sistema reale si avvia → `unitotem-boot-ok.service` (`After=multi-user.target`, `Type=oneshot`)
    scrive `BOOT_OK` in `unitotem-ota.state` e **promuove il sistema reale a default**.
17. Se non conferma → il reboot successivo torna sul fallback, che richiama casa.

> **Riquadro — PINN/NOOBS, verificato.** PINN (fork attivamente mantenuto di NOOBS) seleziona quale OS
> avviare tramite `autoboot.txt` nella partizione RECOVERY, letto da `bootcode.bin` con la variabile
> `boot_partition=<N>`: questo sceglie quale partizione fornisce `config.txt`/`cmdline.txt` all'avvio
> successivo, con tutte le condizionali (incluse quelle su GPIO) che `bootcode.bin` supporta nativamente.
> È un meccanismo di **selezione a livello firmware**, non di `Linux`, quindi funziona anche su Pi privi
> di `tryboot` (Pi 3, Pi Zero, Pi 4 con EEPROM pre-2021). Non lo adottiamo come sostituto di `tryboot` —
> il nostro schema a due file (fallback sempre presente + sistema reale) è più semplice del multi-OS di
> PINN — ma il principio (**scelta prima del kernel, non dopo**) è esattamente perché la garanzia di
> fallback sui firmware legacy non può passare dal cambio di `config.txt` una volta soltanto e basta:
> deve restare verificabile (sha256, passo 13) prima di essere reso effettivo.

---

## 6. Fallback: come lo si raggiunge, sempre

Quattro livelli indipendenti, ognuno sufficiente da solo.

1. **Default di boot** = fallback, dallo stage 1 fino alla conferma del passo 16. Copre power cut, crash
   e immagine difettosa durante tutto il deploy.
2. **Validazione pre-mount** nell'initramfs del sistema reale (`zz-unitotem-ota` in `init-premount`):
   `blkid -L ROOT` risolve? `e2fsck -fp` < 4 (riusando la logica bitmask di `run_e2fsck`,
   `unitotem-flash:56-60`)? Se no → modalità OTA.
3. **Validazione post-mount** (`zz-unitotem-verify` in `local-bottom`): `[ -x $rootmnt/sbin/init ]`,
   `[ -d $rootmnt/etc/kiosk ]`. Va ordinata **prima** di `overlayfs-hook.sh`, che è in `init-bottom`.
4. **Contatore di boot** su `unitotem-ota.state`, azzerato da `unitotem-boot-ok.service`: tre boot
   consecutivi non azzerati → fallback.

Perché i livelli 2/3 richiedono che **anche l'initramfs del sistema reale sia capace di OTA** (stessi
pacchetti/hook di §2.3, installati anche da `stage2-configure.sh`): non è una duplicazione del fallback,
è ciò che rende recuperabile "kernel e initrd sani, root distrutta" senza dipendere dal cambio di
`config.txt`.

**Armare da un sistema in esecuzione**: `/usr/sbin/unitotem-ota-arm`, scrive un flag file
`unitotem-ota.request` sulla FAT di boot e riavvia. **Autocancellante, in questo ordine esatto**: mount
ro → stat → remount rw → leggi in memoria → `rm` → `sync` → umount → *solo allora* rete e azione. Un
crash in qualunque momento dopo `rm` porta a un boot normale, **mai a un loop**.

**Via di fuga manuale su amd64**: `/etc/grub.d/45_unitotem_ota` permanente, più `GRUB_TIMEOUT=1` +
`GRUB_TIMEOUT_STYLE=hidden` in `kiosk/files/grub-default` (oggi `GRUB_TIMEOUT=0`, menu irraggiungibile).
**Sul Pi non esiste equivalente diretto**: la garanzia sono i quattro livelli sopra, rinforzati dal
principio PINN del riquadro in §5.

**Nessuna modifica al firewall**: tutto il traffico OTA (SSH incluso) è nell'initramfs, prima che
`iptables-firewall.service` esista, e `kiosk/files/iptables-firewall.sh:12` ha `OUTPUT ACCEPT`.

---

## 7. Rischi e vincoli

### 7.1 Sequenza obbligata
1. **Verificare che amd64 BIOS si avvii da un'immagine stage3**, prima di scrivere codice OTA per BIOS.
   `kiosk/stage3-image.sh:117-120` e la ef02 non sono **mai** stati testati. Costo: un dominio libvirt
   senza `firmware='efi'`.
2. Fix boot arm64 + nuovo layout + rebuild stage1/2/3 di **entrambe** le arch (con le correzioni di §2.2),
   **prima** di generare qualunque parts set.
3. Verifica di §11.1 (loopback) su entrambe le arch, poi §11.2/11.3 (VM), poi **una sola volta** §11.4
   (Pi reale).
4. Cancellare la vecchia build del flasher **solo dopo** che il fallback è verificato avviabile su
   entrambe le arch in VM/loopback.

### 7.2 DATA preservata × il design a overlay — l'/etc della nuova immagine ha SEMPRE precedenza
`overlayfs-hook.sh:20-32` usa `/mnt/data/upper/etc` come **upperdir di `/etc`**. Punto rafforzato in
questa revisione: preservare DATA **non deve mai** poter rendere un OTA inutilizzabile per mismatch di
configurazione. Regola esplicita: **in caso di conflitto vince sempre `/etc` della nuova immagine.** La
gestione (attiva di default, `--keep-etc-overlay` per disattivarla):
1. il **filesystem** DATA resta intatto, UUID invariato (asset e tutto fuori da `upper/`/`work/`
   sopravvive verbatim);
2. `upper/etc` e `work/etc` **vecchi** vengono spostati interi in `/mnt/data/history/<timestamp>/` — non
   restano mai come overlay attivo sul sistema nuovo;
3. **solo dopo**, viene reimportata una whitelist **additiva** da `/etc/unitotem/ota-preserve.list` del
   rootfs **nuovo** (mai del vecchio: la lista evolve con l'immagine, non porta con sé voci obsolete).
   Lista iniziale conservativa, solo valori operativi mai strutturali: `/etc/hostname`, `/etc/hosts`,
   `/etc/machine-id`, `/etc/ssh/ssh_host_*`, `/etc/NetworkManager/system-connections/*`,
   `/etc/netplan/*`, `/etc/localtime`, `/etc/timezone`, `/etc/vconsole.conf`, `/etc/default/keyboard`,
   `/etc/unitotem*/**`. **Mai** file strutturali (`/etc/fstab`, unit systemd, config di
   `initramfs-tools`, PAM): questi vengono sempre dalla nuova immagine, punto, per costruzione (non sono
   nella whitelist e la migrazione è additiva, mai sostitutiva);
4. la lista porta un numero di formato (`OTA_PRESERVE_LIST_VERSION=`); se il formato letto da DATA è più
   recente di quello che il rootfs nuovo capisce, quella voce viene **saltata con avviso**, mai applicata
   alla cieca;
5. `upper/root` lasciato intatto ma registrato nel file di stato;
6. `--wipe-data` salta tutto e fa `mkfs`.

### 7.3 partclone su partizione di dimensione diversa — verificato, non assunto
Controllo diretto di `partclone.restore --help`/man locale e del sorgente: `-C`/`--no_check` esiste
appunto per "Don't check device size and free space", e il messaggio d'errore che scatta senza `-C` è
letteralmente *"Target partition size(...) is smaller than source(...). Use option -C to disable size
checking"* — cioè per default partclone confronta la dimensione **nominale** della partizione (letta con
`BLKGETSIZE64`), non i blocchi realmente usati. Il maintainer (Steven Shiau, thread SourceForge) conferma
lo stesso: di default niente restore su una partizione più piccola, ma **con `-C`, se i blocchi usati
rientrano nel target, il restore è corretto** — è esattamente l'osservazione dell'utente (dati non
frammentati verso la fine, nessun problema dei "byte finali").

Applicazione: il design **calcola da solo**, prima di invocare partclone, se `_PART_USED_BYTES` (+ un
margine, es. +20% o +256 MiB) sta dentro la partizione target realmente disponibile sul disco; se sì,
invoca **deliberatamente** `partclone.restore -C`, bypassando il controllo più grezzo (e più conservativo
del necessario) di partclone basato sulla sola dimensione nominale. Questo importa soprattutto per la
compatibilità futura: un'immagine più recente con `ROOT_SIZE` ridotto rispetto a un parts-set più vecchio
resta restaurabile su un target già scritto con il layout precedente, purché i dati ci stiano — non solo
per byte-identical (§7.4 resta comunque la via primaria e più sicura quando si ricrea la tabella da zero).
Target **più grande**: sempre sicuro, nessun flag necessario (`resize2fs`/nulla per FAT assorbe la coda).
**Mai** passare `-C` senza aver prima verificato `_PART_USED_BYTES` — l'uso indiscriminato è quello
davvero pericoloso, non `-C` in sé.

### 7.4 Dettagli del restore sfdisk che fanno male se dimenticati
- **Togliere `last-lba:`** dal dump: lasciandolo, su una SD da 32 GiB l'area utile resta ferma agli 11 GiB
  della sorgente.
- **Ricalcolare `size=` di DATA** come `blockdev --getsz - 33 - data_start`, non affidarsi a "size omesso
  = riempi": su amd64 la partizione col numero più alto è p5 (ef02, settori 34-2047), non DATA.
- `sfdisk --force` (una partizione che inizia al settore 34 genera warning di allineamento) e
  `--no-reread`, poi `partx -u` + `udevadm settle` (idioma già a `unitotem-flash:586-588`).
- Tabella **prima** di `bootcode.bin`.
- Questo sostituisce interamente `post_flash_expand` (`unitotem-flash:425-457`).

### 7.5 Indirizzamento per label × restore parziale
Con tabella e partizioni ripristinate identiche le label tornano esatte: `fstab-amd64`/`-arm64` e il
`blkid -L DATA` di `overlayfs-hook.sh` continuano a funzionare. Due residui: il payload deve **smettere**
di usare `blkid -L` per il proprio indirizzamento (`unitotem-flash:464`, `470-472`, `593`) e usare
`pdev_target`; un **secondo disco** con label ROOT/DATA può far avviare la root sbagliata — `do_probe`
deve scansionare tutti i dischi e avvisare rumorosamente.

### 7.6 `set -Eeuo pipefail` × il codice di orchestrazione
`read -t` scaduti, `kill -0`, poll di `ss` e guardie `[ cond ]` restituiscono non-zero come esito
**normale**: ognuno va `|| gestito` o dentro un `if`. È la classe di bug già documentata due volte nel
codice (`unitotem-flash:74-79`, `remote-deploy.sh:493-495`): checklist di review obbligatoria, anche se
lo spostamento a SSH per il controllo (§4.2) elimina una parte della superficie (niente più loop di
`read -u` su un socket grezzo per il controllo — resta per il canale dati e per i poll del listener).

### 7.7 Aspettative oneste sul guadagno
La dimensione sul filo cambia poco (~700-800 MB contro i 779 MB attuali: l'xz già annullava gli zeri).
**Il guadagno è tutto nei byte scritti e decompressi: ~12 GiB → ~3.0 GiB**, cioè su SD di un Pi 4 grosso
modo 10-12 min → 3-4 min, più pochi secondi per lo stage 1. Se la banda conterà,
`UNITOTEM_PART_COMP` già consente `zstd -19 --long` per-stream senza impatto sul formato.

---

## 8. Pacchetti e hook

### `kiosk/stage1-packages.sh` (blocco base, entrambe le arch)
| pacchetto | perché | dimensione |
|---|---|---|
| `partclone` | motore di restore, condiviso da fallback e sistema reale | ~1.9 MB |
| `gdisk`, `parted` | **tenuti** per diagnosi/riparazione manuale (decisione esplicita, non sul percorso automatico) | ~1.5 MB |
| `pv` | metering byte per il gauge | ~0.1 MB |
| `netcat-traditional` | canale **dati** (bulk, EOF-delimited) | ~0.07 MB |
| `dropbear-bin` | canale di **controllo** SSH, chiave rigenerata ad ogni avvio (§4.2) | ~0.13 MB |
| `wpasupplicant` | riconnessione WiFi del fallback | ~4 MB |

**≈ 7.7 MB su 2.93 GiB di rootfs.** Già presenti, verificati: `whiptail` + `libnewt` + `libslang`,
`/lib/terminfo/{l/linux,v/vt100,v/vt220}`, `xz-utils`, `e2fsprogs`, `dosfstools`, `util-linux`,
`firmware-brcm80211`, `initramfs-tools` (che porta `busybox-initramfs` come dipendenza **dura e
inevitabile** — vedi §2.3, va gestita con il force-copy, non evitata). **Non aggiunti**: `dialog`,
`zstd`, `udhcpc`, `dropbear-initramfs` completo (si usa solo `dropbear-bin` + un hook scritto da noi, per
controllare la generazione della chiave — §4.2).

### Hook `/etc/initramfs-tools/hooks/unitotem-ota`
`copy_exec` di: `bash`, `partclone.{extfs,fat,dd,restore,info}`, `sgdisk`, `parted`, `sfdisk`, `partx`,
`blockdev`, `blkid`, `e2fsck`, `resize2fs`, `dumpe2fs`, `mke2fs`, `e2label`, `mkfs.fat`, `fatlabel`,
`xz`/`unxz`, `pv`, `whiptail`, `nc`, `dropbear`, `dropbearkey`, `dbclient`, `wpa_supplicant`,
`wpa_passphrase`, `sha256sum`, `base64`, `awk`, `cut`; su amd64 anche `efibootmgr`, `grub-install` +
`manual_add_modules efivarfs` + le due directory `/usr/lib/grub/*`. `manual_add_modules vfat
nls_iso8859-1 nls_cp437` + i moduli WiFi Broadcom.
Trappole: `nc` è un symlink di alternatives (copiare il binario reale e creare il symlink a mano); la
collisione **permanente** con `busybox-initramfs`/klibc e il ciclo di `cp -a` forzato (§2.3); terminfo e
`TERM` (§2.3); generazione della chiave dropbear **a runtime**, non al momento della build (§4.2) — lo
script `init-premount` chiama `dropbearkey -t ed25519 -f /run/dropbear_ed25519_host_key` prima di
avviare `dropbear`, mai un passo dell'hook stesso.

### Progresso: `whiptail --gauge` basta
whiptail supporta il **protocollo XXX**, quindi il testo si riscrive ad ogni aggiornamento. Non disegna
due barre, quindi: barra = progresso **totale** (byte decompressi cumulativi / `_TOTAL_USED_BYTES`);
testo riscritto = dettaglio per partizione (`Stage 2 — partizione 3/4: ROOT (ext4, 2.93 GiB utili)` +
byte/percentuale/velocità/ETA). Un solo processo gauge per l'intera sessione, alimentato via FIFO. I byte
arrivano da `pv -n -s <used_bytes>` inserito fra `unxz` e `partclone.restore`.

---

## 9. Modifiche file per file

### Creare
| path | contenuto |
|---|---|
| `kiosk/stage1-recovery-initrd.sh` | genera kernel+initrd di fallback da stage1 (§2.1), sostituisce il vecchio `deploy/flasher-image.sh` |
| `deploy/parts-lib.sh` | generatore parts set, `make_parts <device> <outdir> <arch>` |
| `deploy/make-parts.sh` | wrapper host: `.img`/`.img.xz` → scratch sparse → `losetup -r --partscan` → docker |
| `deploy/make-parts-image.sh` | worker in-container |
| `Dockerfile.parts` | bookworm + partclone/xz/util-linux/e2fsprogs/dosfstools, **senza qemu** |
| `deploy/ota-engine.sh` | motore condiviso: gira nel fallback **e** nell'initramfs del sistema reale; sottocomandi invocati via ssh (`probe`, `restore-table`, `restore-part`, `stage1`, `promote`, ...) |
| `deploy/ota-commands.md` | elenco breve dei sottocomandi `unitotem-ota-engine` e del loro output — non più una grammatica di wire-protocol da difendere, solo una reference |
| `deploy/net-probe.sh` | sonda di rete host-side (§3) |
| `kiosk/files/unitotem-ota-arm` | → `/usr/sbin/unitotem-ota-arm` |
| `kiosk/files/unitotem-boot-ok.service` | conferma avvio, promuove il default |
| `kiosk/files/ota-preserve.list` | → `/etc/unitotem/ota-preserve.list`, con `OTA_PRESERVE_LIST_VERSION=` (§7.2) |
| `kiosk/files/rpi-firmware-sync` | → `/etc/kernel/postinst.d/zz-unitotem-rpi-firmware` (§10) |
| `kiosk/files/grub-ota-entry` | → `/etc/grub.d/45_unitotem_ota` |
| `kiosk/files/ota-hook` + `ota-verify` | i due script initramfs del sistema reale (§6 livelli 2-3), stesso hook di §8 |

### Eliminare
`deploy/flasher/unitotem-flash` (607 righe), `deploy/flasher/hook`, `deploy/flasher/udhcpc-script`,
`deploy/flasher-image.sh`, `deploy/build-flasher.sh`, `Dockerfile.flasher`. Netto ≈ **−900 righe**.

### Riuso da `unitotem-flash` → `deploy/ota-engine.sh`
- **Verbatim**: `log`/`warn` (26-27), `cmdline_get` (31-39), `pdev_target` (41-46), `partnum_of` (50),
  `run_e2fsck` (56-60), `resolve_disk` (108-132), `read_manifest_lines` (139-153, riusato per i **file
  locali**, non più per un canale di rete non fidato), `rollback_rpi` (68-86), `fail` + trap `ERR`
  (88-106) con l'estensione per fase, `mount_new_system`/`umount_new_system` (462-483) via `pdev_target`,
  `install_bootloader_uefi` (485-511), la sequenza
  `sync`/`blockdev --flushbufs`/`partprobe`/`partx -u`/`udevadm settle` (584-588).
- **Eliminati**: `do_part_stage` (202-308), il branch `part` di `main` (570-573), `write_image_net`
  (376-406), `write_image_direct` (408-417), `post_flash_expand` (425-457), `pv_gauge` (366-374, riscritto
  come sotto), `install_bootloader_bios` (513-524).
- **Riscritti**: `setup_network` (316-338) → `configure_networking()` + WiFi; `do_net_prepare`/
  `write_image_net` → `ssh`-command dispatch + pull dal canale dati netcat; `do_ram` (168-191) →
  `src_local`; `decompress_pipe` (155-161) → per-stream via `_PART_COMP`.
- **Nuovi**: sottocomandi `probe`/`restore-table`/`write-bootcode`/`install-recovery`/`set-default-
  recovery`/`restore-part`/`populate-bootfs`/`set-trial-boot`/`promote-default` (dispatcher invocato via
  ssh, un sottocomando = un comando del "controllo" di §4.2); `gauge_start`/`gauge_feed`/`gauge_stop`;
  `migrate_etc_overlay` (con precedenza sempre a `/etc` nuovo, §7.2); `ota_console` (fallback + dial-home
  via `ssh -R`); `bootcount_*`; `net_apply`/`wifi_up`; `state_read`/`state_write`; `dropbear_ephemeral_key`.
- Il motore **deve essere eseguibile fuori da un initramfs** (`--target-disk`, sottocomandi invocabili
  singolarmente da riga di comando): è ciò che rende possibile il test di loopback host-side di §11.1.

### Cosa sopravvive di `remote-deploy.sh` (~65 %)
- **Sopravvive**: `do_probe` (60-142) esteso con sonda di rete, "è già un UniTotem", DATA esistente +
  UUID, label duplicate su altri dischi; `print_probe` (144-159); `select_disk` (165-204); `push_flasher_
  kernel` (256-266) ripuntato sui file di recovery; `arm_grub` (276-321) verbatim; `arm_rpi` (323-344) per
  i Pi senza tryboot/PINN; `do_reboot` (346-349); `cmd_disarm` (486-512); la coda di attesa SSH di
  `cmd_deploy` (462-480), che legge `unitotem-ota.state` invece dell'euristica `/etc/kiosk` a 475.
- **Muore**: `decide_mode` (209-229) → `pick_arming` + `pick_source`; i branch `part`/`net` di
  `build_flash_cmdline` (243-252); `push_deploy_payload` (268-274) → spinge una *directory*; `net_send`
  (354-386) → sostituito da chiamate `ssh_t`/`scp_t` dirette all'engine, dato che il controllo ora è SSH;
  il flag `--connect-back` e `OPT_MODE=part`.

Nuova CLI:
```
deploy/make-parts.sh      [--arch A] [--image PATH] [--out DIR] [--keep-scratch]
deploy/remote-deploy.sh probe    user@host
deploy/remote-deploy.sh deploy  user@host [--parts DIR] [--disk BYID] [--stage 1|2|all]
                                [--source net|local] [--arming auto|push|flag|tryboot|pinn]
                                [--port N] [--wipe-data] [--keep-etc-overlay]
                                [--net auto|dhcp|static] [--console STR] [--debug] [--yes]
deploy/remote-deploy.sh recover HOST[:PORT] [--parts DIR] ...   # host si collega a un target in fallback
deploy/remote-deploy.sh serve   [--parts DIR] ...               # attende un target che richiama casa (ssh -R)
deploy/remote-deploy.sh disarm  user@host
```

### Modificare
- `kiosk/common.sh:15-19` — nuove dimensioni (§1); aggiungere il controllo di cache stage1 (§2.1).
- `kiosk/stage1-packages.sh` — i sei pacchetti di §8; **nessuna** asserzione "no busybox" (§2.3: è
  inevitabile, l'asserzione andrebbe sempre in errore).
- `kiosk/stage1-recovery-initrd.sh` (nuovo) — `mkinitramfs` con `MODULES=dep`+`MODULES_EXTRA` mirato
  (§2.2) sulla rootfs di stage1, con l'hook OTA già installato.
- `kiosk/stage2-configure.sh` — installa `ota-engine.sh`, hook, i due script initramfs del sistema reale,
  `unitotem-ota-arm`, `unitotem-boot-ok.service`, `ota-preserve.list`, `45_unitotem_ota`,
  `rpi-firmware-sync`; popolazione FIRMWARE arm64 **dopo** `update-initramfs -u -k all`.
- `kiosk/files/config.txt` — `kernel=kernel8.img`, `initramfs initramfs8 followkernel`; commentare
  `dtoverlay=vc4-kms-v3d`/`-pi5` con rimando al follow-up.
- `kiosk/files/grub-default` — `GRUB_TIMEOUT=1`, `GRUB_TIMEOUT_STYLE=hidden`.
- `kiosk/stage3-image.sh` — nuovo layout, blocco `MAKE_PARTS` opzionale, **asserzioni di avviabilità** di
  §10.
- `Dockerfile.kiosk` — aggiungere `partclone`.
- `deploy/lib.sh` — ritirare `build_deploy_manifest` (86-117) e i `layout_*` hardcoded (61-63) in favore
  di `parts.manifest`; tenere `pdev`, `size_to_bytes`, `bytes_human`, `SSH_OPTS`, `ssh_t`, `scp_t`;
  aggiungere `socat_listen`/`wait_port_bound` (solo per il canale **dati**); `require_cmd` guadagna
  `socat`/`ss` (dati) e `ssh` resta come già.
- `debian-kiosk.md` §28 — riscrivere; `README.md` — nota breve.

---

## 10. Avviabilità dell'immagine Pi — gate espliciti

Richiesta esplicita ("non possiamo permetterci errori"), quindi trattata come requisito verificabile.

**Asserzioni di build** in `kiosk/stage3-image.sh`, che **fanno fallire la build** se non passano:
1. `FIRMWARE/kernel8.img` esiste e i byte 0x38-0x3B sono `ARMd` (magic Image arm64) — il controllo che
   avrebbe intercettato il bug attuale;
2. `FIRMWARE/bcm2711-rpi-4-b.dtb` esiste e `dtc -I dtb -O dts` lo parsa;
3. `FIRMWARE/initramfs8` esiste, non è vuoto, e `lsinitramfs` elenca `sbin/init`;
4. `config.txt` contiene `kernel=` e `initramfs ... followkernel`, e **nessun** `dtoverlay=` che punti a
   un file assente in `overlays/`;
5. `FIRMWARE/recovery8.img` e `recovery-initrd.img` esistono e i loro sha256 corrispondono a
   `recovery.sha256`;
6. spazio libero su FIRMWARE ≥ 64 MiB dopo tutte le copie;
7. `fsck.vfat -n` pulito sulla FIRMWARE e `fsck.ext4 -fn` pulito su ROOT/DATA.

**Hook di manutenzione**: `/etc/kernel/postinst.d/zz-unitotem-rpi-firmware` ripete le copie
kernel/initrd/dtb ad ogni aggiornamento di kernel — altrimenti il primo `kiosk-update`
(`kiosk/files/kiosk-update:27`, `update-initramfs -u -k all`) riporterebbe il Pi nella condizione attuale.

**Gate su hardware reale, prima di qualunque deploy**: scrivere l'immagine appena costruita su un
supporto, avviare il Pi 4 con seriale collegata, e confermare kernel caricato → root montata → login.
Solo dopo questo gate si passa ai test OTA.

### Follow-up separato (non parte di questo lavoro)
Passare arm64 a `linux-image-rpi-v8` da `archive.raspberrypi.org` (già in `stage1-packages.sh:28`): fa
matchare `z50-raspi-firmware` nativamente, porta `overlays/` e restituisce `dtoverlay=vc4-kms-v3d` e il
KMS reale. **Fino ad allora l'immagine Pi non ha KMS**.

---

## 11. Verifica

### 11.1 Loopback host-side — il ciclo primario, senza VM e senza Pi
Da far funzionare **per primo**: prende la maggior parte dei bug in pochi minuti, a rischio zero.
1. `make-parts.sh` sull'immagine ricostruita. Verificare: chiavi del manifest complete e charset-clean;
   `partclone.info` su ogni stream riporta fs e blocchi usati attesi; `sha256sum -c SHA256SUMS`;
   `layout.sfdisk` fa round-trip.
2. **Stage 1 + stage 2 completi su loop device**: `ota-engine.sh --target-disk /dev/loopN --source local`
   fuori da qualunque initramfs, sottocomando per sottocomando (`probe`, `restore-table`, `stage1`,
   `restore-part N` per ognuna, `promote-default`). Poi: `sfdisk --dump` come atteso; `fsck.ext4 -fn` e
   `fsck.vfat -n` puliti; confronto `find -printf` + sha256 per file contro la sorgente; **verificare che
   dopo lo stage 2 i file del fallback siano ancora presenti e con sha256 corretto**. È il gate di
   correttezza.
3. **`partclone.restore -C` con `_PART_USED_BYTES` reale**: restore su una partizione target
   deliberatamente più piccola della sorgente ma più grande dei blocchi usati (§7.3) — verificare che
   funzioni e che il calcolo di sicurezza rifiuti quando non dovrebbe.
4. **Misura di velocità qui, non su hardware**: (2) contro un loop su un file immagine, leggendo i byte
   scritti da `/sys/block/<dev>/stat` campo 7 × 512, contro un baseline `dd` whole-disk. Il numero da
   riportare è **byte scritti** (wall clock secondario).
5. **Canale di controllo SSH**: sessione `dropbear` sul loop/VM con chiave rigenerata ad ogni avvio —
   verificare che due avvii consecutivi producano impronte diverse (conferma che non è baked-in), che il
   comando sbagliato/malformato dia errore pulito, che il canale **dati** rifiuti un byte invertito nello
   stream (deve fallire in `unxz`, non in silenzio).
6. **Sonda di rete** (`net-probe.sh`) contro il Pi reale in tutte le combinazioni: DHCP cablato, statico
   cablato, DHCP WiFi, statico WiFi.

### 11.2 amd64 UEFI — `work/vm-test/`
Sempre su un `overlay.qcow2` fresco sopra `kiosk-amd64.img` intatto.
- **Percorso preparato**: boot dell'immagine, `unitotem-ota-arm --host <ip>`, seguire il log seriale per
  stage 1 + stage 2, confermare la promozione del default e il contenuto di `unitotem-ota.state`.
- **Percorso non preparato**: `work/vm-test-oldsys2/oldsys.img` → push recovery, `arm_grub`, deploy.
- **Gauge whiptail**: verificare che disegni su console SPICE **e** degradi a testo su seriale; forzare un
  `TERM` sbagliato e confermare che scatti il fallback **per errore**, non per binario assente.

### 11.3 amd64 BIOS — mai testato, farlo per primo
Nuovo dominio senza `firmware='efi'` (SeaBIOS).
- **Gate 0**: si avvia l'immagine stage3 così com'è?
- **Gate 1**: stage 1 su disco vuoto → il **fallback** si avvia da BIOS.
- **Gate 2**: stage 2 → il sistema reale si avvia **senza** `grub-install` sul target.
- **Gate 3**: confronto byte a byte di `dd bs=440 count=1` e della ef02 fra disco deployato e sorgente.

### 11.4 Raspberry Pi 4 — un solo passaggio su hardware reale, senza supporti di scorta

L'utente non dispone di una seconda SD/USB: la verifica è quindi strutturata per **non aver bisogno** di
un secondo supporto, spingendo tutto il rischio nei test di loopback/VM sopra (che usano lo stesso identico
codice e lo stesso identico artefatto arm64) e riducendo l'hardware reale a un unico passaggio a basso
rischio, con un checkpoint esplicito prima di reinserire la SD nel Raspberry Pi.

0. **Backup preventivo** (gratuito, la SD è già montata sull'host): `dd if=/dev/sdb of=work/sd-backup-
   pre-ota.img bs=4M status=progress` prima di qualunque scrittura — permette di tornare esattamente allo
   stato attuale con un `dd` inverso se qualcosa va storto, indipendentemente da tutto il resto.
1. **Tutti** i gate del §10 e i test §11.1 vanno eseguiti su **loop device**, non sulla SD, fino a
   convergenza completa — incluso il test "power cut a metà stage 2" (`kill -9` del processo che scrive,
   non `virsh destroy` perché qui non c'è VM, ma l'effetto su un file immagine è equivalente: scrittura
   interrotta a metà, poi si riprende la verifica da lì).
2. **Un solo write reale**: `dd` dell'immagine ricostruita e già verificata (via loop) sulla SD attuale
   (che è già la SD di produzione — non c'è alternativa), poi stage 1 + stage 2 completi eseguiti **con
   la SD ancora nel lettore USB dell'host**, non nel Pi: verificabile via loop/USB reader esattamente come
   il resto, senza mai dipendere dal Pi per la scrittura.
3. **Solo a questo punto**, con la SD già verificata bit-per-bit (fsck puliti, sha256 corretti, gate §10
   tutti verdi) fuori dal Pi, la si reinserisce nel Raspberry Pi per il primo avvio reale — l'unico
   momento in cui l'hardware del Pi entra nel giro, e solo per confermare che il firmware/bootloader
   effettivamente si comporta come atteso (cosa che un loop device sull'host non può testare: il firmware
   del Pi stesso).
4. **Segnale esplicito all'utente**: solo dopo il passo 3 confermato via SSH (`ssh root@<ip> "cat
   /etc/kiosk/*; systemctl is-active unitotem-boot-ok"` o equivalente) comunico che è sicuro considerare
   il test hardware concluso. Se qualcosa va storto al passo 3, si ripristina con il backup del passo 0
   (`dd` inverso) e si torna ai test di loopback per capire cosa il loop device non aveva catturato.
5. Il test di power-cut **reale** (staccare l'alimentazione del Pi a metà OTA) resta l'unico caso che
   richiede necessariamente hardware vero (nessun loop device riproduce un power cut fisico fedelmente) —
   va fatto **per ultimo**, dopo che tutto il resto ha già avuto successo, e solo se l'utente conferma di
   volerlo eseguire con la SD di produzione (in alternativa: acquisire una SD anche solo da pochi euro
   dedicata ai test, se in futuro se ne vuole fare un altro).

### 11.5 La garanzia di fallback
Testare i quattro livelli di §6 **separatamente**, su amd64-UEFI (VM, overlay usa-e-getta) e — per quanto
riproducibile senza hardware dedicato — via loop device per il Pi (§11.4 punto 1):

| guasto iniettato | livello che deve intercettarlo |
|---|---|
| power cut fra stage 1 e stage 2 | 1 — default = fallback |
| power cut a metà restore di ROOT | 1 |
| superblocco ROOT azzerato | 2 — `blkid`/`e2fsck` pre-mount |
| label ROOT cancellata | 2 |
| ext4 corrotto tanto che `e2fsck` ritorna ≥ 4 | 2 |
| `$rootmnt/sbin/init` cancellato | 3 — verify in `local-bottom` |
| `unitotem-boot-ok.service` mascherato ×3 | 4 — contatore di boot |
| flag file presente ma il payload crasha subito | autocancellazione: il secondo boot è normale, nessun loop |
| `initramfs8` del sistema reale troncato | verifica sha256 del passo 13: il default **non** deve cambiare |

Su amd64 confermare in più la via di fuga manuale: SHIFT/ESC → "UniTotem OTA recovery", sia UEFI sia BIOS.

### 11.6 Preservazione di DATA
Prima del deploy: scrivere `/mnt/data/SENTINEL`, impostare un hostname, aggiungere una connessione
NetworkManager, lasciare un file spurio in `/etc` (così finisce nell'upperdir). Registrare l'UUID. Dopo:
- deploy default su sistema già UniTotem → SENTINEL presente, UUID DATA **invariato**, hostname e
  connessione NM reimportati, file spurio spostato sotto `/mnt/data/history/<ts>/etc/` e **non** attivo;
- deploy su sistema nuovo → tabella ricreata, DATA formattata;
- `--wipe-data` → SENTINEL assente, UUID **cambiato**;
- `--keep-etc-overlay` → il file spurio ombreggia ancora `/etc` (unico caso in cui è permesso).

Verificare anche il caso negativo che il codice attuale sbaglia: eseguire una volta il deploy `dd`
whole-disk attuale e confermare che DATA venga distrutta, così il miglioramento è documentato e non
soltanto asserito.

---

## 12. Stato di avanzamento (2026-07-31)

**Fatto e verificato con esecuzione reale**, non solo lettura del codice:
- Entrambe le architetture buildate end-to-end (stage0→1→1b→2→3), tutte le asserzioni di avviabilità e
  fsck passate. amd64: entrambi i `grub-install` (UEFI removable + BIOS i386-pc) riusciti, verificato in
  VM (§11.2/11.3, boot pulito, `systemctl --failed` vuoto su UEFI e BIOS). arm64: boot-ability corrette
  (magic kernel, dtb parsabili, initramfs contiene `/init`), fault-injection sulla garanzia di fallback
  (§11.5, tutti e 4 i livelli) verificata su loop device.
- §11.1 (loopback restore) verificato **per entrambe le architetture**: amd64 storico, arm64 verificato
  in questa sessione con harness dedicato (`work/loopback-test/{run,inside}-arm64.sh`) — 50/50 controlli,
  inclusi `restore-table`/`restore-part`/`set-trial-boot rpi-tryboot`/`promote-default` mai testati prima.
- §11.4 (Pi reale) in stato avanzato: SD scritta e verificata bit-per-bit tramite l'harness di test
  (`work/loopback-test/run-real-sd.sh`, `deploy/ota-engine.sh` invocato direttamente, non via SSH), Pi
  riacceso più volte con successo. Console seriale funzionante (`console=ttyS1,115200` — **non**
  `serial0` né `ttyS0`, vedi memoria `pi-serial-console-ttys0`). Due bug reali trovati e fissati
  sull'hardware reale (dettagli in memoria `ota-redesign-project`):
  1. `ipconfig` (klibc) può bloccarsi ignorando il proprio `-t` (bug upstream noto, Debian #552554) →
     timeout esterno da 30s in `configure_networking_ota()` (`deploy/ota-engine.sh`).
  2. Le stesse chiamate di log interne di `configure_networking()` inquinavano lo stdout catturato da
     `myip=$(configure_networking_ota || true)` → redirette a `/dev/kmsg`.
  DHCP confermato funzionante (IP reale ottenuto, `<pi-host>`), dropbear confermato raggiungibile a
  livello di protocollo TCP/SSH.

**Bug noto, non bloccante, rimandato**: l'overlay DATA→`/etc`,`/root` di `kiosk/files/overlayfs-hook.sh`
non sopravvive allo `switch_root` (vedi memoria `overlayfs-switch-root-bug`). Non blocca l'OTA:
`migrate-etc-overlay` opera offline sul filesystem già montato, non dipende da questo meccanismo di boot.

**L'unico gap reale rimasto per chiudere §11.4/#15**: la sequenza OTA di produzione
(`deploy/remote-deploy.sh` → `ssh_t`/`ota_ssh`, entrambi con `BatchMode=yes`) non è mai stata eseguita
contro il Pi reale — solo l'harness di test (che chiama `ota-engine.sh` direttamente, bypassando SSH). Un
tentativo di connessione reale ha rivelato che il dropbear del fallback non ha alcuna chiave autorizzata:
vedi §13, è l'oggetto di questo piano.

### Ordine consigliato per i task rimanenti
1. §13 (provisioning della chiave SSH per il canale di controllo) — blocca tutto il resto.
2. Prima esecuzione reale di `deploy/remote-deploy.sh deploy` contro il Pi (§11.4, chiusura di #15).
3. Rimozione della vecchia build del flasher (#9), solo a verifica completata.

---

## 13. Autenticazione del canale di controllo del fallback: da chiavi SSH a password fissa

### Contesto e cambio di rotta

Con la seriale funzionante e i due bug di rete risolti (§12), il fallback ottiene un IP reale via DHCP e
dropbear si avvia correttamente, ma `ssh -p 2222 root@<ip>` risponde
`Permission denied (publickey,password)`. Il tentativo iniziale (documentato più sotto, poi abbandonato)
era propagare una chiave SSH già fidata sul sistema reale fino al fallback. **Abbandonato su indicazione
esplicita dell'utente**, dopo due giorni di iterazioni sul problema: *"perchè stiamo lavorando con le
chiavi e non con username e password preimpostati?... stiamo continuando a girare attorno al problema
senza soluzioni da due giorni."* Il punto è corretto nel merito, non solo per stanchezza: l'approccio a
chiavi introduceva un problema di propagazione (chi scrive la chiave dove, per due percorsi target diversi)
senza guadagnare margine di sicurezza reale per il modello di minaccia di questo progetto — lo stesso
ragionamento già applicato alla PSK WiFi (§3: non cancellarla non riduce la sicurezza reale, perché lo
stesso segreto è comunque in chiaro altrove). Il test finale con le chiavi (vedi cronologia sotto) ha anche
scoperto un problema più profondo, indipendente dal meccanismo di autenticazione scelto: **`/etc/shadow`
non esiste affatto** nell'initrd (confermato estraendo un initrd reale e ispezionandolo) — non è che la
password di root sia bloccata, è che non esiste alcun file in cui dropbear (né un eventuale `chpasswd` a
runtime) potrebbe cercarla. Questo va risolto comunque, indipendentemente dal meccanismo scelto.

### Design finale: password fissa, stesso valore già in uso ovunque

`root`/`unitotem` è già la credenziale stabilita per l'accesso interattivo a questi dispositivi (memoria
`no-ssh-password-prompts`, `kiosk/common.sh`'s `ROOT_PASSWORD` default). Riusarla per il canale di
controllo elimina interamente il problema di propagazione: nessuna chiave da copiare, nessuna differenza
tra percorso "target già pronto" e "target mai stato UniTotem", nessuna funzione nuova da testare in
isolamento per la sola preoccupazione di popolare un file di configurazione.

**`deploy/lib.sh`** — `ssh_t`/`ota_ssh`/`scp_t` passano da `BatchMode=yes` (solo chiave) a
`PreferredAuthentications=password -o PubkeyAuthentication=no`, con la password fornita via `sshpass`
(stesso pattern già collaudato e proven-working tutta la sessione per l'accesso interattivo al Pi — vedi
memoria `no-ssh-password-prompts`, incluso il dettaglio critico `SSH_ASKPASS_REQUIRE=never` +
`env -u DISPLAY -u SSH_ASKPASS` per evitare il popup grafico):

```bash
OTA_PASSWORD="${OTA_PASSWORD:-unitotem}"

_sshpass() {
    SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS \
        sshpass -p "$OTA_PASSWORD" "$@"
}

SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no \
          -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)
ssh_t() { _sshpass ssh "${SSH_OPTS[@]}" "${TARGET_USERHOST}" "$@"; }

OTA_SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no \
              -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -p 2222)
ota_ssh() { local host="$1"; shift; _sshpass ssh "${OTA_SSH_OPTS[@]}" "root@${host}" "$@"; }
```

Aggiungere `sshpass` a `require_cmd` in `deploy/remote-deploy.sh`.

**`kiosk/files/ota-hook`** — il fix del problema *reale* (`/etc/shadow` assente). Scrivere l'hash a
build-time invece di chiamare `chpasswd` a runtime: evita di dover forzare la copia di `chpasswd` e delle
sue dipendenze (PAM incluso) nell'initrd per un risultato comunque fisso e noto in anticipo:

```bash
# generato una volta con: openssl passwd -6 -salt unitotemota unitotem
mkdir -p "${DESTDIR}/etc"
cat > "${DESTDIR}/etc/shadow" << 'EOF'
root:$6$unitotemota$dDLHj98s/O9CVUWeDgxAoILrb/ZKm4bbv2Lf/X3GbkR4I2mk1rbcfYUWbOStbVbfxmU2UquFNHQokKcsHU6Cy0:19000:0:99999:7:::
EOF
chmod 600 "${DESTDIR}/etc/shadow"
copy_file file /etc/group /etc/group
```

Questo hook è condiviso tra il fallback residente (`kiosk/stage1-recovery-initrd.sh`) e l'initramfs del
sistema reale (`update-initramfs` in stage2) — corretto che lo sia: anche l'initramfs del sistema reale
deve poter servire OTA (livelli 2/3 della garanzia di fallback, §6) con le stesse credenziali, prima ancora
di uno switch_root verso il rootfs persistente dove vive la password "vera".

`deploy/ota-engine.sh`'s `cmd_serve_fallback()` non ha più bisogno di alcuna chiamata a runtime (né
`chpasswd`, né l'`install_ota_authorized_keys()` del tentativo precedente) — la password è già pronta
nell'immagine. dropbear accetta l'autenticazione a password di default (nessun flag `-s` presente per
disabilitarla).

### Esplicitamente fuori scope: tunnel inverso (`cmd_serve`/`cmd_recover`)

Verificato leggendo il codice: **entrambi** i comandi sono già, esplicitamente, segnati come percorso
avanzato incompleto — `cmd_recover` termina con
`die "... percorso avanzato, non ancora automatizzato end-to-end"` e `cmd_serve` si limita ad attendere e
istruire l'operatore a collegarsi manualmente. Con l'autenticazione a password questo problema si
semplifica parecchio (anche `dbclient` in uscita potrebbe usare la stessa password verso un servizio in
ascolto sull'host), ma non è stato affrontato da questo piano — non è una regressione, era già incompleto
prima.

### Scoperta correlata, RISOLTA (2026-08-01): come si innesca `tryboot` da un initrd senza systemd

Durante il primo tentativo di test end-to-end era emerso un problema distinto: `run_ota_sequence`'s ultimo
passo chiudeva con un riavvio semplice, che per `$trial_mode = rpi-tryboot` non innesca affatto la prova
(serve l'argomento letterale `"0 tryboot"` passato al syscall `reboot(2)`). Indagine completata su hardware
reale, in tre parti:

1. **Fix del binario `reboot` (richiesto esplicitamente dall'utente: *"se il reboot di busybox non lo
   supporta includi un binario che lo supporta"*)**: `kiosk/files/ota-hook` ora forza la copia del vero
   `reboot` (risolve a `/usr/sbin/reboot -> /bin/systemctl -> /usr/bin/systemctl`, verificato con
   `readlink -f`, non assunto), stesso schema ldd-based già usato per `nc`/`mount`/`dd`. Confermato su
   hardware reale: il log del kernel ora mostra `reboot: Restarting system with command '0 tryboot'` —
   l'argomento raggiunge correttamente il kernel, cosa che BusyBox non avrebbe mai fatto.

2. **Due bug reali trovati e fissati in diretta sull'hardware reale**, entrambi causa dello stesso sintomo
   (`Failed to write reboot parameter file` poi `Reboot failed -- System halted`):
   - `/run/systemd` non esiste mai in questo initrd (nessun systemd reale gira qui), ma il binario
     `reboot`/`systemctl` ci scrive `reboot-param` prima del syscall. Fix: `mkdir -p /run/systemd` in
     `cmd_serve_fallback()` (`deploy/ota-engine.sh`), prima dell'avvio di dropbear.
   - Anche con quella directory presente, il reset falliva comunque: `/sys/class/watchdog/` risultava
     vuoto, `bcm2835_wdt` (il driver che implementa davvero il restart handler della macchina — diverso da
     `raspberrypi-power`/`reset_raspberrypi`, che gestiscono solo power domain e il framework reset-
     controller, non il riavvio) assente da `/proc/modules`. Il modulo esiste nel pacchetto kernel
     (verificato in `work/arm64/stage2.tar.gz`) ma non veniva incluso nell'initrd: `MODULES=most` copre il
     rilevamento hardware di storage/rete, non i driver watchdog di piattaforma, e il modulo non era in
     `manual_add_modules`. Fix: aggiunto lì. **Entrambi i fix validati in diretta prima del rebuild**:
     modulo scp'd (`scp -O`, necessario: lo scp moderno di OpenSSH usa SFTP di default, non presente in
     questo initrd) sul fallback in esecuzione, caricato con `insmod`, confermato `watchdog0` apparso,
     poi confermato un reset reale (nuovo boot, timestamp kernel ripartiti da 0).

3. **Il vero limite, non un bug**: anche con il reset funzionante, l'argomento `"0 tryboot"` veniva
   ignorato silenziosamente — il riavvio tornava sul fallback (`config.txt`), mai su `tryboot.txt`. Confermato
   via più fonti indipendenti (ricerca nel sorgente kernel + issue `raspberrypi/rpi-eeprom#716`, un utente
   che riporta lo stesso identico sintomo: *"reboot '0 tryboot' on a mainline kernel does not cause the
   tryboot behavior"*) che la logica che scrive il flag tryboot in `PM_RSTS` esiste solo nel fork
   `raspberrypi/linux`, mai portata upstream. Il kernel arm64 generico Debian che questa immagine spedisce
   è mainline-based e non ce l'ha — nessun fix a livello di initrd/moduli può cambiare questo, serve il
   pacchetto kernel Raspberry Pi vero e proprio (`linux-image-rpi-v8`), già segnalato nel piano come
   follow-up rimandato per il KMS, ora confermato necessario anche per tryboot.

**Decisione presa (confermata dall'utente via domanda esplicita, non una scelta unilaterale — cambia quale
di due percorsi già scritti viene effettivamente usato in produzione): `TRYBOOT_CAPABLE=0` forzato in
`deploy/remote-deploy.sh`'s `do_probe()`, invece di cambiare pacchetto kernel adesso.** Il probe precedente
determinava la capacità da modello + `P[SYSTEMD]`, che non può distinguere la provenienza del kernel — era
sempre sbagliato per questa immagine. Il percorso `rpi-legacy` (`cmd_set_trial_boot`'s branch `rpi-legacy`
in `ota-engine.sh`) era già completamente implementato ed è quello che ora viene effettivamente usato:
scambia `config.txt` direttamente per il boot di prova (con backup dell'originale), affidandosi alle
verifiche di integrità dell'initramfs + contatore di boot (livelli 2-4 della garanzia di fallback, già
verificati con fault-injection, task #14) invece della protezione a livello firmware di tryboot. Chiude la
verifica su hardware reale (#15) su questo kernel senza aspettare il cambio di pacchetto kernel, che resta
un follow-up separato (KMS e tryboot dipendono entrambi da quello, quando accadrà).

### Verifica

1. Rebuild `./build-kiosk.sh` (arm64 necessario — `kiosk/files/ota-hook` è tracciato come dipendenza di
   stage1/stage2 da `should_run()`, nessun `FORCE_STAGE` necessario).
2. Rigenerare il parts set arm64, ri-eseguire il loopback test arm64 (50/50 atteso, nessuna delle modifiche
   tocca il meccanismo di restore).
3. Scrivere sulla SD reale con la procedura collaudata (`work/loopback-test/run-real-sd.sh`).
4. **Test mirato, senza aspettare la sequenza completa**: avviare il Pi (fallback di default, come sempre),
   e provare `ota_ssh <ip-attuale> true` (o l'equivalente `sshpass` manuale) — se questo restituisce
   successo, l'autenticazione è risolta, indipendentemente dal problema del tryboot sopra descritto.
5. Solo dopo il passo 4 verde, e solo se si decide di affrontare anche il problema del tryboot: prova reale
   di `deploy/remote-deploy.sh deploy <host>` end-to-end.

## 14. Strumenti di accesso all'hardware reale e stato dettagliato (2026-08-02, sessione notturna)

Questa sezione è il riferimento operativo per riconnettersi al Raspberry Pi di test
(`root@<pi-host>`) attraverso i tre canali indipendenti usati in questa sessione — seriale
bidirezionale, SSH, cattura video HDMI — più lo stato dettagliato di cosa è verificato e cosa resta
aperto. Scritta su richiesta esplicita dell'utente per rendere possibile riprendere il lavoro da zero,
senza dover ririscoprire questi dettagli.

### 14.1 Seriale bidirezionale (UART fisica, adattatore FT232 su `/dev/ttyUSB0`)

**Impostazione baud — verificare SEMPRE prima di fidarsi del canale.** Durante questa sessione il baud
rate del dispositivo locale si è trovato inspiegabilmente a 250000 invece di 115200 (causa non
diagnosticata — non escludere che accada di nuovo), producendo un pattern di byte ripetuto e privo di
senso in lettura che ha simulato per oltre 10 minuti un falso "hang" dell'hardware. **Prima di qualunque
diagnosi seria basata sulla seriale**, controllare e correggere:
```
stty -F /dev/ttyUSB0 -a          # controlla, la prima riga deve dire "speed 115200 baud"
stty -F /dev/ttyUSB0 115200 raw -echo   # correggi se necessario, innocuo se già corretto
```
L'utente ha esplicitamente chiesto, la prima volta che la seriale fu configurata correttamente in questa
sessione, di non modificarne più la configurazione — questo controllo/ripristino a 115200 non viola quella
richiesta: è una verifica difensiva che ripristina lo stato già concordato, non un cambio di
configurazione.

**Lettura continua (avviare una sola volta, resta valida per tutta la sessione):**
```
nohup cat /dev/ttyUSB0 > ~/Sviluppo/unitotem-system/work/pi-serial-tryboot-trigger.log 2>&1 &
```
Prima di avviarne una nuova, controllare che non ce ne sia già una attiva (`ps aux | grep "[c]at /dev/ttyUSB0"`
— usata più volte così per tutta la sessione senza mai doverla riavviare) e che la porta non sia tenuta
aperta da un processo stantio (`fuser /dev/ttyUSB0`) — già capitato in una sessione precedente che un
`socat` dimenticato da due giorni prima tenesse la porta occupata, causando un falso "nessun output"
completamente indipendente dal target.

**Lettura del contenuto recente** (il file di log cresce continuamente):
```
tail -c 3000 work/pi-serial-tryboot-trigger.log | strings   # solo testo leggibile
tail -c 500  work/pi-serial-tryboot-trigger.log | xxd        # byte grezzi, utile se `strings` non mostra nulla
```
Se `strings` non mostra nulla di leggibile ma il file cresce (mtime aggiornato), sospettare per primo il
baud rate (vedi sopra), non un hardware bloccato — è esattamente quello che è successo stanotte.

**Scrittura (invio di tasti/comandi) — richiede un permesso Bash esplicito.** L'azione di scrivere byte
grezzi su `/dev/ttyUSB0` viene bloccata di default dal classificatore di sicurezza della modalità auto,
anche con una regola in `~/.claude/settings.json`, quando il contenuto scritto assomiglia a una password
— la regola di permesso Bash risolve i casi generici (Ctrl-D, invio, comandi) ma **serve uscire dalla
modalità auto (o avere già approvato esplicitamente l'azione) per inviare la password di root stessa**,
osservato empiricamente in questa sessione. Comandi effettivamente usati con successo:
```
printf '\x04' > /dev/ttyUSB0        # Ctrl-D, es. per superare un prompt di emergency shell
printf 'unitotem\n' > /dev/ttyUSB0  # password di root (stessa di SSH, kiosk/common.sh ROOT_PASSWORD)
printf 'comando qui\n' > /dev/ttyUSB0   # qualunque comando shell, una volta autenticati
```
Dopo ogni scrittura, aspettare 2-3 secondi e rileggere il log (vedi sopra) — non c'è modo di sapere se un
comando è stato eseguito se non rileggendo l'output.

**Regola di permesso già impostata** in `~/.claude/settings.json`:
```json
"permissions": { "allow": ["Bash(printf * > /dev/ttyUSB0)"] }
```

### 14.2 SSH — sistema reale e fallback OTA, credenziali e trappole

Password identica ovunque: `unitotem` (utente `root`). Pattern base, usato per **tutte** le connessioni
SSH di questa sessione (mai `ssh`/`scp` grezzi — vedi CLAUDE.md §"SSH/SCP" per il perché):
```bash
SSH_ASKPASS_REQUIRE=never env -u DISPLAY -u SSH_ASKPASS sshpass -p unitotem ssh \
  -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
  [-p 2222] root@<pi-host> "comando"
```
- **Sistema reale** (porta 22, sshd normale): nessun `-p`. Host key **stabile** finché non si riscrive la
  SD — se cambia inaspettatamente, è un segnale reale (nuova scrittura SD), non ignorarlo.
- **Fallback OTA** (dropbear effimero, porta 2222): `-p 2222`. Host key **cambia ad ogni singolo boot per
  design** (rigenerata in RAM) — `UserKnownHostsFile=/dev/null` + `StrictHostKeyChecking=accept-new`
  evita qualunque prompt/blocco per questo, è il comportamento atteso, non un problema.
- Per `scp` verso questi target: usare sempre `-O` (protocollo scp legacy — lo scp moderno di OpenSSH
  userebbe SFTP di default, che richiede `/usr/lib/sftp-server`, assente in questi sistemi minimali) e
  **sempre `-p`** per preservare i permessi del file sorgente, incluso il bit eseguibile — confermato che
  senza `-p` un binario copiato arriva `rw-r--r--`, silenziosamente non eseguibile, un bug reale trovato
  stanotte mentre si validava dal vivo un fix.
- Shell minimale sul fallback: **non c'è busybox**, solo binari klibc-utils separati — `which`, `grep`,
  `head`, `tail`, `wc`, `cp`, `mountpoint` sono **assenti di default** (fissato per `cp`/`grep`/`head`/
  `tail`/`mountpoint` in `kiosk/files/ota-hook`, ma solo nell'immagine più recente — vedi §14.4 per quale
  build ce li ha). `awk`, `command -v`, `cat`, `readlink` coprono quasi tutto il resto quando serve
  diagnosticare senza quei binari.

### 14.3 Cattura video HDMI (indipendente da seriale e SSH)

Dongle di cattura USB (`534d:2109 MacroSilicon`) su `/dev/video2` — mostra esattamente quello che
mostrerebbe un monitor collegato al Pi, utile soprattutto quando la seriale è inaffidabile o SSH
irraggiungibile (è stato lo strumento decisivo stanotte per scoprire che il Pi non era bloccato ma fermo
su un prompt `sulogin` di emergency shell).
```bash
ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video2 \
  -vf "select=gte(n\,60)" -frames:v 1 -vsync 0 -update 1 -y /percorso/output.jpg
```
- Il filtro `select=gte(n\,60)` salta i primi 60 frame: è un artefatto di cold-start del chip di cattura,
  senza saltarli il primo frame utile arriva completamente nero — non un problema di segnale.
- Controllare `fuser /dev/video2` prima: se OBS o un altro programma lo tiene aperto, la cattura fallisce
  silenziosamente o restituisce contenuto vecchio.
- Leggere il jpg risultante con lo strumento Read (rendering diretto dell'immagine), non serve altro
  processing.

### 14.4 Stato dettagliato: cosa è fatto, cosa resta

**Fatto e verificato con esecuzione reale, non solo scritto:**
- Intero motore OTA a due stage scritto e funzionante: `deploy/ota-engine.sh`, `kiosk/files/ota-hook`,
  `kiosk/stage1-recovery-initrd.sh`, `deploy/parts-lib.sh`/`make-parts.sh`, `deploy/remote-deploy.sh` +
  `deploy/lib.sh` riscritti.
- Build di entrambe le architetture, gate di avviabilità, verifica loopback (§11.1) **50/50 ripetuta più
  volte stanotte** con ogni nuovo fix, mai una regressione.
- VM amd64 UEFI+BIOS (§11.2/11.3) e fault-injection sui 4 livelli della garanzia di fallback (§11.5, task
  #14) — tutti verdi.
- **Autenticazione del canale di controllo**: da chiavi SSH (abbandonato) a password fissa — funzionante,
  confermato su hardware reale (§13).
- **Reboot/tryboot**: BusyBox non supporta l'argomento → copiato il vero `reboot`/`systemctl`; scoperti e
  fissati `/run/systemd` mancante e `bcm2835_wdt` mancante dall'initrd (nessuno dei due, il reset non
  avviene affatto); scoperto che `"0 tryboot"` stesso non funziona su kernel Debian generico (serve il
  fork `raspberrypi/linux`, mai portato upstream) → **deciso e implementato `TRYBOOT_CAPABLE=0` forzato**,
  uso di `rpi-legacy` (swap diretto di `config.txt`) invece di tryboot vero. Vedi §13 per i dettagli
  completi.
- **Primo avvio reale del sistema kiosk vero via OTA, mai riuscito prima stanotte**: confermato via
  seriale + SSH, `unitotem-boot-ok.service` con `status=0/SUCCESS`, `promote-default` eseguito
  correttamente (`config.txt` punta permanentemente al kernel reale, `tryboot.txt`/backup rimossi).
- **Scoperta che l'initrd non ha affatto busybox** (solo klibc-utils) — spiega retroattivamente ogni
  "comando non trovato" di stanotte. Fissato: `cp grep head tail mountpoint` aggiunti a `copy_exec` in
  `kiosk/files/ota-hook`, `nls_ascii` aggiunto a `manual_add_modules` (serve per **qualunque** `mount -t
  vfat` senza `iocharset=` esplicito, non solo per i nomi file).
- **`unitotem-ota-arm` (kiosk/files/unitotem-ota-arm)**: il riavvio in background (`nohup reboot &`)
  non sopravviveva alla chiusura della sessione SSH (il processo veniva ucciso prima di eseguire davvero
  il reset) — fissato con `setsid` + breve `sleep 2` dopo il backgrounding.
- **`check_flag_file()` in `deploy/ota-engine.sh`**: `blkid -L` può perdere la race con udev in avvio
  molto presto (stessa classe di bug già nota per `overlayfs-hook.sh`, vedi memoria
  `overlayfs-switch-root-bug`) — fissato con un retry limitato (5 tentativi, stesso pattern di
  `resolve_disk()`), che prima non c'era per questo punto specifico.
- **`deploy/remote-deploy.sh`**: tre chiamate `ssh`/`scp` grezze (bypassavano il wrapper `_sshpass`,
  causavano tentativi di askpass grafico e fallimento silenzioso in esecuzione non interattiva) — fissate.
  `select_disk()` moriva silenziosamente sotto `set -e` con `--yes` + un solo disco e nessun terminale
  (`read` su EOF) — fissato con auto-selezione quando c'è un solo disco candidato.
- **Build nativa sul Pi** (task #22, `build-kiosk.sh`): implementata (`probe_pi()` +
  `build_natively_on_pi()`), meccanica di setup validata dal vivo (symlink `/kiosk`/`/work`/`/deploy` su
  `/mnt/data`, root reso scrivibile solo per la finestra necessaria con trap di ripristino a `ro`) — **mai
  ancora eseguita end-to-end per una build reale completa** (ogni rebuild di stanotte è finita sotto
  Docker+qemu perché il Pi non aveva il sistema reale già avviato al momento giusto).
- **`boot-firmware.mount` fallisce sul sistema reale** (non solo sull'initrd, un contesto diverso — il
  mount guidato da fstab dopo lo switch_root, con il set completo di moduli del kernel, non quello
  ristretto dell'initrd) per la stessa causa (`nls_ascii`/iocharset di default assente) — diagnosticato
  stanotte via login diretto nella emergency shell su seriale (`systemctl --failed` →
  `boot-firmware.mount loaded failed failed /boot/firmware`), **fissato** in `kiosk/files/fstab-arm64` e
  `fstab-amd64` con `iocharset=iso8859-1` esplicito.
- `CLAUDE.md` creato con due policy permanenti: SSH/SCP sempre via i wrapper `_sshpass` (mai grezzi);
  build arm64 nativa sul Pi quando raggiungibile, altrimenti Docker+qemu.

**In corso, non ancora verificato — la build è già stata lanciata, controllare lo stato:**
- Rebuild arm64 con il fix `iocharset` appena applicato (`work/build-arm64-fstab-fix.log`) — **questo fix
  non è mai stato verificato funzionante su hardware reale**, solo diagnosticato e corretto nel sorgente.
  Serve: attendere il completamento della build, rigenerare il parts set
  (`deploy/make-parts.sh --arch arm64 --image deploy/arm64/kiosk-<data>-arm64.img.xz`), verifica loopback
  (`work/loopback-test/run-arm64.sh`, atteso 50/50), scrittura SD reale
  (`work/loopback-test/run-real-sd.sh`), riavvio del Pi, e **questa volta verificare esplicitamente che
  `systemctl --failed` sia vuoto** dopo il boot reale (non solo che SSH risponda) prima di considerare il
  fix confermato.

**Non ancora fatto — l'obiettivo originale che ha aperto questa sessione notturna, mai completato:**
- **Validare per intero il percorso "arma da sistema live"**: `unitotem-ota-arm` (dal sistema reale già
  avviato) → riavvio → fallback → sequenza `run_ota_sequence` completa di `deploy/remote-deploy.sh deploy`
  → promozione. Tentato più volte stanotte, sempre interrotto da un bug reale diverso ogni volta (corsa
  seriale, `boot-firmware.mount`, ecc.) — **mai arrivato in fondo una sola volta**. È l'ultimo vero gap
  prima di poter chiudere il task #15 con fiducia piena.
- Task #15 (verifica hardware reale, singolo passaggio pulito) — resta aperto finché quanto sopra non
  passa per intero.
- Task #9 (eliminare il vecchio percorso di build del flasher) — deliberatamente ultimo, solo a #15
  chiuso.
- Prima esecuzione reale, end-to-end, della build nativa sul Pi (task #22 è "fatto" solo per
  l'implementazione + validazione della meccanica, non per un run reale completo).

## 17. Chiusura: primo deploy OTA di produzione riuscito end-to-end via rete (2026-08-03)

**Task #15 chiuso.** `deploy/remote-deploy.sh`'s `run_ota_sequence` (guidato manualmente, stessa logica dello
script) eseguita per intero contro il Pi reale, partendo da un target già in fallback (non da un sistema
live) fino a boot confermato del sistema reale: `unitotem-boot-ok.service` `ActiveState=active
Result=success`, nessun file di trial/backup residuo su FIRMWARE (`tryboot.txt`/`*.unitotem-bak` rimossi da
`promote-default`), `systemctl --failed` **senza** `boot-firmware.mount` (i quattro rimasti — `dpkg-db-
backup`, `glamor-test`, `logrotate`, `rpi-eeprom-update` — sono preesistenti e non correlati). Sistema su
stabile, `/etc/kiosk` presente.

Cinque bug reali trovati e fissati in questa sessione, **tutti scoperti solo eseguendo il ciclo completo
contro hardware vero**, mai dal loopback (che non innesca gli stessi percorsi):
1. **Mount `/boot-ota` orfano dopo `switch_root`** (§15) — causa originaria dell'emergency mode permanente.
2. **`basename`/`dirname`/`tr` assenti** dal fallback residente (build vecchia) → sostituiti con espansioni
   bash pure in `deploy/ota-engine.sh` (nessuna nuova dipendenza `copy_exec`, il contrario: meno binari
   esterni necessari).
3. **`serve_file_once()` in `deploy/lib.sh` bloccava `$(...)` per sempre** — bug classico di bash
   (backgrounding senza ridirezione dentro una command substitution): il socat in background ereditava
   l'estremità di scrittura della pipe usata da `$(serve_file_once ...)`, che quindi non tornava mai.
   Spiegava **tutti** gli "hang" di 10-90 minuti osservati: `ota_ssh` per `restore-part` non veniva mai
   nemmeno invocato. Fix: ridirigere esplicitamente stdout/stderr di socat.
4. **`ls` sul fallback non accetta *nessuna* opzione** (nemmeno `-1` bare) — sostituito con un glob bash in
   `cmd_populate_real_kernel`.
5. **Mount RW del FIRMWARE in conflitto con `/boot-ota`** (persistente, montato ro per tutta la sessione
   fallback): qualunque comando dell'engine che rimontava lo stesso device altrove veniva silenziosamente
   degradato a read-only dal kernel (stesso device, un mount ro già attivo). Fix: nuovo helper
   `ota_mount_bootfs_rw`/`ota_umount_bootfs_rw` in `deploy/ota-engine.sh`, che riusa/rimonta rw il mount
   esistente invece di provarne uno nuovo indipendente — applicato a tutti i sei punti che ne avevano
   bisogno (`write-bootfile`, `populate-bootfs`, `set-default-recovery`, `set-trial-boot` ×2,
   `mount-target`).
6. **Il contatore di boot persistito su disco non veniva mai azzerato da un trial-boot** — il parametro
   cmdline `unitotem.ota.bootcount=1` che `set-trial-boot` scrive era vestigiale, mai letto da nessuna
   parte. Un trial veniva quindi giudicato contro fallimenti completamente estranei accumulati ore prima
   (qui: i loop di emergency mode del bug #1, prima ancora di essere corretto). Fix:
   `cmd_init_premount` ora legge quel parametro e, se presente, ignora il conteggio persistito e lo
   riazzera per questo tentativo.

**Aggiornamento (2026-08-03): il bug `date` è stato risolto** (sostituito con il builtin bash
`printf '%(fmt)T'`, nessuna dipendenza esterna aggiunta) e riverificato: loopback 51/51 invariato, matrice
di fault-injection del contatore di boot (§11.5 livello 4) riverificata esplicitamente in tre casi (boot
non-trial con conteggio già a 3 → fallback confermato, invariato; boot non-trial sotto soglia → prosegue;
boot di trial con conteggio residuo alto → ignorato correttamente) tramite un test mirato con `/proc/cmdline`
falsificato via bind-mount, non solo per ispezione del codice. Su hardware reale: `UNITOTEM_ETC_MIGRATED=1`
confermato (prima: `!!! migrazione /etc fallita`).

**Due bug in più trovati testando per la prima volta il percorso "arma da sistema live" fino in fondo**
(mai eseguito realmente con `unitotem-ota-arm` seguito dal deploy completo, in questa sessione o prima):
1. `kiosk/files/unitotem-ota-arm` montava `/run/unitotem-bootfs` con un `mount -t vfat` indipendente,
   stesso bug di classe EBUSY/`errors=remount-ro` già fissato altrove: sul sistema reale `/boot/firmware`
   si trova spesso già montato (a volte inaspettatamente read-only, verosimilmente per un urto pregresso
   con `errors=remount-ro`, l'opzione di mount di default per vfat), quindi il secondo mount veniva
   degradato a sola lettura e la scrittura del flag di arming falliva. Fix: stesso pattern di riuso/remount
   già usato in `ota-engine.sh`, inline (questo script è volutamente standalone, non sorgente
   `ota-engine.sh`).
2. **`rm` assente dall'initramfs del sistema reale** (diverso dal fallback residente — qui `mv`/`cp`/`dd`/
   `chroot` sono presenti, verosimilmente via gli applet di busybox-initramfs, ma non `rm`/`chmod`/`tar`).
   Effetto reale e serio, non cosmetico: `check_flag_file()`'s `rm -f "$mnt/unitotem-ota.request"`
   falliva silenziosamente — **silenziosamente** perché l'intera funzione è invocata dentro un `if`, e la
   semantica di `set -e` di bash esenta i comandi interni a una funzione quando l'intera chiamata è il
   soggetto di un test condizionale. Risultato: il flag file non veniva mai cancellato, quindi *ogni* boot
   successivo (compreso il boot di trial appena armato) rientrava in fallback per "flag file
   unitotem-ota.request" invece di procedere — un loop permanente scoperto solo eseguendo per intero il
   percorso arm-da-sistema-live → deploy → trial-boot, mai testato in questa forma prima d'ora. Fix:
   `rm`, `chmod`, `tar` aggiunti al `copy_exec` di `kiosk/files/ota-hook` (i primi due mai presenti neppure
   come applet busybox su questa build; `tar` serve a `populate-bootfs`, mai esercitato nei test di questa
   sessione perché sempre su un target già-UniTotem, ma con lo stesso gap).

**Aggiornamento (2026-08-03): entrambi risolti e riverificati end-to-end su hardware reale, questa volta
per la prima volta tramite il percorso completo "arma da sistema live"** — `unitotem-ota-arm` dal sistema
reale già in esecuzione → riavvio → fallback → `deploy/remote-deploy.sh deploy` (via `run_ota_sequence`) →
riavvio di prova → `unitotem-boot-ok.service` `ActiveState=active`, nessun file di trial/backup residuo,
`systemctl --failed` invariato rispetto a prima (stessi 4 servizi minori preesistenti, nessuna nuova
regressione). Questo chiude l'ultimo gap che l'esecuzione manuale precedente (bypassando `unitotem-ota-arm`
e partendo da un target già in fallback) non copriva.

Loopback riverificato due volte (una per ciascun fix), sempre 51/51 senza regressioni.

**Deliberatamente rimandato, non un problema aperto:**
- Passaggio a `linux-image-rpi-v8` (kernel Raspberry Pi vero) per KMS reale e supporto nativo di tryboot —
  discusso esplicitamente con l'utente stanotte, deciso di **non farlo ora**: comporta un cambio di
  kernel/moduli/device-tree che riaprirebbe una classe di sorprese analoga a quelle risolte stanotte,
  meglio come sessione dedicata a parte con lo stesso rigore (rebuild→loopback→SD→verifica) da uno stato
  pulito.

**Attrito noto, non risolto, da tenere a mente:**
- Il classificatore di sicurezza della modalità auto ha bloccato in modo intermittente e non sempre
  prevedibile anche azioni innocue (controlli di porta di rete, chiamate a Monitor, modifiche a file di
  configurazione) nella parte finale di questa sessione, apparentemente per il contenuto pregresso della
  conversazione più che per l'azione specifica — nessuna causa precisa isolata, il riprovare la stessa
  azione ha quasi sempre funzionato al secondo tentativo.

---

## 15. Bug nuovo trovato e fissato in questa sessione (2026-08-02, continuazione): mount `/boot-ota`
orfano dopo `switch_root`

Diagnosticato dal vivo su hardware reale: il sistema reale era bloccato in emergency mode a **ogni singolo
boot**, non solo occasionalmente — `boot-firmware.mount` falliva sempre con `EBUSY` ("already mounted or
mount point busy"), anche su un boot pulito con `/etc/fstab` già corretto (fix `iocharset`, vedi §13).
Root cause isolata leggendo `/proc/self/mountinfo` per intero (non filtrato): nessun mount visibile su
`/boot/firmware`, eppure il device `/dev/mmcblk1p1` risultava occupato a livello kernel. Causa: `check_flag_file()`
in `deploy/ota-engine.sh` monta la partizione FIRMWARE/EFI su `/boot-ota` **dentro l'initramfs** per leggere
il flag OTA e il bootcount, e nel percorso "tutti i controlli passati, boot normale" di `cmd_init_premount()`
non la smontava mai — solo `remount,ro`. Un mount di un device reale (non un bind mount) fatto dentro il
tmpfs root dell'initramfs non viene ripulito automaticamente da `switch_root` (che sposta/gestisce
`/dev`,`/proc`,`/sys`, non mount arbitrari creati dagli script boot): resta orfano, referenziato a livello
kernel ma irraggiungibile (quindi invisibile in `mountinfo`) dal nuovo root — da cui l'`EBUSY` permanente sul
sistema reale. **Non riguarda il fallback/recovery initrd**: `ota-recovery-init-premount` non fa mai
`switch_root` (resta sempre in modalità OTA), quindi questo bug specifico non blocca il canale di rete
usato da `deploy/remote-deploy.sh deploy`.

**Fix**: `umount /boot-ota 2>/dev/null || true` aggiunto subito prima del `return 0` finale di
`cmd_init_premount()` in `deploy/ota-engine.sh`. Richiede rebuild (l'hook è parte dell'initramfs generato
da `kiosk/stage2-configure.sh`/`kiosk/stage1-recovery-initrd.sh`) — in corso alla fine di questa sessione,
non ancora verificato su hardware reale dopo il fix.

---

## 16. Richieste per le fasi successive (2026-08-02, non ancora iniziate)

Annotate su richiesta esplicita dell'utente, da affrontare **dopo** la chiusura di #15/§15 sopra — non
implementate in questa sessione:

1. **DTB Raspberry Pi reale invece del generico Debian.** Si sovrappone al follow-up già annotato in §10
   (passaggio a `linux-image-rpi-v8`): quel pacchetto porta anche i device-tree corretti/aggiornati per
   Raspberry Pi, non solo `overlays/` e il match di `z50-raspi-firmware`. Da trattare come un'unica sessione
   dedicata (kernel + dtb + KMS + tryboot, vedi §10 e §13), non tre fix separati.
2. **LED di attività standard, ma LED di accensione lampeggiante 50/50 quando il sistema è in modalità
   OTA** (sia fallback residente sia recovery) — segnale visivo per l'operatore che la macchina è in stato
   di manutenzione/ricezione OTA e non nel funzionamento normale del kiosk. Il LED di attività disco
   (`led0`/attività SD, trigger kernel `mmc0`/simili) non va toccato: resta con il comportamento di default.
   Il LED di accensione (`led1`/PWR su Pi 4, trigger `default-on` di norma) va invece pilotato esplicitamente
   con un pattern lampeggiante 50% duty cycle mentre `deploy/ota-engine.sh` è in modalità serve/recovery —
   verosimilmente via `/sys/class/leds/.../trigger` = `timer` con `delay_on`/`delay_off` uguali, impostato
   all'ingresso in `cmd_serve_fallback()` e ripristinato (o lasciato, dato che il sistema non riprende mai
   il normale funzionamento da lì) all'uscita.
3. **Host key SSH del sistema reale generata al primo boot, salvata su DATA (non hardcoded nell'immagine,
   non rigenerata a ogni OTA).** Oggi (§13) solo il canale di **controllo del fallback** usa autenticazione
   a password con chiave dropbear effimera rigenerata a ogni avvio — questo punto riguarda invece la host
   key del **sistema reale** (sshd normale, porta 22): va generata una sola volta al primo provisioning,
   persistita in `/mnt/data` (sopravvive quindi a un OTA che preserva DATA, §7.2 — coerente con la
   whitelist `/etc/ssh/ssh_host_*` già presente in `ota-preserve.list`, ma qui la richiesta è generarla
   direttamente su DATA invece di dipendere solo dalla migrazione overlay). **Inoltre**: quando si esegue lo
   script di prima installazione/provisioning, la chiave generata in quel momento va salvata esplicitamente
   da qualche parte (backup) per poter essere **ripristinata** su una nuova installazione dello stesso
   dispositivo, non solo propagata in avanti — dettaglio da chiarire con l'utente quando si affronta questo
   punto (dove va il backup: solo su DATA, o anche esportato altrove).
