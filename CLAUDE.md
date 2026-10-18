# Istruzioni per Claude in questo repository

## SSH/SCP verso i target UniTotem: sempre e solo non interattivo

Ogni invocazione di `ssh`/`scp` verso un Raspberry Pi/target UniTotem (sistema reale o fallback OTA) **deve**
passare per gli helper già pronti in `deploy/lib.sh` (`ssh_t`, `ota_ssh`, `scp_t`, `ota_ssh_send`, o la
funzione `_sshpass` direttamente per casi ad-hoc) — mai una chiamata diretta a `ssh`/`scp`. Questi helper
garantiscono `SSH_ASKPASS_REQUIRE=never` + `env -u DISPLAY -u SSH_ASKPASS` attorno a `sshpass -p
"$OTA_PASSWORD"`, che è l'unico modo verificato per impedire che un helper grafico di askpass provi ad
aprirsi quando l'autenticazione a password non trova credenziali pronte.

**Perché questa regola esiste**: `deploy/remote-deploy.sh`'s `do_probe()` e la coda di attesa finale di
`cmd_deploy()` (fino al 2026-08-02) invocavano `ssh`/`scp` grezzi, bypassando `_sshpass`. Risultato reale
osservato su hardware vero: OpenSSH, senza una password pronta, prova a lanciare un askpass grafico (fallito
per mancanza di display, log pieno di `libEGL warning: ... failed to create dri2 screen`), poi
`Permission denied, please try again` ripetuto, poi fallimento — bloccando l'intera sequenza di deploy senza
un errore chiaro all'inizio. Fissato wrappando tutte e tre le chiamate con `_sshpass`.

**Prima di aggiungere una nuova chiamata SSH/SCP in questo codebase**: verificare che passi per uno di
questi helper. Un buon modo per controllarlo rapidamente:
```
grep -n '\bssh \|\bscp \b' deploy/*.sh | grep -v '_sshpass\|ssh_t\|ota_ssh\|scp_t\|command -v\|ssh-keyscan'
```
Se questo comando produce righe (a parte commenti/`require_cmd`), c'è una chiamata non protetta da sistemare.

## Build arm64: preferire l'hardware Raspberry reale, quando disponibile

`build-kiosk.sh`'s pipeline arm64 gira sotto emulazione `qemu-aarch64` via Docker su questo host x86_64.
Questo è **strutturalmente lento**, non un bug: `mkinitramfs` (via `copy_exec`'s uso di `ldd`, che esegue
davvero il linker dinamico del binario target) e gli script postinst/trigger di `apt-get install` (che
invocano binari reali come `ldconfig`, `depmod`, `systemctl`) eseguono codice arm64 vero, che deve passare
per l'emulazione binfmt_misc — non è "solo copiare file". Confermato empiricamente in questa sessione
confrontando con pi-gen vendorizzato in questo stesso repo: quella build usa **armhf**, non arm64
(`scripts/common:12`, `BOOTSTRAP_ARGS+=(--arch armhf)`) — l'emulazione a 32 bit (`qemu-arm-static`) è
storicamente più matura/veloce di quella a 64 bit (`qemu-aarch64-static`), quindi il ricordo di build pi-gen
più veloci su questo stesso host non contraddice la spiegazione, la conferma (confronto non a parità di
architettura).

**Politica per ogni build arm64 d'ora in poi**: prima di lanciare la pipeline Docker+qemu, sondare se il
Raspberry Pi di test (`root@<pi-host>`, via SSH — vedi [[no-ssh-password-prompts]] nella memoria per le
credenziali) è raggiungibile. Se sì, preferire l'esecuzione nativa sul Pi per gli step effettivamente lenti
sotto emulazione (in particolare `mkinitramfs`/stage1b) — già dimostrato più veloce e più completo in questo
stesso progetto (~10 min contro 12+ min e incompleto sotto qemu, vedi memoria `ota-redesign-project`). Se il
Pi non è raggiungibile, procedere con la build Docker+qemu-aarch64 attuale come fallback.

