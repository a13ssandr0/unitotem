# Installare UniTotem partendo da un Windows in esecuzione (sovrascrivendolo)

Stato: **ricerca e proposta, nessun codice scritto** (2026-10-12). Domanda dell'utente: "e se volessimo uno script che fa la
stessa cosa dell'attuale, ma partendo da un sistema Windows che viene sovrascritto?". Non e' un impegno: questo documento serve a
decidere in fretta e, se si parte, a non rifare la ricerca. Log grezzo dei fatti verificati, in ordine cronologico:
`work/windows-research/STATE.md`.

## Legenda delle marcature (ogni affermazione ne ha una)

| Marca | Significato |
|---|---|
| **[V]** | VERIFIED-FROM-DOC: letto in questa sessione da una fonte primaria (URL accanto) oppure dal codice/artefatto del repo (percorso accanto) o misurato con un comando qui. |
| **[R]** | RECALLED-NOT-VERIFIED: so che e' cosi' dalla memoria, non l'ho riscontrato in questa sessione. Da verificare prima di costruirci sopra. |
| **[I]** | MY-INFERENCE: deduzione mia da fatti [V]; puo' essere sbagliata, va provata (di solito in QEMU). |

Le fonti secondarie (forum, snippet di ricerca) sono dichiarate come tali accanto alla marca.

## Indice

