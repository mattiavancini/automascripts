# Automa Plugin Handler

Script Bash per eseguire operazioni massive sui plugin WordPress dentro una struttura `applications/*`, con approccio sicuro, `dry-run` di default e report CSV finale.

Il repository contiene un solo script operativo:

- [`automa-plugin-handler.sh`](C:\Users\matti\OneDrive\Lavoro\automa\automascripts\automa-plugin-handler.sh)

## Obiettivo

Lo script serve a:

- scansionare tutte le applicazioni sotto `applications/`
- identificare solo installazioni WordPress realmente valide
- leggere lo stato di un plugin tramite `WP-CLI`
- installare, attivare o disattivare un plugin in batch
- produrre un report CSV affidabile per ogni applicazione analizzata

## Principi di sicurezza

- `dry-run` attivo di default: senza `--apply` non viene modificato nulla
- un errore su una singola applicazione non interrompe l’intero batch
- le applicazioni non WordPress vengono saltate in modo esplicito
- il purge cache non parte mai in modalità `info`
- il purge cache è opzionale anche nelle azioni operative

## Prerequisiti

Prima di usare lo script servono:

- Bash compatibile con array Bash
- `WP-CLI` disponibile nel `PATH`, oppure indicato con `--wp-bin`
- una struttura directory del tipo `applications/<app_id>/public_html`
- per ogni sito WordPress valido:
  - `public_html` esistente
  - `public_html/wp-config.php` esistente
  - `wp core is-installed` con esito positivo

## Struttura attesa

Esempio:

```text
applications/
  123456/
    public_html/
      wp-config.php
  789012/
    public_html/
      wp-config.php
```

Ogni cartella figlia di `applications/` viene trattata come una possibile app. Lo script usa il nome directory come `app_id`.

## Azioni supportate

- `info`
  - legge solo lo stato del plugin
  - non modifica nulla
- `install-zip`
  - installa un plugin ZIP senza attivarlo
- `activate`
  - attiva un plugin già installato
- `deactivate`
  - disattiva un plugin installato
- `install-activate`
  - installa il plugin ZIP e poi lo attiva

## Sintassi

```bash
./automa-plugin-handler.sh --action ACTION --plugin-slug SLUG [opzioni]
```

## Opzioni CLI

- `--action ACTION`
  - azione da eseguire
- `--plugin-slug SLUG`
  - slug del plugin da verificare via `WP-CLI`
- `--zip-path PATH`
  - file ZIP richiesto da `install-zip` e `install-activate`
- `--exclude-file FILE`
  - file con app da saltare
- `--purge-cache`
  - esegue flush cache dopo azioni reali diverse da `info`
- `--apply`
  - abilita le modifiche reali
- `--report-file FILE`
  - percorso output CSV
- `--apps-root DIR`
  - root applicazioni, default `applications`
- `--wp-timeout SEC`
  - timeout per ogni comando `WP-CLI`, default `30`
- `--wp-bin PATH`
  - binario `WP-CLI`, default `wp`
- `--help`
  - mostra help

## Comportamento operativo

Per ogni directory sotto `applications/`, lo script:

1. verifica che esista `public_html`
2. verifica che esista `wp-config.php`
3. esegue `wp core is-installed`
4. prova a leggere `home`, poi `siteurl`
5. controlla se l’app è esclusa tramite `app_id` o `siteurl`
6. rileva lo stato del plugin:
   - `active`
   - `inactive`
   - `not_installed`
7. applica l’azione richiesta oppure simula il risultato in `dry-run`
8. opzionalmente esegue:
   - `wp cache flush`
   - `wp breeze purge --cache=all` se il plugin `breeze` è installato
9. scrive una riga nel report CSV

## File di esclusione

Il file passato con `--exclude-file` accetta una voce per riga:

- `app_id`
- `siteurl`

Sono ignorate:

- righe vuote
- righe che iniziano con `#`

Esempio:

```text
# esclusioni operative
123456
https://example.com
http://staging.example.net
```

Il match è esatto.

## Esempi d’uso

Solo analisi:

```bash
./automa-plugin-handler.sh --action info --plugin-slug breeze
```

Attivazione reale di un plugin già installato:

```bash
./automa-plugin-handler.sh --action activate --plugin-slug redis-cache --apply
```

Disattivazione con esclusioni:

