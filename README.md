# Automa Scripts

Repository di script operativi.

## Convenzione adottata

Ogni script ha un file di documentazione associato con lo stesso nome base:

- `automa-plugin-handler.sh`
- `automa-plugin-handler.md`

In questo modo:

- il file `.sh` contiene il codice eseguibile
- il file `.md` descrive funzionamento, opzioni CLI, prerequisiti, output ed esempi d'uso

## Come leggere il repository

Per ogni automazione:

1. individua lo script `.sh`
2. apri il file `.md` con lo stesso nome
3. usa quel file come documentazione principale dello script

## Script attualmente presenti

- [`automa-plugin-handler.sh`](C:\Users\matti\OneDrive\Lavoro\automa\automascripts\automa-plugin-handler.sh)
  - documentazione: [`automa-plugin-handler.md`](C:\Users\matti\OneDrive\Lavoro\automa\automascripts\automa-plugin-handler.md)

## Regola per i nuovi script

Quando aggiungi un nuovo script, mantieni questa coppia:

- `nome-script.sh`
- `nome-script.md`

Esempio:

- `site-audit.sh`
- `site-audit.md`

## Contenuto consigliato del file `.md`

Ogni file di documentazione per script dovrebbe includere almeno:

- scopo dello script
- prerequisiti
- sintassi
- opzioni CLI
- esempi d'uso
- output generato
- note operative e limiti