**Nota di implementazione (2026-08-02)**: `build-kiosk.sh` non implementa ancora questo probe automaticamente
— è ancora un passo manuale/procedurale da seguire quando si avvia una build arm64, non (ancora) codificato
nello script. Prima di rifarlo un'ennesima volta a mano, vale la pena implementarlo come parte dello script
stesso.

## SD reale del Pi di prova: mai scritture senza limite

L'SD del Raspberry Pi di prova è una risorsa che costa soldi all'utente. Il 2026-10-17 un generatore di carico lanciato
con `ssh … 'nohup … &'` è rimasto in esecuzione 14,7 ore (ssh mai tornato, script in attesa) e ha scritto ~475 GiB
sulla SD prima che qualcuno se ne accorgesse. Regole, valide per ogni sessione/agente:

- Ogni job che scrive sul Pi ha un **limite duro incorporato** (durata o byte massimi) e parte con
  `systemd-run --collect -p RuntimeMaxSec=N …`. Mai un processo lungo avviato con `ssh host 'cmd &'`.
- Stimare i byte scritti prima di avviare; se > ~1 GiB, dirlo all'utente.
- Affiancare ai job di scrittura `tools/pi-sd-guard.sh SECONDI` (staccato): ferma `pwr-writer`/`*-testload.service`
  sopra 300 MiB/min e scrive `SDGUARD` in `work/pi-test/STATE.md`.
- I passi di uno script che aspettano un comando remoto devono essere limitati nel tempo (ssh con
  `ServerAliveInterval`, cicli con massimo) e controllare il budget di scritture (`/sys/block/mmcblk0/stat`, campo 7 × 512).
- Controllare i job lunghi a intervalli; a fine lavoro riportare all'utente i byte scritti sulla SD.

## Disco e cartella di lavoro: tenere in ordine, eliminare il vecchio

Il 2026-10-17 `work/` e `deploy/` occupavano ~450 GB (immagini di prova, qcow2, build giornaliere, `.prev*`). Regole per
ogni sessione e agente di questo repo (e della sessione del manager):

- **Una prova = una cartella sotto `work/<nome>/`**, con una riga in `work/README.md` (scopo, data, "eliminabile quando"). Niente
  immagini sciolte nella radice di `work/` o `deploy/`.
- **Conservare solo l'ultimo risultato utile.** Per le build: l'ultima `kiosk-*.img.xz` e l'ultima `*.parts` per architettura, più
  la release servita al Pi. Le copie `.prevNN`, le `*.parts` vecchie, le release intermedie e le immagini di prova si eliminano
  appena la prova è conclusa, non "più avanti".
- **Alla fine di ogni prova/round: pulire.** Elencare cosa è stato prodotto (`du -sh`), cancellare ciò che è rigenerabile con percorsi
  letterali (mai glob/variabili in `rm`; vedi regole sul `rm`), annotare in `work/pi-test/STATE.md` lo spazio liberato.
- **Grandi file di test = sparsi e temporanei.** `qcow2`/`.img` di VM e di taglio di corrente: creare con overlay/backing file (non
  copie intere), cancellarli quando la prova passa; tenere solo i report (`REPORT.md`) e i log.
- **Directory create da Docker sono di root**: si eliminano con Docker stesso (`docker run --rm -v <cartella-madre>:/w <immagine
  già presente> rm -rf -- /w/<nome letterale>`), mai con sudo; meglio ancora crearle con `--user $(id -u):$(id -g)`.
- **Controllo di spazio:** prima di una build o di una serie di prove, `df -h /home`; sotto i 150 GB liberi, pulire prima di
  iniziare. Mai lasciare un job che scrive senza limite (vedi sezione SD).

## Priorità durante le build