```bash
./automa-plugin-handler.sh \
  --action deactivate \
  --plugin-slug debug-bar \
  --exclude-file ./exclude.txt \
  --apply
```

Installazione ZIP senza attivazione:

```bash
./automa-plugin-handler.sh \
  --action install-zip \
  --plugin-slug my-plugin \
  --zip-path /home/master/applications/my-plugin.zip \
  --apply
```

Installazione e attivazione con purge cache:

```bash
./automa-plugin-handler.sh \
  --action install-activate \
  --plugin-slug my-plugin \
  --zip-path /home/master/applications/my-plugin.zip \
  --purge-cache \
  --apply
```

Override del binario `WP-CLI` e percorso applicazioni:

```bash
./automa-plugin-handler.sh \
  --action info \
  --plugin-slug woo-commerce \
  --apps-root /home/master/applications \
  --wp-bin /usr/local/bin/wp
```

## Report CSV

Se `--report-file` non è specificato, lo script genera automaticamente:

```text
$HOME/automa-plugin-handler-report-YYYYMMDD-HHMMSS.csv
```

Header CSV:

```text
index,app_id,siteurl,wp_detected,wp_installed,action,zip_path,plugin_slug,pre_status,post_status,install_result,activate_result,cache_purged,note
```

Significato colonne:

- `index`: progressivo della scansione
- `app_id`: nome directory dell’app
- `siteurl`: URL letto da WordPress, se disponibile
- `wp_detected`: presenza struttura WordPress minima
- `wp_installed`: esito di `wp core is-installed`
- `action`: azione richiesta
- `zip_path`: ZIP usato, se previsto
- `plugin_slug`: slug controllato
- `pre_status`: stato plugin prima dell’azione
- `post_status`: stato plugin dopo l’azione
- `install_result`: esito della parte di installazione
- `activate_result`: esito della parte di attivazione/disattivazione
- `cache_purged`: esito flush/purge cache
- `note`: dettagli operativi o motivi di skip/failure

## Valori più comuni nel report

Stato plugin:

- `active`
- `inactive`
- `not_installed`
- `unknown`

Esito operazioni:

- `info_only`
- `dry_run`
- `installed`
- `activated`
- `deactivated`
- `skipped`
- `failed`
- `verification_failed`
- `not_requested`

Cache:

- `yes`
- `no`
- `partial`
- `failed`

## Cause comuni di skip o warning

Nel campo `note` possono comparire valori come:

- `public_html_missing`
- `wp_config_missing`
- `wp_core_not_installed`
- `siteurl_unavailable`
- `excluded`
- `plugin_not_installed`
- `already_active`
- `already_inactive`
- `would_install_zip`
- `would_activate`
- `would_deactivate`

In caso di errore possono comparire anche:

- `install_failed`
- `activate_failed`
- `deactivate_failed`
- `install_timeout`
- `activate_timeout`
- `deactivate_timeout`
- `cache_flush_failed`
- `breeze_purge_failed`

Lo script può inoltre appendere nel `note` l’output testuale restituito da `WP-CLI`.

## Dry-run vs apply

Comportamento consigliato:

1. eseguire sempre prima un `info` o un’azione senza `--apply`
2. verificare il report CSV
3. ripetere con `--apply` solo quando l’elenco target è corretto

Esempio:

```bash
./automa-plugin-handler.sh --action activate --plugin-slug query-monitor
./automa-plugin-handler.sh --action activate --plugin-slug query-monitor --apply
```

## Timeout

Ogni comando `WP-CLI` usa un timeout configurabile con `--wp-timeout`.

- default: `30`
- se disponibile, lo script usa `timeout`
- in alternativa prova `gtimeout`
- se nessuno dei due è disponibile, esegue i comandi senza wrapper timeout

## Note operative

- per `install-zip` e `install-activate`, il file ZIP deve esistere già su filesystem
- l’installazione ZIP usa `wp plugin install <zip> --force --quiet`
- l’attivazione usa `wp plugin activate <slug> --quiet`
- la disattivazione usa `wp plugin deactivate <slug> --quiet`
- dopo un’operazione reale lo script verifica sempre lo stato finale del plugin

## Suggerimento pratico

Se vuoi usare questo repository in team, la documentazione minima consigliata è:

- questa `README.md` per l’uso operativo
- un file `exclude.txt` di esempio
- eventuali comandi standardizzati in uno script wrapper o in una wiki interna
