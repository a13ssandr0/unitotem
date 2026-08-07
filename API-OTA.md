# API OTA — rilevazione modifiche e conferma del deploy

Documento per chi implementa il frontend nel progetto `unitotem-manager`. Qui c'è solo il **contratto
backend**: comandi, formato dei dati, codici di uscita e la sequenza da rispettare. Nessuna scelta di
interfaccia è imposta.

## Il problema che risolve

Un OTA sostituisce **l'intera partizione ROOT**. Tutto ciò che è stato installato o modificato sul sistema
in esecuzione viene distrutto. Prima non veniva nemmeno segnalato: l'aggiornamento e la perdita di lavoro
altrui erano indistinguibili.

Il backend risponde a due domande separate:

1. *cosa è cambiato rispetto all'immagine installata?* → `unitotem-ota-changes`
2. *l'operatore ha visto e accettato proprio quelle modifiche?* → `--accept-changes <digest>`

## Perimetro: cosa viene considerato

| Percorso | Supporto | Sopravvive all'OTA? | Nel rapporto? |
|---|---|---|---|
| `/usr` `/boot` `/opt` `/srv` `/home` `/media` `/mnt` | ROOT | **No** | **Sì** |
| `/etc` | overlay su DATA | Solo la whitelist `ota-preserve.list` | No |
| `/var` | overlay su DATA | No, azzerato | No |
| `/root` | overlay su DATA | Sì | No |
| `/var/lib/dpkg` | ROOT (ancorato) | No | Sì, come database |

`/etc`, `/var` e `/root` sono esclusi di proposito: sono overlay con regole proprie al momento del deploy.
Includerli produrrebbe solo rumore — a build time `/var` è una directory normale, a runtime è un overlay,
quindi ogni file sotto di esso risulterebbe mancante su ogni dispositivo.

## Comando sul dispositivo

```
/usr/sbin/unitotem-ota-changes check [--json]
```

**Codici di uscita** — da distinguere sempre, `1` non è un errore:

| Codice | Significato |
|---|---|
| `0` | nessuna modifica |
| `1` | modifiche rilevate (esito normale, non un errore) |
| `2` | il controllo stesso è fallito (baseline assente, argomenti errati) |
| `127` | comando assente: immagine anteriore a questa funzione |

**Costo**: dipende dalla cache del filesystem, e la differenza è grande abbastanza da dover dimensionare i
timeout sul caso peggiore. Misurato su Raspberry Pi 4: **~1m20s alla prima esecuzione dopo un riavvio**
(cache fredda, legge 87 MB dalla SD e attraversa 44.000 file), **~11 s nelle esecuzioni successive**. Il
tempo è quasi tutto I/O: la CPU usata resta sotto i 30 s in entrambi i casi. Non dare per scontato il caso
caldo: la prima chiamata dopo l'avvio del dispositivo è proprio quella che un'interfaccia fa per prima.

Nota storica, per non ripercorrere la stessa strada: una prima versione era lenta **anche a cache calda**
(1m31s) perché calcolava lo sha256 con un processo per file, 3.043 fork. Quel costo è stato eliminato. Se
un domani il caso caldo tornasse sopra i 15 s, il fork per file è il primo posto dove guardare; se invece a
essere lenta è solo la prima esecuzione, è la cache fredda ed è normale.

**Avanzamento**: con `OTA_CHANGES_PROGRESS=1` nell'ambiente, la fase corrente viene scritta come singola
riga di testo in `/run/unitotem-ota-changes.progress`. È pensato per una barra di stato, non per essere
parsato.

### Schema JSON

```json
{
  "verdict": "clean | packages-only | mixed",
  "digest": "<sha256>",
  "packages": {
    "added":   ["sl", "libgpm2"],
    "removed": ["vecchio-pacchetto"],
    "changed": [{"name": "curl", "from": "7.88.1-10", "to": "7.88.1-11"}]
  },
  "files": {
    "unexplained":            ["/usr/bin/gzip", "/opt/mio/file"],
    "package_files_modified": ["/usr/bin/gzip"],
    "unowned_added":          ["/opt/mio/file"],
    "unowned_removed":        [],
    "unowned_modified":       []
  }
}
```

**`verdict`** è ciò su cui basare l'interfaccia:

