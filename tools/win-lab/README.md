# Laboratorio Windows 11 + OVMF Secure Boot (libvirt)

Strumenti per provare, senza hardware, come partire da un Windows 11 in esecuzione e avviare l'ambiente OTA di UniTotem con Secure Boot
ATTIVO. Risultati e metodo: `WINDOWS-INSTALL-NOTES.md`, sezione "Risultati del laboratorio". Questa cartella contiene solo gli helper:
**niente chiavi o password** (la chiave SSH `id_lab`, `lab-password.txt` e i `labtools.*` restano in `work/win-lab/`, fuori da git).

## Il laboratorio

- dominio libvirt `win11-lab` (`qemu:///system`) = clone completo di un Windows 11 Pro 24H2 italiano; il `win11` dell'utente non si tocca MAI.
- UEFI con Secure Boot attivo e chiavi Microsoft (`OVMF_CODE_4M.ms.fd`), TPM 2.0 emulato (swtpm), 8 GB RAM, 4 vCPU, NIC e1000e su rete `default`, disco SATA 64 GB.
- accesso: SSH come `lab` (amministratore, chiave `work/win-lab/id_lab`, PowerShell 5.1).

## File

| File | Cosa fa |
|---|---|
| `lab.sh` | `start`, `wait`, `stop`, `revert [SNAP]` (default `base-nvram`), `snap NAME`, `list`, `ssh 'comando powershell'`, `put LOCALE [REMOTO]`, `shot FILE.png` |
| `winkeys.py` | digita nella console della VM con `virsh send-key`: `text` (layout italiano, per Windows), `ustext` (layout US, per GRUB e menu del firmware), `key`, `shot` |
| `gcmd.sh` | scrive un comando al prompt di GRUB (layout US), Invio, screenshot |
| `serialcap.sh` | cattura la console seriale (ttyS0) in un file: li' escono anche i messaggi di OVMF (`BdsDxe: loading Boot0005 ...`), che a schermo non si vedono |
| `probe-windows.ps1` | sonda di sola lettura lato Windows (UEFI/BIOS, Secure Boot, db/KEK/PK decodificate, BitLocker, dischi, ESP, NIC, RAM): seme della futura sonda Windows |
| `nvram-var.ps1` | legge/scrive variabili UEFI grezze da Windows e decodifica `Boot####`/`BootOrder`/`BootNext` |

## Baseline e NVRAM: attenzione

1. **Il ripristino di uno snapshot libvirt NON ripristina l'NVRAM UEFI se questa e' un file `raw`** (default di libvirt): voci di boot, `BootOrder`
   e variabili MOK restano quelle dopo l'esperimento (provato: una variabile `LabMarker` e un `BootOrder` modificato sopravvivevano al revert).
   Il dominio e' quindi definito con `<nvram format='qcow2'>` su `work/win-lab/nvram/win11-lab_VARS.qcow2`, creato con
   `qemu-img convert -f raw -O qcow2 /usr/share/OVMF/OVMF_VARS_4M.ms.fd ...` (libvirt 12 non converte il template da solo:
   "conversione del template nvram in un altro formato target non e' supportata"). Gli snapshot interni includono allora anche l'NVRAM
   (provato: marker assente e `BootOrder` originale dopo il revert). XML del dominio: `work/win-lab/lab-domain.xml`.
2. Il baseline e' lo snapshot **`base-nvram`** (VM spenta). Prima di ogni esperimento: `lab.sh stop; lab.sh revert base-nvram; lab.sh start`.
   `base-ssh` (il vecchio baseline) NON include l'NVRAM: non usarlo.
3. **Lo stato di swtpm (TPM) non fa parte degli snapshot del disco.** Dopo un revert il disco torna indietro ma il TPM no: per BitLocker
   significa che i protettori TPM sul disco (sigillati sotto la SRK) restano validi finche' la SRK e' la stessa, ma ogni stato nel TPM
   (indici NV, contatori anti-hammering) e' quello "di adesso". Per esperimenti BitLocker conviene fare snapshot a VM spenta e sapere che
   il TPM non torna indietro (vedi il capitolo BitLocker nelle note).
4. Windows impiega alcuni minuti a rispondere via SSH dopo un avvio a freddo: i cicli di attesa vanno con timeout, in background.

## Trucchi appresi

- `Rd` in PowerShell e' un alias di `Remove-Item`: mai chiamare una funzione `Rd`.
- Windows 11 24H2 cifra con BitLocker (chiave in chiaro, "protezione disattivata") anche le **nuove partizioni di dati** appena create: GRUB
  vede `-FVE-FS-` e "unknown filesystem". Dopo la creazione serve `manage-bde -off X:`.
- Partizioni: Windows e GRUB le numerano in modo diverso (GRUB per posizione): usare le etichette (`search --label`).