1. [Verdetto in 10 righe](#1-verdetto-in-10-righe)
2. [Come funziona oggi (letto dal codice)](#2-come-funziona-oggi-letto-dal-codice)
3. [Prior art](#3-prior-art)
4. [Ottenere un boot one-shot del nostro codice da Windows/UEFI](#4-ottenere-un-boot-one-shot-del-nostro-codice-da-windowsuefi)
5. [Dove mettere i file (ESP, nuova partizione, NTFS)](#5-dove-mettere-i-file-esp-nuova-partizione-ntfs)
6. [Secure Boot sui PC Windows](#6-secure-boot-sui-pc-windows)
7. [BitLocker / Device Encryption](#7-bitlocker--device-encryption)
8. [Tutto il resto che puo' morderci](#8-tutto-il-resto-che-puo-morderci)
9. [Lato Windows: come eseguire l'arming e la sonda](#9-lato-windows-come-eseguire-larming-e-la-sonda)
10. [Design proposto](#10-design-proposto)
11. [Come testare senza hardware](#11-come-testare-senza-hardware)
12. [Stima, rischi, ordine di lavoro, punti di decisione](#12-stima-rischi-ordine-di-lavoro-punti-di-decisione)
13. [Cosa NON ho potuto verificare](#13-cosa-non-ho-potuto-verificare)
14. [Fonti](#14-fonti)
15. [Risultati del laboratorio (Windows 11 + OVMF Secure Boot, 2026-10-13)](#15-risultati-del-laboratorio-windows-11--ovmf-secure-boot-2026-10-13)

---

## 1. Verdetto in 10 righe

1. **Fattibile, con precedente reale**: il `win32-loader` di Debian fa gia' esattamente "da Windows in esecuzione, UEFI + Secure Boot,
   copia shim+GRUB firmati sulla ESP e crea una voce di boot firmware via WMI/BCD" (dal 2020). **[V]** (sorgente salsa, par. 3.1)
2. Lo schema nostro e' lo stesso del caso Linux: spingere kernel+initrd di recovery, creare una voce **one-shot**, riavviare; da li'
   `ota-engine.sh` e `run_ota_sequence` sono invariati. **[V]** (`deploy/remote-deploy.sh`, par. 2)
3. Il pezzo nuovo e' solo **lato Windows**: sonda (UEFI/BIOS, Secure Boot, ESP, BitLocker, rete) + arming (`bcdedit`/WMI) + disarm. **[I]**
4. **Spazio sulla ESP**: kernel+initrd di recovery misurano **106,4 MB** (non ~76) piu' ~4,6 MB di catena firmata: **non entra in una ESP da 100 MB**,
   entra in una da 260/500 MB solo se ci sono ~115 MB liberi. Servono un initrd "slim" (via ~80 MB di firmware amdgpu) o una
   partizione FAT32 temporanea ricavata restringendo C:. **[V]** misure (par. 5)
5. **Secure Boot**: la catena firmata esiste gia' (shim doppia firma 2011+2023, GRUB e kernel firmati Debian) **[V]**; il rischio vero e' il firmware
   che **non si fida della "Microsoft UEFI CA (3rd party)"** (Surface e alcuni OEM la spediscono disattivata) **[V]** -> servono azioni fisiche nel setup firmware.
6. **BitLocker/Device Encryption** e' la trappola per l'operatore: se si cambia Secure Boot nel setup firmware senza sospendere BitLocker, Windows chiede la chiave
   di ripristino **[R]**; Windows 11 Home la cifra in silenzio e la chiave sta nell'account Microsoft **[V]**.
7. **Rete**: l'ambiente OTA oggi sa solo **Ethernet con DHCP** nel percorso "legacy"; **non c'e' alcun driver/firmware Wi-Fi** nell'initrd (solo `brcmfmac` del Pi, senza firmware) **[V]**. PC Windows solo-Wi-Fi: fuori portata senza lavoro (dongle USB-Ethernet o initrd con iwlwifi/rtw + firmware).
8. **Rischio piu' alto di tutti**: alcuni firmware ignorano/non mostrano le voci create da `bcdedit` (visto con Wubi-UEFI) **[V, forum]**; l'esito reale si sa solo su hardware.
9. **Stima**: MVP (UEFI, cablato, SB spento o con shim, ESP capiente) ~**8-12 giorni lavorativi** incluso un harness QEMU+Windows; "robusto su molti OEM" non ha fine. **[I]**
10. **Raccomandazione**: se la richiesta diventa reale, partire dal **bundle autonomo** (script PowerShell lanciato dall'operatore come amministratore, senza abilitare sshd su Windows),
    solo UEFI, solo cablato, e **provare prima in QEMU/OVMF+swtpm con Windows Evaluation**; decidere dopo se vale la pena la modalita' SSH. **[I]**

---

## 2. Come funziona oggi (letto dal codice)

Tutto **[V]** sul repo salvo dove indicato.

- `deploy/remote-deploy.sh` pilota il target via SSH solo tramite gli helper di `deploy/lib.sh` (`ssh_t`, `scp_root`, `ota_ssh`...; regola di `CLAUDE.md`: mai `ssh`/`scp` grezzi, sempre `_sshpass`).
- `do_probe()` (riga ~104) esegue **uno script bash** sul target: `uname -m`, `/sys/firmware/efi` (UEFI si/no), modello device-tree (Pi), **Secure Boot** letto dalla variabile EFI `SecureBoot`
  (`unknown` se illeggibile), presenza di `grub-reboot`/`update-grub`, `HAVE_UNITOTEM` (esiste `/etc/kiosk`), `HAVE_DATA`, punto di mount del boot e spazio libero (`BOOTFREE`), RAM,
  rete (interfaccia, wired/wifi, dhcp/static, SSID+PSK se Wi-Fi) e l'elenco dischi `DISK: nome|size|tran|model|by-id`. Se `EFI=1` -> `ARCH=amd64 FIRMWARE=uefi`, altrimenti `bios`.
- `cmd_deploy()` (riga ~711): `do_probe`, `select_disk`, scelta del parts set, `secure_boot_gate`, `changes_gate`, conferma "SI". Poi due rami:
  - **target gia' UniTotem**: `ssh_t "unitotem-ota-arm --port 2222"` (script sul target che scrive `unitotem-ota.request` + `unitotem-ota.conf` sulla ESP e riavvia).
  - **target legacy (Linux estraneo)**: `push_recovery_kernel` (scp di `deploy/amd64/recovery-vmlinuz-amd64` e `recovery-initrd-amd64.img` in `/boot` come `unitotem-recovery-vmlinuz`/`unitotem-recovery-initrd.img`),
    `arm_grub` (scrive `/etc/grub.d/99_unitotem_flash` con `menuentry 'UniTotem OTA' { linux ... unitotem.ota=1 console=tty0 ; initrd ... }`, `update-grub`, **`grub-reboot 'UniTotem OTA'`** = one-shot), `do_reboot`.
  - poi `wait_ota_reachable` (dropbear sulla **porta 2222**, fino a 10 min) e `run_ota_sequence` (comandi `unitotem-ota-engine ...` via SSH: partizionamento, stream `partclone` via netcat, `populate-bootfs`, ecc.).
- `cmd_disarm()`: rimuove `99_unitotem_flash`, rigenera la config GRUB, cancella kernel/initrd copiati (e per il Pi ripristina `config.txt`/`cmdline.txt`).
- **Ambiente OTA** (`deploy/ota-engine.sh`, dentro l'initramfs di recovery):
  - rete: `configure_networking_ota()` (riga ~1207) legge `/boot-ota/unitotem-ota.conf` (`OTA_NET_IFACE/LINK/MODE/ADDR/GW`, `OTA_WIFI_SSID_B64`, `OTA_WIFI_PSK_B64`), carica `virtio_net genet bcmgenet`,
    prende la **prima interfaccia non-lo**, e: se `OTA_NET_LINK=wifi` usa `wpa_passphrase`+`wpa_supplicant`; se `OTA_NET_MODE=static` usa `ip addr`; altrimenti **DHCP** (`configure_networking` / `ipconfig`).
  - **Punto critico per Windows**: nel percorso legacy (cmdline `unitotem.ota=1`) `cmd_init_premount` va **subito** in `cmd_serve_fallback`, **prima** di `check_flag_file`, che e' l'unico punto che monta
    `/boot-ota`. Quindi `unitotem-ota.conf` **non viene letto**: rete = DHCP sulla prima interfaccia, niente static, niente Wi-Fi. **[I]** (deduzione da una lettura delle righe 1207-1235 e 1665-1735; da confermare con un test).
  - accesso: dropbear porta 2222, **password root fissa `unitotem`** (`OTA_PASSWORD` in `deploy/lib.sh`), chiave host effimera. Un watchdog (1800 s per `unitotem.ota=1`) **riavvia** se nessun host si collega: e' l'ancora di salvataggio dell'abort.
  - `efibootmgr` e' nell'initrd di recovery (`usr/bin/efibootmgr`) ma `ota-engine.sh` non lo chiama. `sgdisk`, `sfdisk`, `partclone.restore`, `dropbear`, `wpa_supplicant`, `whiptail`, `pv`, `nc`, `ipconfig` ci sono.
- **Artefatti misurati** (`lsinitramfs`, `sbverify`, qui):
  - `recovery-vmlinuz-amd64` = 12.154.816 B, firmato "Debian Secure Boot Signer 2022 - linux" (quindi accettato da shim). **[V]**
  - `recovery-initrd-amd64.img` = 94.284.394 B, **gia' compresso** (zstd -3 -> 93,9 MB, xz -3 -> 93,8 MB: non c'e' margine). Totale con kernel = **106,4 MB**. **[V]**
  - Contenuto non compresso dell'initrd: 201 MB di cui **firmware amdgpu 81,5 MB**, radeon 3,3 MB, moduli kernel 38,7 MB. **[V]**
  - Driver di rete cablata: ampio (e1000e, igc, igb, ixgbe, r8169, tg3, bnxt, atlantic, USB: ax88179, cdc_ether, cdc_ncm...). Storage: nvme, ahci, xhci, uas, usb-storage. **[V]**
  - Wi-Fi: **solo** `brcmfmac`/`brcmutil` (per il Pi); nessun `iwlwifi`, `rtw88/89`, `ath1xk`, `mt76`; in `/lib/firmware` solo amdgpu, radeon, `cis`, `ene-ub6250`, `cxgb3/4`, `tigon`, `kaweth`, `advansys`, `microchip`, `tehuti`, `isci`, `3com`, `rp2.fw`, `regulatory.db`: **nessun firmware Wi-Fi e nemmeno `rtl_nic`** (alcune Realtek r8169 lo vogliono, **[R]**). **[V]** per la lista.
  - (Nota: `kiosk/stage1-packages.sh` installa `firmware-linux-nonfree`, `firmware-misc-nonfree`, `firmware-brcm80211` nell'**immagine**, ma questi firmware NON finiscono nell'initrd di recovery. **[V]**)
- **Catena Secure Boot** (commit `748ed61`, `kiosk/stage3-image.sh` righe ~256-281, `deploy/ota-engine.sh` righe ~557-575): l'immagine porta in `EFI/unitotem-sb/` `shimx64.efi`, `mmx64.efi`, `grubx64.efi` (firmati), `grub-unsigned.efi` e uno `grub.cfg` "stub"
  (`search --no-floppy --label --set=root EFI` poi `configfile .../unitotem-grub/grub/grub.cfg`). `populate-bootfs --secure-boot shim` copia gli stub in `EFI/BOOT` **e** `EFI/debian`, e sostituisce `BOOTX64.EFI` con lo shim per ultimo, via rename. Il commento nel codice: *"The signed GRUB has a fixed prefix and cannot be pointed elsewhere"*. **[V]**
  - I binari firmati in `work/sb-test/signed/` (altro agente, solo lettura): `shimx64.efi.signed` 1.036.152 B con **due firme** (Microsoft Windows UEFI Driver Publisher <- Microsoft Corporation UEFI CA 2011; e Microsoft UEFI CA 2023 signer <- Microsoft UEFI CA 2023), `grubx64.efi.signed` 2.684.352 B e `mmx64.efi.signed` 873.904 B firmati "Debian Secure Boot Signer 2022". Totale catena ~4,6 MB. **[V]** (`sbverify --list`); che quei file coincidano con quelli dell'immagine finale: **[V]** (laboratorio 2026-10-13: `sha256sum` identici a quelli estratti da `work/sb-test/built2.img`).
  - Test gia' fatto dall'altro agente (`work/sb-test/STATE.md`): l'immagine senza shim sotto OVMF con chiavi Microsoft viene rifiutata ("Access Denied -- rejected probably by Secure Boot"). **[V]** (file di stato letto).
  - Il gate dice gia': *"Se il sistema attuale non e' Debian, il primo passaggio (voce GRUB una tantum) puo' fallire: il suo shim rifiuta il kernel Debian ('bad shim signature')"*. Su Windows **non c'e' un GRUB di partenza**: la catena nostra (shim->GRUB->kernel) viene avviata *direttamente dal firmware*, quindi quel problema non esiste, ma ne nasce un altro (par. 6). **[V]** per la frase, **[I]** per la conseguenza.

---

## 3. Prior art

### 3.1 Debian `win32-loader` (il piu' importante)

- Cos'e': installer NSIS che da Windows prepara l'avvio del Debian Installer. **UEFI e Secure Boot supportati da 0.10.0 (luglio 2020)**: changelog "Introduce UEFI boot manager and Secure Boot support (Closes: #918863)". **[V]**
  Fonti: sorgente `https://salsa.debian.org/installer-team/win32-loader` (ho scaricato il tarball master e letto `s_install.nsi`, `include/bootcfg.nsh`, `debian/changelog`); annuncio
  [micronews.debian.org/2021/1628987476.html](https://micronews.debian.org/2021/1628987476.html) (Bullseye).
- **Come aggiunge la voce di boot (sezione `Firmware Boot Manager` di `s_install.nsi`)** **[V]**:
  1. via **WMI** (provider BCD di `root\WMI`: classi `BcdStore`/`BcdObject`) apre lo store BCD di default e ricava il volume della ESP (`GetESPVolume`);
  2. monta temporaneamente la ESP in una cartella con `SetVolumeMountPoint`, crea `\EFI\debian\`, copia `bootnetx64.efi` (shim firmato, dalla netboot Debian) come `shimx64.efi` e `grubx64.efi`;
  3. scrive `grub.cfg` con `search --set --fs-uuid <UUID di C:>` e `set prefix=($root)<cartella di installazione>` poi `normal` -> **kernel e initrd restano su C: (NTFS)**, GRUB li legge col modulo NTFS;
  4. crea un oggetto BCD di tipo **BOOT_MANAGER (0x10100002)** con un GUID nuovo, `SetDescription`, `SetPartitionDeviceElement` (la ESP), `SetStringElement` path `\EFI\debian\shimx64.efi`,
     poi `AppendFwBootEntry` (lo aggiunge al `displayorder` firmware) e `SetActiveFwBootEntry`;
  5. salva il GUID in registro (`REGSTR_WIN32\bootmgr`) per la disinstallazione.
  - **Non** usa `bootsequence`: la voce e' **persistente** (resta in lista finche' non la si rimuove), non one-shot. Per noi serve one-shot (par. 4).
  - Nel changelog (trixie): "Remove obsolete workaround (netboot grubx64.efi of Trixie is fine)": oggi usa lo shim/GRUB firmati della netboot Debian senza patch. **[V]**
- Riutilizzabile? **Come modello e come prova di fattibilita': si'. Come componente: no** (NSIS, scarica la netboot di d-i, kernel su NTFS, voce persistente). Il codice `bootcfg.nsh` (WMI BCD) e' la miglior documentazione operativa di come si crea una voce firmware senza `bcdedit`. **[I]**

### 3.2 Altri

| Strumento | Cosa fa | Riutilizzabile da noi? |
|---|---|---|
| **Wubi** (Ubuntu) | Installava Ubuntu in un file su NTFS, voce nel BCD di Windows. **Tolto da Ubuntu 13.04**: inutilizzabile su Windows 8, rischio di perdita dati con l'ibernazione, non funzionava su UEFI. **[V]** [lista ubuntu-devel](https://lists.ubuntu.com/archives/ubuntu-devel/2013-April/036994.html), [037058](https://lists.ubuntu.com/archives/ubuntu-devel/2013-April/037058.html), [Phoronix](https://www.phoronix.com/news/MTM0MDY), [Wikipedia](https://en.wikipedia.org/wiki/Wubi_(software)) | No (morto). Il fork **wubiuefi** (github.com/hakuna-m/wubiuefi) e' utile come **testimonianza** (vedi par. 4.4). |
| **wubiuefi issue 15** | Una voce creata con `bcdedit /copy {bootmgr}` + `path \EFI\ubuntu\wubildr\shimx64.efi` compare in `bcdedit /enum firmware` ma **non nel menu di boot** finche' non e' in `displayorder`; aggiunta al `{bootmgr}` displayorder fallisce con `0xc000007b`; il manutentore: "known issues with non-Microsoft programs if you want to start them from BCD menu" -> usare il menu **firmware**. **[V, fonte secondaria: issue di progetto]** [github.com/hakuna-m/wubiuefi/issues/15](https://github.com/hakuna-m/wubiuefi/issues/15) | Si': conferma che serve `{fwbootmgr}`, non il menu BCD. |
| **EasyBCD / NeoGrub** | Aggiunge Linux al bootmgr di Windows; NeoGrub = GRUB4DOS (BIOS). In modalita' EFI molte funzioni sono disabilitate; staff NeoSmart: "bootmgr.efi" impedisce di avviare OS "estranei" dal menu BCD. **[V, fonte secondaria: forum NeoSmart via ricerca; non aperto direttamente]** | No (BIOS-only, per design). |
| **UNetbootin** | Modalita' "hard disk": modifica bootmgr/bcdedit su Vista+ e poi annulla. Nessuna fonte su UEFI/Secure Boot trovata; il progetto risulta quasi abbandonato (fonte debole). **[R]** | No. |
| **Grub2Win** | Installa GRUB su Windows (BIOS e UEFI). La ricerca **non ha trovato documentazione** su come registra la voce UEFI/Secure Boot. **[R]** | Non valutabile; da leggere se si va avanti (e' un secondo esempio di voce firmware creata da Windows). |
| **Ventoy / Rufus** | Bootano da **chiavetta**: contrasto, non soluzione. Ventoy con Secure Boot richiede l'enrollment di una chiave in MokManager (fisico, una tantum per PC). **[V, fonte secondaria]** [Ventoy FAQ #3536](https://github.com/ventoy/Ventoy/issues/3536) | No: il punto della richiesta e' evitare la chiavetta. |
| **iVentoy / PXE / WDS / MDT / SCCM** | Boot di rete: serve che il firmware faccia PXE (con Secure Boot il PXE richiede shim firmato; il PC deve essere messo in PXE da firmware/BIOS). Nessuna fonte aperta in questa sessione. **[R]** | Alternativa **strutturale** (nessun arming lato Windows) ma richiede infrastruttura DHCP/TFTP e un modo di dire al PC "il prossimo boot e' PXE" (vedi sotto). |
| **"Forza PXE al prossimo boot" dei costruttori** | Dell Command Configure `cctk --forcepxeonnextboot=enable`, HP BCU, Lenovo ...: esiste per Dell ma **non su tutti i modelli** (thread Dell Community: OptiPlex 3050 ok, 3060 no). **[V, fonte debole: forum]** [dell.com community](https://www.dell.com/community/Optiplex-Desktops/3060-does-not-support-forcepxeonnextboot/m-p/6178920) | Specifico per marca; utile solo come ripiego in flotte omogenee. |
| **Intel AMT / vPro, BMC** | Boot remoto one-shot fuori banda (IDE-R / PXE). Nessuna fonte aperta. **[R]** | Solo flotte con vPro provisionato. |
| **Clonezilla, Veeam, RMM (Intune, Tanium...)** | Reimaging di massa: in pratica usano PXE, chiavetta, oppure una voce BCD/WinPE creata da un agente. Nessuna fonte aperta. **[R]** | Non reperiti strumenti open che facciano "da Windows vivo a Linux senza chiavetta" oltre a win32-loader. |
| **Operese** | Migratore Windows 10 -> Kubuntu in Rust (Codeberg), **alpha**, per la stampa "UEFI support not implemented yet" (2025). **[V, fonte secondaria]** [Neowin](https://www.neowin.net/news/windows-11-is-unsupported-this-app-automatically-moves-important-windows-10-data-to-linux/), [BetaNews](https://betanews.com/2025/07/22/saying-no-to-windows-11-just-got-easier-operese-automatically-transfers-your-windows-10-files-and-settings-to-linux/) | No. |
| **kexec** | Non c'e' un kexec da Windows. (Nota: Google ha fatto il contrario, avviare Windows da Linux con kexec.) **[V, snippet]** [Phoronix](https://www.phoronix.com/news/Google-Kexec-Windows-Linux) | No. |
| **Ricerca generale "installare Linux da Windows via rete/SSH"** | Nessun risultato utile oltre a quanto sopra. | — |

**Conclusione di sezione**: l'unico precedente maturo con UEFI+Secure Boot e' `win32-loader`; il resto e' morto, BIOS-only o alpha. Non esiste un prodotto da riusare; esiste un **metodo documentato nel suo codice**. **[I]**

---

## 4. Ottenere un boot one-shot del nostro codice da Windows/UEFI

### 4.1 Il meccanismo, in una frase

Windows non offre un "grub-reboot", ma espone le variabili UEFI di boot (`Boot####`, `BootOrder`, `BootNext`) tramite lo **store BCD** come oggetto speciale **`{fwbootmgr}`**: creare un'applicazione firmware nel BCD
significa creare un `Boot####` nella NVRAM. **[R]** per l'identita' "oggetto BCD firmware == `Boot####`"; **[V]** per l'esistenza di `{fwbootmgr}`/`displayorder` ([MS: BCD UEFI](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi)).

### 4.2 Comandi `bcdedit` (richiedono un prompt elevato)

Tutti richiedono **amministratore** (*"Administrative privileges are required to use BCDEdit to view the BCD store"* **[V]** [MS: bcdedit /enum](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--enum)).

```bat
:: 0. fotografia PRIMA (da salvare: serve al rollback)
bcdedit /enum firmware            :: tipi validi di /enum: ACTIVE | FIRMWARE | BOOTAPP | BOOTMGR | OSLOADER | RESUME | INHERIT | ALL   [V: MS bcdedit /enum]
bcdedit /export C:\ProgramData\unitotem\bcd-before.bak   :: copia dello store                                                   [R]

:: 1. creare la voce (modello copiato da {bootmgr}; schema confermato da post di forum e dal thread wubiuefi)                      [V, forum]
bcdedit /copy {bootmgr} /d "UniTotem OTA"                 :: stampa il nuovo {GUID}
bcdedit /set {GUID} device partition=S:                   :: S: = ESP montata (vedi 5.1)                                          [R: sintassi; win32-loader usa SetPartitionDeviceElement]
bcdedit /set {GUID} path \EFI\unitotem-ota\shimx64.efi    :: shim se Secure Boot ON, grubx64.efi se OFF (indicazione del manutentore wubiuefi)   [V, forum]

:: 2a. one-shot (consigliato per noi)
bcdedit /set {fwbootmgr} bootsequence {GUID}              :: forma {fwbootmgr}: NON documentata da MS; PROVATA nel laboratorio: scrive BootNext [V, lab 2026-10-13]
::     la doc MS di /bootsequence ("sets the one-time boot sequence to be used by the boot manager") descrive solo la forma generica [V: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--bootsequence]
:: 2b. persistente (come win32-loader: AppendFwBootEntry)
bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst    :: forma documentata nell'esempio MS con {bootmgr}                               [V: MS BCD UEFI]

:: 3. riavvio
shutdown /r /t 5 /c "UniTotem OTA"                        :: /r riavvia, /t ritardo, /a aborta (anche /fw per "vai al setup firmware") [V: MS shutdown]
```

- **Cosa cambia in modo persistente**: una nuova voce nello store BCD (e, se il firmware la accetta, una `Boot####` in NVRAM) e, con 2b, l'ordine di boot. Con 2a la `BootNext` e' consumata dal firmware al primo boot (semantica UEFI standard **[R]**).
- **Annullare**: `bcdedit /delete {GUID}` (rimuove anche dalla sequenza **[R]**), `bcdedit /set {fwbootmgr} bootsequence {GUID} /remove` o `bcdedit /bootsequence ... /remove` (**[V]** la sintassi `/remove` nella doc MS di `/bootsequence`, solo per la forma generica),
  `bcdedit /set {fwbootmgr} displayorder {GUID} /remove`; poi riconfrontare `bcdedit /enum firmware` con la fotografia iniziale. **[R]** per la sequenza completa.
- **`shutdown /r /fw`** apre il setup firmware (non avvia una voce); `shutdown /a /fw` annulla un boot-to-firmware pendente. **[V]** [MS shutdown](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown). Utile come **ripiego manuale** ("entra nel firmware e scegli la voce").

### 4.3 Alternative a `bcdedit`

| Via | Note |
|---|---|
| **WMI provider BCD** (`root\WMI`, `BcdStore.OpenStore`, `BcdObject`, ...) | E' cio' che usa `win32-loader`. **[V]** (`include/bootcfg.nsh`). Piu' robusto dei parser di output di `bcdedit` (che e' localizzato: l'output cambia con la lingua di Windows **[R]**). In PowerShell: `Get-CimInstance`/`Invoke-CimMethod` su `root\WMI`. **[R]** |
| **Variabili UEFI dirette** (`SetFirmwareEnvironmentVariable[Ex]`, scrivere `Boot####`, `BootOrder`, `BootNext`) | Richiede il privilegio `SE_SYSTEM_ENVIRONMENT_NAME`; **fallisce su BIOS legacy** (`ERROR_INVALID_FUNCTION`), il che da' anche un test affidabile UEFI/BIOS. **[V]** [MS API](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariablea). Si deve costruire a mano la struttura `EFI_LOAD_OPTION` (device path compreso). **[R]** E' l'unica via che non dipende dal "traduttore" BCD, quindi la piu' vicina a `efibootmgr -n`. |
| **`mountvol S: /S` + sostituire `\EFI\Boot\bootx64.efi`/`bootmgfw.efi`** | Invasiva e fragile (gli aggiornamenti di Windows ripristinano `bootmgfw.efi`); rompe l'abort. **Sconsigliata.** **[I]** |
| **Boot da Windows RE / `reagentc`** (avviare un WinRE personalizzato) | Richiede di costruire un'immagine WinPE/RE con dentro la nostra logica: non e' "il nostro kernel". **[I]** Non approfondito. |
| **Menu BCD ({bootmgr} displayorder)** | Non funziona per applicazioni EFI estranee (`0xc000007b` nel thread wubiuefi; limite dichiarato di bootmgr.efi). **[V, secondario]** |

### 4.4 Cosa succede se il firmware ignora la voce creata dal BCD

Casi riportati (tutti **fonti secondarie**): la voce c'e' in `bcdedit /enum firmware` ma **non compare nel menu di boot** del firmware, oppure compare solo entrando nel setup; alcuni firmware accettano solo `\EFI\Microsoft\Boot\bootmgfw.efi` o `\EFI\Boot\bootx64.efi` e "resettano" il resto; la voce lanciata da `{bootmgr}` dà `0xc000007b`; un caso con path corrotto da `bcdedit` (Fedora) risolto ricreando la voce con un'altra etichetta.
Fonti: [wubiuefi #15](https://github.com/hakuna-m/wubiuefi/issues/15), [Arch forum 225683](https://bbs.archlinux.org/viewtopic.php?id=225683), [Fedora discussion](https://discussion.fedoraproject.org/t/failed-to-boot-shim-efi-but-boots-grub-anyway-file-s/90143). **[V]** che i resoconti esistono, **[R]** la loro generalita'.
Conseguenze per il design **[I]**:
1. *Verificare dopo aver creato*: rileggere `bcdedit /enum firmware` e controllare che `{GUID}` esista con il path giusto **e** (se possibile) che `Boot####`/`BootNext` esistano davvero (lettura variabili UEFI).
2. *Fallimento sicuro*: se il firmware ignora `BootNext`, la macchina riparte in **Windows** (nulla e' distrutto). Il watchdog dell'host (`wait_ota_reachable`, 10 min) deve concludere "non sono entrato in OTA" e proporre `disarm` + istruzioni manuali (tasto del boot menu / `shutdown /r /fw`).
3. *Ripiego manuale documentato*: l'operatore preme il tasto del boot menu del costruttore e sceglie "UniTotem OTA" (se la voce c'e') oppure "Boot from file" nel setup (se il firmware lo offre). **[R]**

---

## 5. Dove mettere i file (ESP, nuova partizione, NTFS)

### 5.1 ESP (la scelta naturale)

- Dimensioni: la guida Microsoft per OEM fissa il **minimo a 200 MB (settore 512/512e) e 300 MB (4K nativo)**, dice che la ESP *"should not contain any other files"* oltre a quelle gestite dal sistema, e che MSR = 16 MB. **[V]** [MS: UEFI/GPT partitions](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions).
- Nella pratica i PC piu' vecchi (Windows 8/10 installati "puliti") hanno ESP da **100 MB**, gli OEM recenti 260/300/500 MB. **[R]** Spazio libero tipico sulla ESP: decine di MB (font, lingue, firmware, a volte tool OEM) **[R]**: va **misurato**, non assunto.
- Il nostro fabbisogno (**misurato**, par. 2): 12,2 MB kernel + 94,3 MB initrd + ~4,6 MB catena firmata = **~111 MB**. **[V]** -> **non entra in 100 MB**; entra in 260/500 MB solo con ~115 MB liberi.
- Come montarla da Windows: `mountvol S: /S` (monta la ESP su una lettera) **[R]**; oppure `diskpart` (`select disk 0` / `list volume` / `select volume N` / `assign letter=S`) **[V]** [MS BCD UEFI](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi) (esempio con `assign letter=s`). `win32-loader` evita le lettere: `SetVolumeMountPoint` su una cartella. **[V]**
- **Initrd "slim" per Windows [I]**: il firmware amdgpu pesa 81,5 MB dei 201 MB non compressi; senza di esso l'initrd compresso scenderebbe plausibilmente a ~50-60 MB (stima proporzionale, **da misurare**). Conseguenza: console grafica via `efifb`/`simpledrm` senza accelerazione AMD (la UI dell'OTA e' testo: `whiptail`). Totale ~70 MB -> entra in una ESP da 260 MB con margine, **non** in una da 100.
- Altri problemi della ESP **[R]**: condivisa con altri OS/OEM; alcuni firmware (HP, Lenovo) usano la ESP per i propri tool; la scrittura di ~100 MB fa una FAT32 molto piena -> Windows Update delle componenti di boot puo' fallire se la lasciamo piena (quindi **pulire sempre nel disarm**).

### 5.2 Nuova piccola partizione FAT32 dopo aver ristretto C:

- `Resize-Partition -DriveLetter C -Size <n>` accompagnato da `Get-PartitionSupportedSize` (`.SizeMin/.SizeMax`). **[V]** [MS: Resize-Partition](https://learn.microsoft.com/en-us/powershell/module/storage/resize-partition) (la pagina non parla dei limiti).
  Limiti noti **[R]**: il minimo e' alzato dai file non spostabili (pagefile, hiberfil, MFT, shadow copies) -> a volte si riesce a liberare poco; richiede C: sano (`chkdsk`).
- Vincoli di layout **[V]** (MS): la partizione di recovery deve stare **subito dopo** la Windows e le utility "devono precedere" Windows/dati; una nostra partizione in coda (dopo Recovery) e' accettabile dato che comunque verra' cancellata. **[I]**
- Vantaggio: non tocca la ESP; il firmware carica da qualsiasi FAT con device path GPT. **[R]** Svantaggio: operazione che modifica la tabella partizioni di un disco con dati (rischio piu' alto di quello della sola ESP), e **con BitLocker** il restringimento e' ammesso online ma aggiunge variabili. **[R]**
- Per un'installazione che *comunque* cancella tutto, il rischio del restringimento e' accettabile solo se il restringimento non e' piu' pericoloso del fallimento dell'arming (se l'arming fallisce Windows deve ripartire intatto -> bisogna *riestendere* C: nel disarm). **[I]**

### 5.3 Leggere da NTFS (come `win32-loader`)

- `win32-loader` tiene kernel+initrd su C: e li fa leggere a GRUB; sulla ESP mette solo shim+GRUB+`grub.cfg` (con `search --fs-uuid` di C:). **[V]**
- Per noi: **RIFIUTATO [V, lab]**: il modulo `ntfs` c'e' nel GRUB firmato ma `ls` risponde `unknown filesystem` su tutti i volumi NTFS provati; inoltre **non funziona con BitLocker** (C: cifrato illeggibile da GRUB). **[I]**
- Pro: sulla ESP bastano ~5 MB. Contro: dipende da BitLocker e da `Fast Startup` (NTFS "sporco" dopo uno shutdown ibrido -> GRUB legge comunque, ma i file scritti da Windows potrebbero non essere ancora flushati **[R]**).
- **Raccomandazione [I]**: ESP se `libero >= 115 MB` (o ~75 MB con initrd slim); altrimenti nuova partizione FAT32; NTFS solo come terza scelta e mai con BitLocker.

---

## 6. Secure Boot sui PC Windows

### 6.1 Stato tipico e significato per la nostra catena

- Un PC con Windows 11 ha quasi sempre Secure Boot **attivo** (requisito di Windows 11 insieme a TPM 2.0). **[R]** Su PC Windows 10 piu' vecchi puo' essere spento o in modalita' CSM/legacy. **[R]**
- La nostra catena (par. 2): **firmware -> shim (firmato Microsoft: UEFI CA 2011 *e* 2023) -> GRUB firmato Debian -> kernel firmato Debian**. Lo shim contiene la CA Debian e verifica GRUB e kernel con quella (wiki Debian: *"Shim embeds Debian's CA, which signs GRUB, the Linux kernel..."*). **[V]** [wiki.debian.org/SecureBoot](https://wiki.debian.org/SecureBoot)
- L'**initrd non e' firmato** e non viene verificato da shim/kernel (e' dati, non codice EFI). **[I]**. Il *lockdown* del kernel con Secure Boot (modalita' integrity) limita moduli non firmati e `/dev/mem`, ma non le scritture raw sui dischi che ci servono; i moduli dell'initrd sono quelli Debian firmati. **[I]** (da provare in QEMU con OVMF Secure Boot).

### 6.2 La "Microsoft UEFI CA (3rd party)" non e' sempre fidata

- Debian: *"Some recent machines ship with the Microsoft UEFI 3rd Party CA disabled, so shim fails with a security violation. Re-enabling it in firmware is the usual fix."* e: *"On some 2024+ hardware, the DB contains 'Windows UEFI CA 2023' but not 'Microsoft Corporation UEFI CA 2011', which can block shim... newer Debian releases ship a shim signed with the 2023 CA."* **[V]** [wiki.debian.org/SecureBoot](https://wiki.debian.org/SecureBoot)
- **Surface**: il firmware accetta di default solo il keyset Microsoft; l'impostazione e' sotto *Security -> Secure Boot configuration -> "Microsoft & 3rd party CA"*; con "Secured-core" attivo ci sono anomalie (boot loop su Surface Laptop 5 / Pro 9 con certe versioni). **[V, fonti di terzi]** [ESET KB8389](https://support.eset.com/en/kb8389-enable-3rd-party-certificates-in-secure-boot-for-eset-endpoint-encryption-and-eset-full-disk-encryption), [Matrix42](https://docs.matrix42.com/en_US/3604148_computer-does-not-boot-with-secure-boot-enabled).
- **Dell, HP, Lenovo, ASUS, Acer**: non ho trovato in questa sessione una fonte primaria sullo stato di default; **[R]** che la maggior parte dei desktop/laptop consumer spedisce la 3rd-party CA abilitata, mentre i modelli "secured-core"/commerciali/Surface e alcuni firmware 2024+ possono avere il toggle (es. "Enable Microsoft UEFI CA" nei menu Dell/Lenovo ThinkPad). Da trattare come **non noto per OEM** finche' non si prova.

### 6.3 La transizione 2011 -> 2023

- "Microsoft Corporation UEFI CA 2011" (quella che firma shim) e' scaduta il **26/27 giugno 2026**; "Windows Production PCA 2011" scade il **19 ottobre 2026**; KEK CA 2011 il 24 giugno 2026. **[V]** [LWN 1079808](https://lwn.net/Articles/1079808/), [MS KB5036210](https://support.microsoft.com/topic/kb5036210-deploying-windows-uefi-ca-2023-certificate-to-secure-boot-allowed-signature-database-db-a68a3eae-292b-4224-9490-299e303b450b).
- Le firme su binari **non vengono controllate rispetto alla data** dal firmware: *"Firmware generally ignores certificate expiry"*; uno shim firmato 2011 continua a funzionare dove la CA 2011 e' in `db`. Si rompe solo se il firmware **non ha la CA 2023** e riceve uno shim firmato **solo 2023**. **[V]** (LWN, sopra)
- Da ottobre 2025 Microsoft restituiva **due firme** per shim; dopo la scadenza le nuove sottomissioni hanno solo la 2023. **[V]** (LWN)
- **Il nostro shim e' firmato con entrambe** (verificato con `sbverify`, par. 2) -> funziona su firmware con solo-2011, con solo-2023 e con entrambe. **[V]** Il rischio futuro e' rinnovare lo shim con uno solo-2023 (quando Debian passera' a quello): su firmware senza CA 2023 romperebbe. **[V]** (stessa logica LWN) -> *tenere lo shim doppia-firma finche' Debian lo fornisce*; la flotta Windows vecchia e' proprio quella che non ha ricevuto la 2023 in `db`.
- Microsoft distribuisce la CA 2023 nelle `db` dei PC tramite Windows Update (dal 13/02/2024 il pacchetto puo' applicare "Windows UEFI CA 2023"; trigger di registro `HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot` `AvailableUpdates=0x40`). **[V]** (KB5036210, snippet). Attenzione: **"Windows UEFI CA 2023" (firma il boot loader Windows) non e' "Microsoft UEFI CA 2023" (firma shim/terze parti)**. **[V]** (KB5036210 le elenca separate: Windows UEFI CA 2023, Microsoft UEFI CA 2023, Microsoft Option ROM UEFI CA 2023, KEK 2K CA 2023). Aver ricevuto l'aggiornamento Windows non garantisce quindi la presenza della *Microsoft UEFI CA 2023* in `db`. **[I]**
- Gli aggiornamenti forzati delle db non sono sicuri su tutto l'hardware (alcune macchine rese inavviabili, alcune con danno permanente). **[V]** (LWN). **Noi non dobbiamo mai scrivere nelle db dal nostro script.** **[I]**

### 6.4 Rilevare da Windows

| Cosa | Comando | Note |
|---|---|---|
| Secure Boot attivo? | `Confirm-SecureBootUEFI` (True/False; errore su BIOS/non supportato) | cmdlet del modulo `SecureBoot`; richiede amministratore. **[V]** (stesso modulo: [Get-SecureBootUEFI](https://learn.microsoft.com/en-us/powershell/module/secureboot/get-securebootuefi): su BIOS stampa `Cmdlet not supported on this platform.`, senza privilegi `Unable to set proper privileges. Access was denied.`) |
| Variabili grezze | `Get-SecureBootUEFI -Name SecureBoot\|SetupMode\|PK\|KEK\|db\|dbx\|dbDefault ...` | Nomi accettati elencati nella doc. **[V]** |
| CA di terze parti in `db`? | `[Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).Bytes) -match 'Microsoft Corporation UEFI CA 2011'` (e `-match 'Microsoft UEFI CA 2023'`) | Il match sulla stringa e' euristico; meglio decodificare le EFI_SIGNATURE_LIST e leggere i subject con `X509Certificate2`: fatto e **provato [V, lab]** in `tools/win-lab/probe-windows.ps1`. |
| UEFI vs BIOS | `bcdedit /enum {current}` -> `path \Windows\system32\winload.efi` (UEFI) / `winload.exe` (BIOS) **[V parziale]** MS BCD UEFI: il path UEFI e' `winload.efi`; oppure registro `PEFirmwareType`: **RIFIUTATO [V, lab]**, il valore esiste solo in WinPE e manca su Windows 11; oppure `SetFirmwareEnvironmentVariable` con nome vuoto (par. 4.3) **[V]**. |
| `msinfo32` | "BIOS Mode: UEFI", "Secure Boot State: On", "Device Encryption Support" | `msinfo32.exe` e' nominato nella doc BitLocker per "Device Encryption Support: Meets prerequisites". **[V]** |
| Aggiornamento CA 2023 applicato | registro `...\Control\SecureBoot\Servicing` (es. `UEFICA2023Status`) e task `\Microsoft\Windows\PI\Secure-Boot-Update` | da terzi (checker/WAPT); la doc MS non e' stata aperta su questo. **[R]** |

### 6.5 Azioni fisiche tipiche

- **Spegnere Secure Boot** o **abilitare "Microsoft & 3rd party CA"** nel setup firmware (tasto F2/Del/F10; su Surface Volume Su). Ma attenzione a BitLocker (par. 7): **sospendere prima**.
- **MOK**: solo se servono moduli kernel non firmati (NVIDIA proprietario): conferma dalla console al primo avvio. **[V]** (wiki Debian: *"may only be confirmed directly from the console at boot time"*; gate esistente di `remote-deploy.sh`).

---

## 7. BitLocker / Device Encryption

### 7.1 Stato di fatto

- **Device Encryption** accende BitLocker da solo a fine OOBE, inizialmente con "clear key" (equivalente a protezione sospesa); la chiave di ripristino va a Entra ID / AD / **account Microsoft** (in tal caso l'account deve essere amministratore del dispositivo). Con soli account locali i dati sono cifrati ma "unprotected" (clear key resta). **[V]** [MS: BitLocker overview](https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/)
- Da Windows 11 **24H2** sono stati **rimossi** i prerequisiti DMA e HSTI/Modern Standby: piu' dispositivi (incluso Home) si cifrano da soli. **[V]** (stessa pagina). Su Home la chiave viene sempre caricata sull'account Microsoft. **[V, fonte secondaria]** (Slashdot/The Verge/pureinfotech via ricerca).
- Impedire l'auto-cifratura: `HKLM\SYSTEM\CurrentControlSet\Control\BitLocker` `PreventDeviceEncryption=1` (DWORD). **[V]** (stessa pagina).
- La ESP **non e' cifrata** (deve essere FAT32 in chiaro, "~350 MB consigliati, ~250 MB liberi dopo BitLocker"). **[V]** (stessa pagina) -> quindi **copiare i file sulla ESP funziona anche con BitLocker attivo**; leggere C: da GRUB no.

### 7.2 Rilevazione

```powershell
Get-BitLockerVolume | Select MountPoint,VolumeStatus,ProtectionStatus,EncryptionMethod,KeyProtector   # modulo BitLocker; Pro+ ma il cmdlet risponde anche in Home?  [R]
manage-bde -status                                                                                      # [R] strumento a riga di comando
Get-CimInstance -Namespace root\cimv2\Security\MicrosoftVolumeEncryption -ClassName Win32_EncryptableVolume   # [R] funziona anche dove i cmdlet mancano
```
`Suspend-BitLocker -MountPoint C: -RebootCount 0` sospende **a tempo indeterminato** (finche' `Resume-BitLocker`); senza `-RebootCount` vale **1** (riprende al prossimo riavvio); range 0-15; in sospensione la chiave e' in chiaro e *"BitLocker does not validate system integrity at start up"*. **[V]** [MS: Suspend-BitLocker](https://learn.microsoft.com/en-us/powershell/module/bitlocker/suspend-bitlocker)
La doc **non dice** se un riavvio verso un'applicazione non-Windows consuma il conteggio. Percio' per il nostro caso usare `-RebootCount 0` e `Resume-BitLocker` esplicito nel `disarm`. **[I]**

### 7.3 Perche' conta, dato che sovrascriviamo il disco

1. **Il percorso di successo non e' toccato**: tutto il disco viene riscritto, BitLocker sparisce con esso. **[I]**
2. **Il percorso di abort lo e'**: se l'arming riesce solo in parte (voce creata ma il firmware la ignora; shim rifiutato dal firmware; l'operatore annulla) e **Windows riparte**, si vuole che riparta *senza chiedere la chiave di ripristino* e *senza lasciare la voce di boot*. **[I]**
3. **Modello di rischio**: i PCR del TPM si azzerano a ogni reset; un tentativo di boot fallito di una nostra voce non lascia traccia nei PCR del boot successivo di Windows. Con profilo "PCR 7 + Secure Boot" (default con Secure Boot attivo **[R]**) cio' che conta e' l'insieme di chiavi/db/dbx e lo stato di Secure Boot; con Secure Boot spento il profilo usa PCR 0,2,4,11 **[R]**, piu' sensibile a modifiche di boot. Quindi **il rischio concreto non e' la nostra voce ma le modifiche al firmware che l'operatore potrebbe fare** (disattivare Secure Boot, abilitare la 3rd party CA, aggiornare le db): cambiano PCR 7 e fanno chiedere la chiave. **[I]**, basato su **[R]** (comportamento PCR). 
4. Dunque la regola d'oro: **chi entra nel setup firmware per cambiare Secure Boot deve prima aver sospeso BitLocker e avere in mano la chiave di ripristino** (account Microsoft: pagina "BitLocker recovery keys" **[V, secondario]**).

### 7.4 Ordine sicuro delle operazioni (proposta)

1. Sonda (sola lettura): BitLocker si/no, stato Secure Boot, ESP, spazio, rete. Niente modifiche.
2. Se BitLocker attivo: **chiedere conferma esplicita** + mostrare dove recuperare la chiave (e/o richiedere che l'operatore dichiari di averla) **prima** di qualunque modifica.
3. Copiare i file sulla ESP e verificarne lo SHA-256 (nessun effetto sull'avvio).
4. `Suspend-BitLocker -RebootCount 0` (solo se serve; vedi 7.3) **immediatamente prima** della creazione della voce.
5. Creare la voce, impostare la sequenza one-shot, rileggere e verificare, salvare lo stato di rollback in un file (`C:\ProgramData\unitotem\arm-state.json`: GUID, path, file copiati, stato BitLocker precedente, BCD export).
6. `shutdown /r`.
7. Se l'host non vede l'OTA entro il timeout (o Windows e' ripartito): `disarm` (rimuove voce+file, `Resume-BitLocker` se l'avevamo sospeso noi).

---

## 8. Tutto il resto che puo' morderci

| Tema | Fatto / rischio | Marca |
|---|---|---|
| **BIOS legacy / MBR** | `SetFirmwareEnvironmentVariable` fallisce, `Confirm-SecureBootUEFI` non supportato; il layout A/B nostro e' implementato "per amd64/UEFI e Raspberry con tryboot; BIOS legacy ... non ancora" (`cmd_deploy`). Su Windows BIOS servirebbe un percorso diverso (BCD+NTLDR/GRUB4DOS, MBR) e l'immagine A/B non lo supporta. **Fuori scope.** | [V] codice, [I] decisione |
| **Piu' dischi, nomi NVMe/SATA** | `select_disk` usa gia' i path stabili by-id/by-path e rifiuta dischi senza path stabile. Su Windows la sonda deve riportare `Get-Disk` (Number, Size, BusType, FriendlyName, SerialNumber, `IsBoot`, `IsSystem`) per far scegliere il disco; la corrispondenza con `/dev/disk/by-id` dentro l'OTA va fatta per **modello+seriale/WWN** (non per numero). | [V] codice, [I] mappatura |
| **Partizioni di ripristino OEM / "Reset this PC"** | Verranno cancellate: l'operatore deve saperlo (nessun modo di tornare a Windows OEM senza media). Dire in chiaro nel gate. Le partizioni OEM possono contenere la ESP o utility prima della Windows (la guida MS le colloca prima). | [V] (layout MS), [I] |
| **Dischi dinamici (LDM)** | Windows li gestisce con un MBR/GPT "protettivo" e un database LDM in coda; `sgdisk`/`sfdisk` del nostro engine riscrivono la tabella: si dovrebbe fare `wipefs`/azzerare i settori LDM finali. Non verificato. | [R] |
| **Fast Startup / ibernazione** | `shutdown /s` ibrida lo stato del kernel e lascia NTFS "sporco"; `shutdown /r` fa un riavvio completo e *non* usa fast startup (`/hybrid` va con `/s`). L'arming deve usare **`/r`**. Per noi irrilevante sul disco (viene cancellato), rilevante solo se lasciamo file su NTFS (opzione 5.3). | [V] (`/hybrid` richiede `/s`, doc shutdown); resto [R] |
| **Portatili a batteria** | Un'interruzione di corrente durante `partclone` su un laptop distrugge il disco: richiedere alimentatore collegato (WMI `Win32_Battery`/`BatteryStatus`, `Get-CimInstance Win32_Battery`). | [R]/[I] |
| **Wi-Fi-only** | L'OTA non ha driver/firmware Wi-Fi (par. 2) **e** nel percorso legacy non legge `unitotem-ota.conf`. Vedi 8.1. | [V]/[I] |
| **NIC senza driver nell'initrd** | Cablate: copertura larga (Intel, Realtek r8169, Broadcom, Aquantia, USB). Mancano: firmware `rtl_nic` (r8169 piu' recenti ne vogliono), `i40e`/`ice` firmware ecc.; Realtek 2.5G `r8125` e' fuori kernel (driver separato) **[R]**. Windows "driver-less": se la NIC non e' nell'albero kernel Debian non funziona (es. alcuni chip Killer/Realtek 8125 piu' vecchi). Mitigazione: adattatore USB-Ethernet (ax88179/cdc_ncm e' nell'initrd). | [V] lista moduli, [R] resto |
| **Windows on ARM (Snapdragon)** | Fuori scope: richiede immagine arm64 per tutt'altro firmware (non Raspberry), nessun supporto qui. | [I] |
| **Credenziali OTA fisse** | La finestra di arming espone SSH sulla 2222 con password nota `unitotem` e **poteri di cancellare il disco** su una LAN che per un PC Windows e' spesso aziendale/domestica non fidata. Mitigare: password per-deploy generata dall'host e scritta nel conf/cmdline, finestra breve, o limitare per IP sorgente. | [V] codice, [I] rischio |
| **Cambio di IP tra Windows e ambiente OTA** | Windows e il DHCP dell'initrd possono avere client-id diversi -> IP diverso. L'host (`wait_ota_reachable "$target_ip"`) deve ritrovare la macchina per **MAC** (la sonda lo riporta) con ARP/ping scan o mDNS. | [I] |
| **Aggiornamenti dbx / SBAT** | Se Windows Update aggiorna `dbx` revocando la versione del nostro shim/GRUB, la voce sara' rifiutata. Tenere shim/GRUB aggiornati; il fallimento e' sicuro (Windows riparte). | [R] |
| **Firmware che proteggono la ESP / hanno solo "Windows Boot Manager"** | Alcuni (HP Sure Start, Lenovo) ripristinano le voci o bloccano le modifiche. | [R] |
| **Lingua di Windows** | Parsing dell'output di `bcdedit`/`manage-bde` e' localizzato: preferire WMI/CIM o cmdlet (oggetti) a regex sul testo. | [R] |
| **PowerShell 5.1 vs 7, Constrained Language Mode, AppLocker/WDAC** | PC aziendali bloccati potrebbero rifiutare script non firmati; `Set-ExecutionPolicy -Scope Process Bypass` aiuta solo senza WDAC. | [R] |

### 8.1 Wi-Fi: cosa servirebbe

Stato: **non supportato oggi** nell'ambiente OTA su amd64 (nessun modulo/firmware Wi-Fi, e il conf non viene letto nel percorso legacy). **[V]/[I]**. Opzioni, dalla piu' economica:

1. **Richiedere cavo** (o adattatore USB-Ethernet) - zero codice; il probe Windows rifiuta se non c'e' un'interfaccia cablata attiva con IPv4 verso l'host. **[I]**
2. **Aggiungere al percorso legacy la lettura del conf**: far leggere a `configure_networking_ota` il conf anche quando `/boot-ota` non e' montato (p.es. passare `unitotem.net=...` sulla cmdline o montare la ESP per label/UUID passata in cmdline) - risolve static IP e Wi-Fi gia' previsto nel codice. **[I]**
3. **Includere nell'initrd moduli+firmware Wi-Fi** (`iwlwifi` + `iwlwifi-*.ucode`, `rtw88/rtw89`, `mt76`, `ath11k`, ... da `firmware-iwlwifi`, `firmware-realtek`, `firmware-atheros`, `firmware-misc-nonfree`) + `wpa_supplicant` (c'e' gia'). Costo: decine di MB per copertura ampia (**[R]**), in conflitto con il problema ESP. Il profilo si prende da Windows: `netsh wlan export profile name="<SSID>" folder="C:\x" key=clear` produce un XML con la chiave in chiaro **solo se il chiamante e' amministratore locale**, la cartella deve esistere, niente UNC. **[V]** [MS: netsh wlan](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-wlan). Da convertire in `OTA_WIFI_SSID_B64/PSK_B64` (ora `wpa_passphrase` -> solo WPA2-PSK; WPA3-SAE / 802.1X enterprise non coperti). **[I]**
4. **Firmware Wi-Fi che serve in due momenti**: anche il *sistema installato* (immagine) ha i firmware `firmware-linux-nonfree`/`misc-nonfree` (par. 2) ma serve la rete anche dopo, per OTA: cio' e' un tema separato dall'arming.

---

## 9. Lato Windows: come eseguire l'arming e la sonda

### 9.1 Tre modalita'

| Modalita' | Come | Pro | Contro |
|---|---|---|---|
| **A. Bundle autonomo** (consigliata per l'MVP) | cartella/zip con `arm-windows.ps1` + payload (kernel, initrd, shim, GRUB, `grub.cfg`) + manifest SHA-256; l'operatore lo lancia da PowerShell **come amministratore**; lo script esegue sonda+arming e stampa un blocco "KEY: value" da incollare/scaricare; l'host poi fa solo `wait_ota_reachable` | niente sshd su Windows, nessuna porta aperta, nessun problema di quoting, funziona anche dietro WinRM chiuso | richiede una persona al PC (ma comunque serve per scegliere cosa cancellare) |
| **B. OpenSSH Server** (come il flusso Linux) | `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`; `Start-Service sshd`; `Set-Service sshd -StartupType Automatic`; regola firewall `OpenSSH-Server-In-TCP` porta 22 (creata dall'installazione) **[V]** [MS: OpenSSH install](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse). Requisiti: Windows 10 1809 / Server 2019+, PowerShell 5.1, account Administrators; Windows Server 2025 lo ha preinstallato. **[V]** | `remote-deploy.sh` resta il solo pilota; `scp` del payload (111 MB) | l'utente deve prima abilitare sshd (un passo manuale: stessa difficolta' di A); per gli admin le chiavi vanno in `%programdata%\ssh\administrators_authorized_keys` con ACL solo SYSTEM+Administrators (`icacls ... /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`); shell di default `cmd.exe` (si cambia in `HKLM:\SOFTWARE\OpenSSH\DefaultShell`); solo `password` e `publickey`, **niente Entra** **[V]** [MS: sshd config](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration) |
| **C. WinRM / PowerShell Remoting** | `Enable-PSRemoting`, `Invoke-Command`/`Copy-Item -ToSession` | nativo Windows, oggetti strutturati | richiede configurazione (rete privata, TrustedHosts se fuori dominio); non c'e' nulla di simile nel flusso Linux; non verificato in questa sessione **[R]** |

Regola di `CLAUDE.md` da rispettare in B: **ogni** `ssh`/`scp` verso il target passa da `_sshpass` (o helper) - quindi serve un `ssh_win`/`scp_win` in `deploy/lib.sh` costruito su `_sshpass` (con una variabile `WIN_PASSWORD` distinta da `OTA_PASSWORD`, o l'autenticazione a chiave se si fa). **[V]** (CLAUDE.md) / **[I]** (design).

### 9.2 La sonda Windows (equivalente di `do_probe`)

Output a righe `KEY: value` identico nel formato, cosi' `print_probe`, `secure_boot_gate` e il resto non cambiano. **[I]**

| Chiave (oggi) | Equivalente Windows | Marca |
|---|---|---|
| `UNAME_M` | `$env:PROCESSOR_ARCHITECTURE` / `[Runtime.InteropServices.RuntimeInformation]::OSArchitecture` (AMD64 / ARM64) | [R] |
| `EFI` | PEFirmwareType==2 oppure `SetFirmwareEnvironmentVariable` ok (par. 6.4) | [V]/[R] |
| `SECUREBOOT` | `Confirm-SecureBootUEFI` -> 1/0, errore -> `unknown` (come oggi) | [V] cmdlet |
| (nuovo) `SB_3RDPARTY_CA` | stringa in `db` (par. 6.4): `2011`, `2023`, `both`, `none`, `unknown` | [R] |
| `HAVE_UNITOTEM` | sempre `0` (nessun `/etc/kiosk`) | [I] |
| `BOOTMNT`/`BOOTFREE` | ESP: `Get-Partition` con `GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'`, monta `mountvol S: /S`, spazio libero `[IO.DriveInfo]` | [R] |
| `MEMAVAIL` | `(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory` KB (ma conta la RAM *totale* per l'initrd: ~200 MB scompressi + page cache) | [R]/[I] |
| `NETIF/NETLINK/NETMODE/NETADDR/NETGW/NETDNS/WIFI_*` | `Get-NetAdapter`, `Get-NetIPConfiguration` (dhcp/static), tipo `PhysicalMediaType`/`NdisPhysicalMedium`, Wi-Fi via `netsh wlan export` | [R] |
| `DISK:` | `Get-Disk` (Number, Size, BusType, FriendlyName, SerialNumber, `IsBoot`/`IsSystem`) | [R] |
| (nuovo) `BITLOCKER` | par. 7.2 | [R] |
| (nuovo) `BATTERY`, `AC_POWER` | `Win32_Battery` | [R] |
| (nuovo) `FASTSTARTUP`, `HIBERNATE` | `powercfg /a`, `HiberbootEnabled` in `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power` | [R] |
| (nuovo) `MAC` | `Get-NetAdapter | % MacAddress` (serve all'host per ritrovare la macchina) | [R]/[I] |

Rilevare il sistema operativo dal lato host (`do_probe`): oggi un solo ssh con `bash -s`. Su Windows OpenSSH la shell di default e' `cmd.exe` **[V]** (MS sshd config), quindi `bash -s` fallisce; proposta: tentare prima `uname -m` (se risponde -> ramo Linux invariato), altrimenti `cmd /c ver` / `powershell -NoProfile -Command ...` e saltare al ramo Windows. **[I]** (In modalita' A la sonda gira localmente e non serve detection.)

### 9.3 Equivalente di `disarm`

`arm-windows.ps1 -Disarm` legge `arm-state.json` e: (1) `bcdedit /set {fwbootmgr} bootsequence {GUID} /remove`, (2) `bcdedit /delete {GUID}`, (3) cancella **solo i file elencati** in `arm-state.json` dalla ESP (e la cartella se vuota), (4) `Resume-BitLocker` solo se l'abbiamo sospeso noi, (5) rimonta/smonta la ESP, (6) opzionalmente `Resize-Partition` per riestendere C: se avevamo creato una partizione temporanea, (7) confronta `bcdedit /enum firmware` con la fotografia iniziale e avverte delle differenze. Deve essere **idempotente** e usabile anche dopo un crash a meta' (principio "redo over assume-done" della memoria utente). **[I]**
Mai `rm` con glob/variabili anche qui: percorsi letterali dallo state-file, un file alla volta (`Remove-Item -LiteralPath`). **[I]**

---

## 10. Design proposto

### 10.1 File nuovi / modificati

| File | Scopo |
|---|---|
| `deploy/windows/arm-windows.ps1` | Un solo script, tre modi: `-Probe` (stampa `KEY: value`), `-Arm -Bundle <dir>` (verifica SHA-256, ESP/partizione, copia, catena SB, grub.cfg, BitLocker, voce firmware, state-file, riavvio), `-Disarm`. PowerShell 5.1 compatibile. Nessuna dipendenza esterna. |
| `deploy/windows/make-bundle.sh` | Sull'host: assembla il bundle da `deploy/amd64/recovery-*`, shim/GRUB firmati presi **dall'immagine** (non da `work/`), `grub.cfg` stub per Windows, `manifest.sha256`, zip. |
| `deploy/windows/grub-windows.cfg` | Stub: `search --no-floppy --file --set=root /EFI/unitotem-ota/vmlinuz` poi `linux ($root)/EFI/unitotem-ota/vmlinuz unitotem.ota=1 console=tty0 ...` e `initrd ($root)/EFI/unitotem-ota/initrd.img`. NB: lo stub dell'immagine usa `--label EFI`, che su Windows **non** esiste (la ESP Windows di solito non ha quella label) -> serve ricerca per file o UUID. **[V]** (stub dell'immagine) / **[I]** |
| `deploy/lib.sh` | `ssh_win`/`scp_win` su `_sshpass` (solo modalita' B). |
| `deploy/remote-deploy.sh` | rilevazione OS target in `do_probe`; ramo `FIRMWARE=uefi-windows` in `cmd_deploy` (al posto di `push_recovery_kernel`+`arm_grub`); `cmd_disarm` ramo Windows; `secure_boot_gate` esteso con lo stato 3rd-party CA; nuovo gate BitLocker. |
| `kiosk/stage1-recovery-initrd.sh` (+ `ota-engine.sh`) | variante initrd "slim" (senza amdgpu/radeon) per Windows; lettura rete anche nel percorso legacy (par. 8.1); password OTA per-deploy. |

### 10.2 Sequenza passo-passo (modalita' A, UEFI, cablato)

1. Host: `make-bundle.sh` -> `unitotem-windows-<data>.zip` (+ `manifest.sha256`). L'operatore lo porta sul PC (condivisione di rete / `Invoke-WebRequest` verso `remote-deploy.sh serve`, che c'e' gia' come subcomando).
2. Su Windows, PowerShell amministratore: `.\arm-windows.ps1 -Probe` -> blocco `KEY: value`. Rifiuta (exit != 0, messaggio chiaro) se: non UEFI; ARM64; nessuna NIC cablata attiva; spazio ESP insufficiente **e** nessuna alternativa; batteria senza alimentatore. **[I]**
3. Gate (sull'host o interattivo nello script): mostra disco/i, partizioni che verranno distrutte (OEM recovery compresa), Secure Boot/CA, BitLocker, cosa serve di fisico. Conferma "SI" (stessa liturgia di `select_disk`).
4. `-Arm`: verifica manifest -> monta ESP -> controlla spazio -> copia in `\EFI\unitotem-ota\` -> rilegge SHA-256 -> scrive `grub.cfg` stub (e, se serve, in `\EFI\debian\` o nella cartella da cui lo shim carica GRUB: **da provare**, par. 6/11) -> BitLocker (7.4) -> voce firmware + sequenza one-shot -> verifica -> `arm-state.json` -> `shutdown /r /t 5`.
5. Il firmware avvia shim -> GRUB firmato -> kernel -> initrd -> `cmd_serve_fallback` (rete DHCP, dropbear :2222, schermata whiptail "OTA update mode"). **[V]** (stesso percorso del caso Linux).
6. Host: `wait_ota_reachable` (ritrovando l'IP per MAC) -> `run_ota_sequence` (invariato: dischi visti dall'engine con `unitotem-ota-engine probe`, scelta del disco, partizionamento, stream, `populate-bootfs --secure-boot shim|noshim`...). **[V]** (esiste `cmd_probe` nell'engine, citato nei commenti di `ota-engine.sh`).
7. Riavvio nel nuovo sistema. La voce NVRAM creata da Windows ora punta a un file inesistente: il firmware ricade su `\EFI\BOOT\BOOTX64.EFI` (l'immagine installa GRUB `--removable`, e con `--secure-boot shim` sostituisce BOOTX64.EFI con lo shim). Voci orfane "Windows Boot Manager" e "UniTotem OTA" restano in NVRAM; ripulirle con `efibootmgr` dall'ambiente OTA (e' nell'initrd) come ultimo passo, **o** accettarle. **[I]**

### 10.3 Abort e rollback

| Dove fallisce | Cosa succede | Cosa fa l'operatore/lo script |
|---|---|---|
| Prima della voce (copia, spazio, SHA) | Nessuna modifica al boot | `-Disarm` (pulisce i file) |
| Voce creata, firmware la ignora | Windows riparte da solo (BootNext non onorata) | host: timeout -> messaggio -> `-Disarm` |
| Firmware rifiuta shim (3rd-party CA assente, dbx) | "Security Violation" e il firmware prosegue con la boot order normale -> Windows riparte (comportamento tipico UEFI, **[R]**) | `-Disarm`; guida fisica per CA/Secure Boot **dopo** aver sospeso BitLocker |
| GRUB/kernel parte ma l'OTA non ha rete | schermata OTA su console, watchdog 1800 s -> **riavvio** -> Windows (BootNext consumata) | `-Disarm` |
| OTA parte e l'operatore cambia idea | `unitotem-ota-engine reboot`/riavvio prima del partizionamento = Windows intatto | `-Disarm` |
| **Dopo** l'inizio della scrittura dischi | Nessun ritorno: Windows e' distrutto. | Il gate lo dice; stessa semantica attuale ("il rollback non esiste mentre si scrive"). |

Principio (utente): ripetibile e idempotente, `STATE.md`-style checkpoint per ogni passo che modifica il sistema. **[I]**

### 10.4 Cosa e' testabile dove

| Cosa | Dove |
|---|---|
| Logica di `-Probe`/`-Arm`/`-Disarm`, parsing, state-file, ripristino | VM Windows in QEMU (OVMF + swtpm), anche Windows Server evaluation |
| Voce firmware / `BootNext` | QEMU/OVMF (stesso comportamento UEFI standard) ma **non** rappresentativo dei firmware OEM |
| Catena shim->GRUB->kernel con Secure Boot | QEMU: `OVMF_CODE_4M.secboot.fd` + `OVMF_VARS_4M.ms.fd` (chiavi Microsoft) gia' usati dall'altro agente; per "CA 3rd party assente" costruire un `VARS` senza quella CA (`virt-fw-vars`/`ovmfctl`/`ovmf-vars-generator`, **[R]**) |
| BitLocker + TPM | QEMU con `swtpm` (TPM 2.0): Windows 11 accende device encryption nella VM se i prerequisiti ci sono (**[V]** sulla politica 24H2, **[R]** sul comportamento in VM) |
| ESP da 100 MB / 260 MB, dischi multipli, Wi-Fi | QEMU con `autounattend.xml` (DiskConfiguration) per replicare i layout; Wi-Fi no (nessun Wi-Fi emulato di serie) |
| Comportamento di firmware reali (HP, Dell, Lenovo, Surface), Fast Startup reale, `dbx` reali | **Solo hardware** |

---

## 11. Come testare senza hardware

Non scaricare ora; questa sezione dice *come*. Host verificato **[V]**: `qemu-system-x86_64`, `swtpm`, `/usr/share/OVMF/OVMF_CODE_4M.{fd,ms.fd,secboot.fd,snakeoil.fd}` e `OVMF_VARS_4M.{fd,ms.fd,snakeoil.fd}` presenti; harness gia' esistente `work/sb-test/vm.sh` (altro agente, da leggere prima di scriverne uno nuovo).

### 11.1 Immagini Windows disponibili (stato 2026-10)

- **Microsoft Evaluation Center** (pagina letta): Windows 11 Enterprise **26H2** x64 e Arm64 e **Enterprise LTSC 2024** x64; **solo ISO** (nessun VHD); periodo **90 giorni**; nessuna chiave; "devi accedere con account Microsoft"; lingue incl. inglese/italiano; dimensione ISO non indicata nella pagina (**[R]** ~5-7 GB). **[V]** [evalcenter](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise). Estensione oltre 90 giorni (rearm, fino a ~270 giorni): claim di un blog giapponese, **[R]** non verificato.
- **Windows Server evaluation** (2022/2025): esiste nell'Evaluation Center (**[R]**, non aperto); utile perche' ha **lo stesso bcdedit/ESP/OpenSSH** (Server 2025 ha OpenSSH preinstallato **[V]**), non richiede TPM/Secure Boot per installarsi e la UI e' piu' semplice da automatizzare. Non rappresenta pero' Device Encryption ne' i profili OEM di un PC client. **[I]**
- **Windows 11 Dev Environment VM** (Hyper-V/VMware/VirtualBox/Parallels): **non disponibili dall'ottobre 2024**, nessun ritorno trovato (ultime fonti ~aprile 2025). **[V, secondario]** [Neowin](https://www.neowin.net/news/microsofts-official-windows-11-virtual-machines-are-no-longer-available/), [MS Q&A](https://learn.microsoft.com/en-us/answers/questions/2169617/download-of-testing-windows-11-hyper-v-vms). Da riverificare, la pagina developer potrebbe essere cambiata. 
- **Windows 11 IoT Enterprise LTSC** eval: compare tra i risultati dell'Evaluation Center (URL `download-windows-11-iot-enterprise-ltsc-eval`), non aperto. **[R]**
- **Windows PE/RE**: non va bene (non ha lo stack di installazione/BitLocker/OpenSSH di un Windows vero). **[I]**

### 11.2 Ricetta QEMU (da adattare al harness esistente)

```bash
# 1. disco e firmware (VARS copiato per-VM, scrivibile)
qemu-img create -f qcow2 win.qcow2 80G
cp /usr/share/OVMF/OVMF_VARS_4M.ms.fd win-vars.fd          # chiavi Microsoft gia' dentro  [V: file presente]
# 2. TPM 2.0 emulato
swtpm socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm/sock --daemon
# 3. avvio per l'installazione
qemu-system-x86_64 -machine q35,smm=on -enable-kvm -cpu host -m 8G -smp 4 \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
  -drive if=pflash,format=raw,unit=1,file=win-vars.fd \
  -chardev socket,id=chrtpm,path=tpm/sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -drive file=win.qcow2,if=none,id=d0 -device nvme,drive=d0,serial=win0 \
  -drive file=Win11_eval.iso,media=cdrom -device e1000e,netdev=n0 -netdev user,id=n0
```
(flag tipici **[R]**; `e1000e` e' riconosciuta da Windows senza driver aggiuntivi **[R]**; con `virtio-net`/`virtio-blk` serve l'ISO `virtio-win`). Windows 11 si installa con TPM 2.0 (swtpm) e Secure Boot (OVMF secboot) senza bypass; in alternativa `reg add HKLM\SYSTEM\Setup\LabConfig` `BypassTPMCheck`/`BypassSecureBootCheck` durante setup (**[R]**).
- **Automazione**: `autounattend.xml` su un secondo ISO (o su `-fda`/CD) con `DiskConfiguration` per scegliere ESP da 100/260/500 MB, `OOBE` saltato, utente admin con password nota, `FirstLogonCommands` che attiva OpenSSH Server e copia il bundle. **[R]** (schema noto ma da scrivere e provare: e' la parte con piu' incognite). Una volta installata, salvare uno **snapshot qcow2** (`qemu-img snapshot -c clean win.qcow2`) per ripartire in secondi a ogni test.
- **Scenari**: (a) SB off; (b) SB on + MS vars (qui lo shim deve passare); (c) SB on + VARS senza 3rd-party CA (deve fallire in sicurezza e Windows deve ripartire); (d) BitLocker acceso (verificare che `disarm` dopo un abort non chiede la chiave); (e) ESP da 100 MB (deve rifiutare o scegliere l'alternativa); (f) due dischi; (g) arming ma l'OTA non riceve host -> watchdog -> Windows riparte.
- **Dalla VM: la stessa console seriale/schermo** gia' usati dall'altro agente per l'immagine (`work/sb-test/vm.sh`); l'ambiente OTA e' raggiungibile via rete `user` con `hostfwd` sulla 2222. **[I]**

### 11.3 Cosa QEMU NON dimostra

Comportamento dei firmware OEM (che e' il rischio n.1), la gestione reale di `BootNext` da parte di HP/Dell/Lenovo/Surface, `dbx` reali, driver NIC reali, Fast Startup reale, batterie. Servono almeno 3-5 PC reali diversi (una Surface se si vuole coprire il caso 3rd-party CA disattivata). **[I]**

---

## 12. Stima, rischi, ordine di lavoro, punti di decisione

### 12.1 Stima (onesta; giorni-persona)

| Blocco | Giorni | Incognita principale |
|---|---|---|
| `arm-windows.ps1`: sonda + arming + disarm + state-file (modalita' A) | 2-3 | creazione voce firmware robusta (bcdedit vs WMI vs variabili UEFI) |
| `make-bundle.sh` + manifest + stub `grub.cfg` per Windows | 0,5-1 | dove cerca `grub.cfg` il GRUB firmato (prefix fisso) fuori da `EFI/BOOT`/`EFI/debian` |
| Initrd slim + rete anche nel percorso legacy (+ password per-deploy) | 1-2 | tocca lo stage1b e l'`ota-engine`; richiede ricostruzione (build) e test regressione sul flusso Linux/Pi |
| Integrazione in `remote-deploy.sh` (detect OS, ramo Windows, gate BitLocker, ricerca per MAC) | 1-2 | quoting/PowerShell se si fa anche la modalita' B (+1-2) |
| Harness QEMU+Windows (unattended, TPM, SB, snapshot, scenari a-g) | 2-4 | **la parte piu' incerta**: automatizzare l'installazione di Windows evaluation e il suo OOBE |
| Prove su hardware reale (3-5 PC) e correzioni | 2-4+ | firmware imprevedibili: non ha un limite superiore |
| **Totale MVP** | **~8-12** (UEFI, cablato, ESP capiente) **[I]** | |
| + Wi-Fi (moduli+firmware+WPA3/802.1X) | +3-5 | peso dei firmware vs spazio ESP |
| + restringimento C: / partizione temporanea | +2-3 | casi con file non spostabili; riestensione nel disarm |
| + BIOS legacy | non stimato | l'immagine A/B non lo supporta oggi |

### 12.2 Rischi in ordine di gravita'

1. **Firmware che ignorano/rimuovono la voce creata da Windows** (o non onorano `BootNext`) -> l'MVP non parte su certi PC. (**[V, forum]** esiste; frequenza ignota.) Mitigazione: variabili UEFI dirette, ripiego manuale col menu di boot, matrice di PC provati.
2. **Secure Boot + 3rd-party CA disattivata** (Surface, alcuni 2024+) -> serve intervento fisico nel setup, **con BitLocker da sospendere prima**. Mitigazione: rilevarlo, spiegare, offrire "annulla".
3. **Perdita accidentale di dati dell'utente** (il disco sbagliato, OEM recovery, l'utente non sa che Windows sparisce): serve un gate molto piu' esplicito di quello Linux. (**[I]**)
4. **ESP troppo piccola/piena** -> bundle slim o partizione temporanea; rischio di lasciare la ESP piena se l'arming si interrompe (disarm obbligatorio).
5. **Rete**: solo DHCP cablato nel percorso legacy; Wi-Fi assente; IP che cambia; la password fissa esposta in LAN mentre l'ambiente e' armato.
6. **Compatibilita' PowerShell/WDAC/lingua** su PC aziendali.
7. **Scadenza/rinnovo certificati**: shim futuro solo-2023 sui PC che non hanno la CA 2023.
8. **Stato BitLocker dopo abort**: basso se non si tocca il firmware e si usa `Resume-BitLocker` (**[I]**, non verificato).

### 12.3 Ordine di lavoro consigliato

1. **Giorno 0 (mezza giornata)**: verificare in QEMU/OVMF, senza Windows, i due punti che decidono tutto: (a) shim doppia-firma + GRUB firmato avviano il kernel di recovery da una voce `Boot####` creata a mano con `efibootmgr` in una cartella *diversa* da `EFI/BOOT`/`EFI/debian` (dove cerca `grub.cfg`?); (b) la dimensione reale dell'initrd slim. Costo basso, elimina la maggiore incognita tecnica non-Windows. **[I]**
2. Harness QEMU con **Windows Server evaluation** (piu' semplice) e solo dopo Windows 11 + swtpm + BitLocker.
3. `arm-windows.ps1` modalita' A, con `-Probe` per primo (sola lettura: sicuro da far girare su PC veri per raccogliere dati sulla flotta).
4. **Far girare solo la sonda sui PC reali che interessano**: costa poco e risponde a "quante macchine hanno ESP capiente / Secure Boot / 3rd-party CA / BitLocker / solo-Wi-Fi" prima di scrivere il resto. **[I]**
5. Arming reale, prima in VM, poi su 1 PC di prova (con il disco intercambiabile/dati di nessun valore).
6. Solo allora: modalita' B (SSH), Wi-Fi, partizione temporanea.

### 12.4 Punti di decisione per l'utente

1. **Rete**: pretendere cavo (o dongle USB-Ethernet), oppure investire nel Wi-Fi (par. 8.1)?
2. **Secure Boot**: richiedere "spento" (nessuno shim, intervento fisico, ma niente rischio CA) oppure "acceso con shim" (nessun intervento se la CA 3rd-party e' fidata, altrimenti intervento)? Oggi il gate offre shim/noshim/abort; su Windows `noshim` perde senso (la macchina non partirebbe nemmeno nell'OTA).
3. **Solo UEFI** (raccomandato) o anche BIOS legacy (non supportato dall'immagine A/B)?
4. **Operatore presente al primo riavvio?** (Serve comunque se SB/CA richiede il setup; consigliato sempre per il primo tentativo su una macchina.)
5. **Modalita' di arming**: bundle locale (A), SSH (B) o entrambe?
6. **Dove mettere i file**: solo ESP (rifiuta le macchine con ESP piccola) oppure anche partizione temporanea (piu' macchine, piu' rischio)?
7. **Gestione di BitLocker**: pretendere che sia gia' sospeso/spento dall'operatore, oppure sospenderlo noi con `Suspend-BitLocker`?
8. **Password dell'ambiente OTA**: accettare la fissa `unitotem` anche su LAN non fidate, o una per-deploy?
9. **Ambito di supporto**: quali PC provare? (Almeno una Surface se interessa il caso CA disattivata; un laptop Dell/HP/Lenovo consumer; un desktop.)
10. **Vale la pena?** Se l'unico scopo e' evitare una chiavetta su pochi PC, una chiavetta USB con l'ISO installer (`deploy/unitotem-kiosk-installer-*.iso` esiste gia' nel repo **[V]**) e' molto meno lavoro; lo script ha senso se i PC sono molti, remoti, o senza accesso fisico comodo.

---

## 13. Cosa NON ho potuto verificare

- **Il comportamento di `bcdedit ... bootsequence` su firmware reali** (provato solo su OVMF nel laboratorio, par. 15; nessuna pagina MS lo documenta per `{fwbootmgr}`).
- ~~Dove cerca `grub.cfg` il GRUB firmato~~: risolto [V, lab]: lo cerca nella propria cartella (`\EFI\unitotem\`), senza bisogno di `EFI/debian`.
- ~~Se il GRUB firmato include il modulo `ntfs`~~: risolto nel laboratorio (par. 15): c'e', ma non monta i volumi NTFS provati.
- **Frequenza reale** dei firmware che ignorano voci BCD; stato di default della 3rd-party CA per Dell/HP/Lenovo/ASUS/Acer (nessuna fonte primaria trovata).
- **Contenuto reale delle `db`** sui PC (la tecnica `-match` sulle stringhe e' ricordata, non provata), nonche' i valori di registro per lo stato dell'aggiornamento CA 2023 (la pagina KB aperta non li riporta).
- **Esito BitLocker dopo un abort** (E6 non eseguito; nel laboratorio C: risulta gia' cifrato con chiave in chiaro).
- **Dimensione effettiva dell'initrd slim**, **spazio libero tipico delle ESP**, **dimensione ISO di Windows evaluation**: stime/ricordi.
- **Pagine non aperte**: Grub2Win, iVentoy, WDS/MDT, Intel AMT, Rufus (solo ricordi, marcati [R]); la ricerca per Grub2Win non ha trovato documentazione.
- Un'ulteriore ricerca dedicata ai post di forum citati (Arch/Lemmy/Fedora) non e' stata fatta oltre agli snippet: li tratto come indizi, non come prove.

---

## 14. Fonti

Primarie / ufficiali (lette in questa sessione salvo diversa indicazione):

- Debian win32-loader, sorgente: https://salsa.debian.org/installer-team/win32-loader (file `s_install.nsi`, `include/bootcfg.nsh`, `debian/changelog` dal tarball master)
- Debian micronews, supporto UEFI/Secure Boot di win32-loader: https://micronews.debian.org/2021/1628987476.html
- Debian wiki Secure Boot: https://wiki.debian.org/SecureBoot
- MS, BCD System Store Settings for UEFI: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/bcd-system-store-settings-for-uefi
- MS, `bcdedit /enum`: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--enum
- MS, `bcdedit /bootsequence`: https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--bootsequence
- MS, UEFI/GPT partitions (ESP, MSR, recovery): https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions
- MS, `Get-SecureBootUEFI`: https://learn.microsoft.com/en-us/powershell/module/secureboot/get-securebootuefi
- MS, KB5036210 (Windows UEFI CA 2023 e le altre CA 2023): https://support.microsoft.com/topic/kb5036210-deploying-windows-uefi-ca-2023-certificate-to-secure-boot-allowed-signature-database-db-a68a3eae-292b-4224-9490-299e303b450b
- MS, BitLocker overview (Device Encryption): https://learn.microsoft.com/en-us/windows/security/operating-system-security/data-protection/bitlocker/
- MS, `Suspend-BitLocker`: https://learn.microsoft.com/en-us/powershell/module/bitlocker/suspend-bitlocker
- MS, `Resize-Partition`: https://learn.microsoft.com/en-us/powershell/module/storage/resize-partition
- MS, `SetFirmwareEnvironmentVariable`: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setfirmwareenvironmentvariablea
- MS, `shutdown`: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/shutdown
- MS, `netsh wlan`: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/netsh-wlan
- MS, OpenSSH Server install: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse
- MS, OpenSSH Server configuration: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration
- MS Evaluation Center, Windows 11 Enterprise: https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise
- LWN, scadenza certificati Secure Boot 2026: https://lwn.net/Articles/1079808/

Secondarie (forum, giornali, snippet di ricerca; indizi):

- wubiuefi issue 15: https://github.com/hakuna-m/wubiuefi/issues/15
- Arch forum (voce BCD / NVRAM): https://bbs.archlinux.org/viewtopic.php?id=225683
- Fedora discussion (shim da BCD): https://discussion.fedoraproject.org/t/failed-to-boot-shim-efi-but-boots-grub-anyway-file-s/90143
- Ubuntu-devel (drop Wubi): https://lists.ubuntu.com/archives/ubuntu-devel/2013-April/036994.html , https://lists.ubuntu.com/archives/ubuntu-devel/2013-April/037058.html ; Phoronix: https://www.phoronix.com/news/MTM0MDY ; Wikipedia: https://en.wikipedia.org/wiki/Wubi_(software)
- Ventoy FAQ Secure Boot: https://github.com/ventoy/Ventoy/issues/3536
- Dell forum `forcepxeonnextboot`: https://www.dell.com/community/Optiplex-Desktops/3060-does-not-support-forcepxeonnextboot/m-p/6178920
- Surface 3rd-party CA: https://support.eset.com/en/kb8389-enable-3rd-party-certificates-in-secure-boot-for-eset-endpoint-encryption-and-eset-full-disk-encryption , https://docs.matrix42.com/en_US/3604148_computer-does-not-boot-with-secure-boot-enabled
- Operese: https://www.neowin.net/news/windows-11-is-unsupported-this-app-automatically-moves-important-windows-10-data-to-linux/ , https://betanews.com/2025/07/22/saying-no-to-windows-11-just-got-easier-operese-automatically-transfers-your-windows-10-files-and-settings-to-linux/
- Windows 11 Dev VM non disponibili: https://www.neowin.net/news/microsofts-official-windows-11-virtual-machines-are-no-longer-available/ , https://learn.microsoft.com/en-us/answers/questions/2169617/download-of-testing-windows-11-hyper-v-vms
- Kexec Windows (inverso): https://www.phoronix.com/news/Google-Kexec-Windows-Linux

Nel repo: `deploy/remote-deploy.sh`, `deploy/ota-engine.sh`, `deploy/lib.sh`, `kiosk/files/unitotem-ota-arm`, `kiosk/stage3-image.sh`, `kiosk/stage1-packages.sh`, `AB-DESIGN.md`, `API-OTA.md`, `work/sb-test/{STATE.md,vm.sh,signed/}`, `work/windows-research/STATE.md`.

---

## 15. Risultati del laboratorio (Windows 11 + OVMF Secure Boot, 2026-10-13)

Laboratorio: dominio libvirt `win11-lab` = clone di un Windows 11 Pro 24H2 (italiano, build 26200), OVMF con Secure Boot attivo e chiavi Microsoft, swtpm, NIC e1000e,
disco SATA 64 GB (ESP 100 MB). Helper e istruzioni: `tools/win-lab/` (README). Log grezzo con orari: `work/win-lab/STATE.md`; screenshot: `work/win-lab/shots/`;
log seriali: `work/win-lab/logs/`. Marche: **[V]** osservato qui (con il come), **[I]** inferenza, **[R]** ricordo. **Limite generale: OVMF non e' un firmware OEM**: quanto segue vale per il
comportamento UEFI standard e non dice nulla su HP/Dell/Lenovo/Surface.

### 15.1 E0 - gli snapshot libvirt NON ripristinano l'NVRAM (raw)
- **[V]** Scritto da Windows (`SetFirmwareEnvironmentVariableEx`, `tools/win-lab/nvram-var.ps1`) un `BootOrder` diverso e una variabile `LabMarker`; spento, `snapshot-revert base-ssh`, riavviato: **entrambi erano ancora li'**. Con NVRAM `raw` il revert lascia voci di boot e variabili MOK. (Il test `bcdedit /copy` fatto prima era inconcludente: quella voce vive nel file BCD sull'ESP.)
- **[V]** Correzione: `<nvram format='qcow2'>` su un file creato con `qemu-img convert -f raw -O qcow2` dal template (libvirt 12 rifiuta la conversione automatica: "conversione del template nvram in un altro formato target non e' supportata"). Nuovo baseline `base-nvram`; stesso test ripetuto: marker assente, `BootOrder` originale. Procedura in `tools/win-lab/README.md`.
- **Stato del TPM (swtpm)**: non e' negli snapshot. **[I]** Per BitLocker: il disco torna indietro, il TPM no; i protettori sigillati sotto la SRK restano utilizzabili, ma indici NV e contatori sono quelli "di adesso". Non provato (E6 non eseguito).

### 15.2 E1 - sonda Windows (`tools/win-lab/probe-windows.ps1`)
**[V]** Output completo in `work/win-lab/probe-baseline.txt`. Punti salienti: Secure Boot attivo (`Confirm-SecureBootUEFI`), `SetupMode=0`; PK/KEK = Ubuntu OVMF + Microsoft KEK 2011 e 2023; `db` = Windows Production PCA 2011, Windows UEFI CA 2023, **Microsoft Corporation UEFI CA 2011, Microsoft UEFI CA 2023**, Option ROM CA 2023 (`SB_3RDPARTY_CA: both`); `dbx` 431 hash. ESP 100 MB con 64,6 MB liberi; C: 63 GB (34 GB liberi); NIC "Intel 82574L" (e1000e) in DHCP; RAM 8 GB.
Scoperte che correggono le note: (1) `PEFirmwareType` nel registro **non esiste su Windows 11** (solo WinPE): per UEFI/BIOS si usa il path `winload.efi` in `bcdedit /enum {current}` (indipendente dalla lingua); (2) **C: risulta `FullyEncrypted`, protezione disattivata, nessun protettore** (device encryption con chiave in chiaro) anche con un account locale: BitLocker e' la norma, non l'eccezione; (3) la decodifica dei subject dalle EFI_SIGNATURE_LIST funziona, il match su stringa non serve.

### 15.3 E2 - voce di boot per la catena firmata, creata da Windows
Comandi (tutti **[V]**, `work/win-lab/logs/e2-*.txt`):
```
mountvol S: /S                                   :: monta la ESP
(copia di shimx64.efi, mmx64.efi, grubx64.efi firmati + grub.cfg in S:\EFI\unitotem\ : 4,6 MB, hash verificati)
bcdedit /copy {bootmgr} /d "UniTotem OTA"        :: -> {GUID}
bcdedit /set {GUID} device partition=S:
bcdedit /set {GUID} path \EFI\unitotem\shimx64.efi
bcdedit /set {fwbootmgr} displayorder {GUID} /addfirst     :: persistente
bcdedit /set {fwbootmgr} bootsequence {GUID}               :: one-shot
```
- **[V]** `/copy {bootmgr}` crea una **vera `Boot0005` in NVRAM** (letta con `nvram-var.ps1 -Boot`: "UniTotem OTA", path `\EFI\unitotem\shimx64.efi`). `bootsequence` scrive **`BootNext=0005`**; `displayorder {GUID} /remove` toglie la voce da `BootOrder` ma la lascia in NVRAM.
- **[V]** One-shot confermato: dopo l'uso `BootNext` sparisce e Windows riparte da solo (anche dopo panic del kernel + reset).
- **[V]** Con `shutdown /r`, OVMF (Secure Boot ON) avvia **shim -> GRUB firmato -> kernel**: seriale `EFI stub: UEFI Secure Boot is enabled`, `Kernel is locked down from EFI Secure Boot`, `Loaded X.509 cert 'Debian Secure Boot CA'` (`logs/e2-serial.log`, `shots/e2-kernel-panic-secureboot-chain.png`; il panic e' atteso: nessun initrd in questa prova).
- **[V] Risolta l'incognita del "prefix fisso"**: il GRUB firmato legge `grub.cfg` dalla **propria cartella** (`\EFI\unitotem\`); non serve `EFI/debian`. Lo stub dell'immagine (`search --label EFI`) non va usato su Windows: `grub.cfg` proprio con `search --no-floppy --file|--label`.

### 15.4 E3 - dove mettere kernel+initrd (101,5 MiB; la ESP ha 61,6 MiB liberi)
- **(a) NTFS letto dal GRUB firmato: NON funziona [V].** `lsmod` mostra `ntfs` gia' dentro (con fat, ext2, xfs, btrfs, f2fs, zfs, iso9660, jfs, hfsplus, luks/luks2, lvm; **non** ntfscomp ne' exfat: `insmod` -> `file not found`), ma `ls (hd0,gptN)/` risponde `unknown filesystem` su entrambi i volumi NTFS provati (uno creato da Windows 11 e decifrato, e la partizione WinRE), che Linux (`blkid`) riconosce come ntfs. Causa non indagata. `insmod` di un `.mod` non firmato dalla ESP -> **`error: prohibited by secure boot policy`** (`logs/e3c-serial.log`). **C: e' comunque BitLocker** (GRUB: `unknown filesystem`).
- **(b) Restringere C: e creare una FAT32: funziona [V]** (`logs/e3-part.txt`): `Resize-Partition -DriveLetter C -Size <-400MB>` online in pochi secondi anche con C: cifrato (`SizeMin` 37,8 GB); `New-Partition` + `Format-Volume -FileSystem FAT32`; il GRUB firmato legge la FAT32 e `search --label` la trova. **Trappola [V]**: Windows 11 24H2 ha **cifrato con BitLocker la nuova partizione** appena creata (`-FVE-FS-` nel primo settore, visto con `cat (hd0,gpt4)+1` da GRUB): GRUB vede "unknown filesystem". Serve `manage-bde -off X:` (pochi secondi su 256 MB) prima di copiare i file (impedire l'auto-cifratura con `PreventDeviceEncryption`: **non provato**). GRUB numera le partizioni per posizione, Windows per ordine di creazione: usare le etichette.
- **(c) initrd slim**: non ricostruito (come richiesto). **[I]** Per stare nei 61,6 MiB liberi servirebbero kernel+initrd <= ~55 MiB, cioe' initrd <= ~43 MiB; togliere amdgpu (81,5 MB non compressi) porta alla stima precedente di ~50-60 MB (da misurare): **al limite, non garantito**. Con ESP da 260/500 MB basta; altrimenti partizione FAT32 (b).

### 15.5 E4 - ambiente OTA avviato da Windows con Secure Boot attivo
- **[V]** Kernel+initrd dalla FAT32 (`linux ($root)/vmlinuz unitotem.ota=1 nomodeset console=tty0 console=ttyS0,115200`, `initrd ($root)/initrd.img`) attraverso la catena firmata: l'ambiente OTA parte, prende DHCP sulla e1000e (**stesso IP 192.168.122.88 di Windows**, stesso MAC), schermo: `OTA update mode / Reason: booted from the resident fallback image / Address / Port: 2222 / Waiting for commands over SSH...` (`shots/e4-ota-screen-from-windows-esp-secureboot.png`, bassa risoluzione).
- **[V]** Dall'host `ota_ssh` su 2222 risponde; `dmesg`: `Kernel is locked down from EFI Secure Boot`; `unitotem-ota-engine probe` ok (`UNITOTEM_EFI=1`). Il percorso "legacy" (`unitotem.ota=1`) usa DHCP, come dedotto.
- **STRETCH [V]: installazione completa.** `deploy/make-parts.sh --arch amd64 --image deploy/amd64/kiosk-2026-10-12-amd64.img.xz` (docker, utente normale, ~18 min; ha ignorato `--out` e scritto in `deploy/amd64/kiosk-2026-10-12-amd64.parts`). `cmd_recover` e' **solo uno stub** (si ferma con un messaggio): ho scritto `tools/win-lab/recover-driver.sh`, che esegue le vere `run_ota_sequence()`/`populate_bootfs_step()` estratte da `remote-deploy.sh` con `SB_MODE=shim`. Esito: GPT riscritta, ESP+ROOT_A+ROOT_B+DATA ripristinate, catena attivata (`EFI/BOOT/BOOTX64.EFI`=shim), riavvio: **UniTotem parte con Secure Boot attivo** (`shots/e4-unitotem-booted-under-secureboot.png`; via ssh: `Kernel is locked down from EFI Secure Boot`, efivar `SecureBoot`=1; `BootCurrent`=0002 = voce auto-creata da OVMF). La voce orfana `Boot0005 "UniTotem OTA"` resta in NVRAM; le voci Windows erano gia' sparite dal `BootOrder`.
- **BUG TROVATO [V]** (`work/win-lab/logs/e4-install-attempt1.log`): la prima installazione e' fallita a meta' (disco con tabella nuova) perche' l'initrd di recovery amd64 (sha256 `4967187009a0...`, build 01:32 del 13/10) **non contiene `tr` ne' `cmp`**, usati da `deploy/ota-engine.sh:432` (padding del grubenv: `tr ' ' '#'` -> "scrittura grubenv fallita") e `:572` (`cmp -s` sullo shim -> "lo shim scritto non coincide"). `lsinitramfs`: ci sono cat/cp/dd/mv/sha256sum/sync, mancano tr e cmp. Aggirato **solo nel laboratorio** copiando in RAM il busybox statico dell'host come `tr`/`cmp`; **nessuna modifica al repo**: da correggere (aggiungere `tr` e `cmp` all'initrd, o riscrivere i due punti). Senza, ne' `set-default-recovery` (A/B) ne' `populate-bootfs --secure-boot shim` funzionano.

### 15.6 E5 - controlli negativi e altre strade
- **(i) GRUB non firmato [V]**: voce su `\EFI\unitotem\grub-unsigned.efi`: seriale `BdsDxe: failed to load Boot0006 ... Access Denied -- rejected probably by Secure Boot`, poi OVMF passa da solo alla voce successiva (Windows) (`logs/e5i-serial.log`). Nessun danno. OVMF non mostra nulla a schermo (su firmware reali di solito compare una schermata "Security Violation": **non verificato**).
- **(ii) NVRAM senza la CA terze parti [V]** (`pip install virt-firmware` in un venv funziona; `virt-fw-vars -i OVMF_VARS_4M.fd --enroll-microsoft --microsoft-db win+rom23 --microsoft-kek 2023 --sb` -> `db` = solo Windows UEFI CA 2023 + Option ROM CA 2023): con UniTotem gia' installato (shim in `EFI/BOOT/BOOTX64.EFI`) il firmware risponde `failed to load Boot0002 ... Access Denied -- rejected probably by Secure Boot`, `No bootable option or device was found`, `Press any key to enter the Boot Manager Menu` (`logs/e5ii-serial.log`, `shots/e5ii-shim-rejected-no-3rdparty-ca.png`). L'utente vede una macchina che non parte. Vie d'uscita: tutte dal setup firmware (abilitare "Microsoft & 3rd party CA", aggiungere hash/cert a `db`, o spegnere Secure Boot) = **presenza fisica**; **non provate**. (Provato sul disco gia' installato, non dal Windows originale: per Windows la conseguenza e' quella di (i), la voce viene scartata e riparte Windows.)
- **(iii) Un amministratore puo' arruolare chiavi senza il setup firmware? No per `db`; per MOK solo con console [V]**: `Set-SecureBootUEFI -Name db` con payload non firmato -> `Dati di autenticazione non corretti: 0xC0000022`, `db` invariato (`logs/e5-setsb.txt`); servirebbe un payload autenticato firmato con la chiave KEK. Scrivere da Windows la variabile `MokNew` di shim (certificato self-signed in EFI_SIGNATURE_LIST, attributi NV|BS) **funziona** e al boot successivo shim lancia MokManager: `Press any key to perform MOK management / Booting in 10 seconds` (`logs/e5iii-serial.log`): serve un tasto sulla console entro 10 s (+ conferma). **Non l'ho premuto**: la conferma finale non e' provata. **[I]** Per la nostra catena il MOK non serve (shim contiene la CA Debian) e non aiuta se shim non parte.
- **(iv) Tutte le strade per avviare il nostro kernel con Secure Boot ON**

| # | Strada | Presenza fisica | Si basa su | Stato |
|---|---|---|---|---|
| 1 | Voce firmware da Windows (`bcdedit`) -> shim (MS) -> GRUB firmato -> kernel; file su ESP + FAT32 ricavata da C: | **No** (se la 3rd-party CA e' in `db`) | Microsoft UEFI CA 2011/2023 in `db`; firmware che onora la voce/BootNext | **Provata** (OVMF), installazione completa compresa |
| 2 | Come 1 con kernel/initrd su ESP capiente (>= ~110 MB liberi) | No | idem + ESP grande | Parziale: catena+kernel provati, initrd su ESP no (qui 61 MB liberi) |
| 3 | Kernel/initrd su NTFS letto da GRUB | - | modulo ntfs del GRUB firmato | **Non funziona** (unknown filesystem); C: e' BitLocker |
| 4 | Sostituire `\EFI\BOOT\BOOTX64.EFI` / `bootmgfw.efi` | No | - | Non provata (sconsigliata: Windows Update la ripristina, rompe l'abort) |
| 5 | Spegnere Secure Boot nel setup firmware | **Si** | setup firmware (con BitLocker: sospendere prima, [R]) | Non provata |
| 6 | Abilitare "Microsoft & 3rd party CA" (Surface e simili) | **Si** | toggle OEM | Non provata; senza, shim e' rifiutato (provato in E5ii) |
| 7 | Arruolare hash/cert in `db` dal setup | **Si** | UI firmware | Non provata; da Windows `Set-SecureBootUEFI` e' rifiutato (E5iii) |
| 8 | MOK: `MokNew` scritta da Windows + MokManager | **Si** (console, tasto entro 10 s) | shim gia' avviabile | Richiesta provata, conferma no; non aiuta se shim non parte |
| 9 | Tool OEM da Windows (Dell Command Configure, HP BCU, Lenovo WMI, Surface SEMM) per cambiare SB/CA | Forse no | tool e modello specifici | Non provata [R] |
| 10 | Boot di rete (PXE/HTTP) con shim firmato | Dipende | firmware con voce di rete + infrastruttura | Non provata [R] |
| 11 | GRUB o kernel non firmati | - | - | **Rifiutati** dal firmware (E5i) |

### 15.7 Verdetto e stima: cosa cambia
- "Fattibile" **si rafforza**: Windows -> `bcdedit` -> shim -> GRUB firmato -> OTA -> installazione completa -> UniTotem con Secure Boot e' stato percorso fino in fondo (su OVMF), senza azioni fisiche quando la 3rd-party CA e' in `db`.
- Restano da fare: `grub.cfg` per Windows (cartella propria), spazio (ESP da 100 MB con 61 MB liberi **non basta**: partizione FAT32 ricavata da C: **con `manage-bde -off`** subito dopo la creazione, oppure initrd slim), correggere `tr`/`cmp` nell'initrd, implementare davvero `recover` (oggi stub).
- Stima: MVP invariato (8-12 giorni); **+1 giorno** per gestire bene la partizione temporanea (ridimensionamento, decifratura, ripristino di C: nel disarm); l'incognita "GRUB legge NTFS" e' chiusa in negativo.
- **Non fatto**: E6 (BitLocker con protettore TPM, `Suspend-BitLocker -RebootCount`, chiave di ripristino dopo cambio di catena): restano [R]/[I] nei par. 7.2-7.3.