Durante una build (soprattutto quella nativa sul Pi) la build ha la priorità massima e i servizi UniTotem la minima; a build finita
si ripristina tutto com'era. Salvare prima i valori attuali (nice, `CPUWeight` di unitotem-manager/splash/start-xorg e dei
sottoprocessi CEF), applicare `systemctl set-property --runtime … CPUWeight=1` / `renice 19` ai servizi e `nice -n -20` alla build,
e fare il ripristino in un `trap … EXIT` (così un'interruzione ripristina comunque). Valori solo runtime: spariscono al riavvio.

## Server di compilazione (root@build-server)

Dal 2026-10-18 le compilazioni pesanti si fanno su `root@build-server` (Ubuntu 26.04, **container LXC** su Proxmox, 128 core, 256 GB di RAM, 64 GB
di disco di sistema + 256 GB su `/nas`). Regole:
- Lavorare sotto `/nas/` (Docker ha già `data-root=/nas/docker`); il disco di sistema (64 GB) non va riempito.
- Ogni build parte staccata con `systemd-run --unit=<nome> --collect …` (o `work/run-build.sh ARCH VERSION` nel clone di `/nas/unitotem-system`):
  una caduta di ssh non la ferma. Log in `work/logs/build-ARCH.log`, sentinella `work/logs/build-ARCH.done`. Mai build in primo piano in una sessione ssh.
- amd64: la build immagine (debootstrap) **non gira ancora sul server**: nel container LXC `mknod` è vietato (`E: Cannot install into target '/tmp/rootfs' mounted with noexec or nodev`, provato 2026-10-18). Serve che l'utente abiliti sull'host Proxmox `pct set <ID> -features nesting=1,mknod=1` (o un container privilegiato). Finché non c'è, l'amd64 si costruisce sul PC dell'utente con Docker locale; il server resta per le compilazioni che non fanno mknod (CEF/Chromium, cross-build, wheel). **arm64: le immagini si costruiscono SEMPRE sul Pi** (decisione dell'utente 2026-10-18: sul container la CPU
  è troppo lenta per l'emulazione e non si chiede di registrare qemu sull'host Proxmox). Il server serve a ciò che non esegue codice arm64.
- La chiave di firma delle release resta sul PC dell'utente: l'immagine si porta qui con rsync e la release si firma qui.

## Cross-compilazione: sempre preferita

Prima di OGNI compilazione (C/C++, kernel/firmware, estensioni Python, wheel, pacchetti, parti di immagine) verificare e dichiarare se si
può fare in cross dall'host x86 (cross-gcc/clang, sysroot, multiarch, dpkg-cross, `--host-arch`). Se si sceglie l'emulazione (qemu/binfmt)
probabilmente si sta sbagliando: va tenuta solo per ciò che deve eseguire codice del target (debootstrap seconda fase, postinst, test) e
bisogna dire perché. Le immagini arm64 di questo repo non compilano nulla (installano pacchetti e generano l'initramfs): lì il codice del
target gira per forza, quindi si usa il Pi reale, non l'emulazione.

Rete verso il server (misurata 2026-10-18): è in un'altra sede, via VPN (RTT ~38 ms). Il collo di bottiglia era `VPNd` in modalità
userspace (`--tun=userspace-networking`, il container non aveva /dev/net/tun): 5-60 Mbit/s. Con `/dev/net/tun` abilitato e `FLAGS=""` in
`/etc/default/VPNd` il tunnel va a ~390-530 Mbit/s con un flusso e ~730 Mbit/s con quattro (percorso pubblico diretto). Mantenere le VPN
`<vpn>` e `<vpn>` SPENTE durante i trasferimenti: se sono su, VPN sceglie il percorso `<build-server>` dentro la VPN (~30-65 Mbit/s).
Se VPN cade: `nmcli connection up <vpn>` e `<vpn>`, poi ssh a <build-server> (e riportare `FLAGS="--tun=userspace-networking"` se serve).
`mknod` funziona sul server (feature mknod=1) ma NON dentro un container Docker annidato: la build immagine con debootstrap in Docker fallisce ancora
(`Cannot install into target '/tmp/rootfs' mounted with noexec or nodev`): amd64 resta sul PC dell'utente finché non si trova un modo.