- `clean` — nulla è cambiato, si può aggiornare senza chiedere niente
- `packages-only` — solo installazioni/rimozioni/aggiornamenti di pacchetti. Mostrare `packages`, non serve
  elencare file: sono tutti spiegati dalle operazioni sui pacchetti
- `mixed` — c'è anche altro. Mostrare `files.unexplained`: sono le modifiche che **nessuna** operazione sui
  pacchetti giustifica, quindi le più probabilmente intenzionali e le più facili da perdere senza accorgersene

**`files.unexplained` è già filtrato.** Un file appartenente a un pacchetto installato o aggiornato non
compare: è conseguenza di quell'operazione, non una modifica a sé. Idem per gli effetti collaterali noti
(`/boot/initrd.img-*` rigenerato, moduli del kernel). Gli altri campi di `files` sono di dettaglio,
utili per una vista avanzata; per il flusso normale basta `unexplained`.

**`digest`** copre esattamente ciò che viene mostrato (pacchetti + file non spiegati). Serve al passo di
conferma.

## Conferma del deploy

Dal lato host (chi orchestra il deploy):

```
./deploy/remote-deploy.sh changes root@host [--json]
./deploy/remote-deploy.sh deploy  root@host --parts DIR --accept-changes <digest>
```

`--accept-changes` procede **solo se** il digest corrisponde ancora alle modifiche presenti sul
dispositivo. Se qualcuno ha installato un pacchetto fra il momento in cui l'operatore ha visto l'elenco e
quello in cui ha confermato, il deploy si ferma. È questa la proprietà che rende una conferma da
interfaccia web sicura quanto un prompt da terminale: non si può approvare un insieme di modifiche e
distruggerne un altro.

`--accept-changes` implica anche l'esecuzione **non interattiva**: sopprime la scelta del disco e la
conferma finale, che altrimenti resterebbero in attesa su un terminale che un'interfaccia web non ha. Il
digest resta comunque verificato prima di qualunque scrittura — è una conferma più stringente di quella da
tastiera, non una scorciatoia per saltarla.

`--yes` esiste ancora e accetta tutto senza guardare. È per gli script, non per l'interfaccia.

### Sequenza consigliata

1. `changes --json` → se `verdict` è `clean`, procedere al deploy
2. altrimenti mostrare pacchetti e file non spiegati, e conservare `digest`
3. l'utente conferma → `deploy --accept-changes <digest>`
4. se il deploy si ferma per digest non corrispondente, tornare al passo 1: il sistema è cambiato

## Installare pacchetti sul dispositivo

Root è read-only. Il varco è:

```
kiosk-update enter                     # ferma il kiosk e rimonta / in rw
apt-get update && apt-get install ...
kiosk-update exit [--initramfs]        # rimonta ro e RIAVVIA il dispositivo
```

Due cose che l'interfaccia deve sapere:

- **`kiosk-update exit` riavvia**, sempre, dopo 5 secondi. Non è opzionale.
- `enter` ferma `unitotem-manager.service` e `start-xorg.service`, quindi lo schermo si spegne e il manager
  non risponde più finché il dispositivo non riparte. Se l'interfaccia gira **sul** dispositivo, perderà la
  connessione con sé stessa: l'operazione va comandata in modo da sopravvivere alla propria esecuzione.
- `--initramfs` serve solo se sono stati aggiornati kernel o moduli.

Gli aggiornamenti automatici in background sono disattivati di proposito (`apt-daily.timer` e
`apt-daily-upgrade.timer` sono mascherati): su questa immagine gli aggiornamenti passano dall'OTA, e un
timer che modifica pacchetti da solo renderebbe questo rapporto rumoroso per modifiche che nessuno ha
fatto.

## Da dove viene la baseline

Generata a build time in `/usr/lib/unitotem/baseline/` (`kiosk/stage3-image.sh`), come ultima operazione
sull'immagine: `packages`, `unowned.sha256`, `verify-expected`, `meta`.

Se manca, `check` esce con `2`. Un'immagine costruita prima di questa funzione non ha la baseline e il
dispositivo risponde `127` al comando: in entrambi i casi l'interfaccia dovrebbe dire che la rilevazione
non è disponibile su quel dispositivo, non che non ci sono modifiche.
