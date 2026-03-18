#!/usr/bin/env bash

set -u
set -o pipefail
IFS=$'\n\t'

# ==============================================================================
# AUTOMA PLUGIN HANDLER
#
# Scopo:
# - Scansionare applications/*
# - Rilevare solo installazioni WordPress reali e operative
# - Eseguire in sicurezza operazioni massive su plugin via WP-CLI
# - Produrre un report CSV affidabile per ogni applicazione analizzata
#
# Principi operativi:
# - Dry-run attivo di default
# - Le modifiche reali richiedono sempre --apply
# - Nessun purge cache implicito in modalità info
# - Nessuna cancellazione massiva di transient di default
# - Un errore su una singola app non interrompe l'intero batch
#
# Azioni supportate:
# - info
# - install-zip
# - activate
# - deactivate
# - install-activate
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly APPS_ROOT_DEFAULT="applications"
readonly WP_TIMEOUT_DEFAULT=30
readonly WP_BIN_DEFAULT="wp"

readonly COLOR_RED=$'\033[0;31m'
readonly COLOR_GREEN=$'\033[0;32m'
readonly COLOR_YELLOW=$'\033[1;33m'
readonly COLOR_BLUE=$'\033[0;34m'
readonly COLOR_BOLD=$'\033[1m'
readonly COLOR_RESET=$'\033[0m'

ACTION="info"
ZIP_PATH=""
PLUGIN_SLUG=""
APPLY=0
PURGE_CACHE=0
EXCLUDE_FILE=""
APPS_ROOT="$APPS_ROOT_DEFAULT"
WP_TIMEOUT="$WP_TIMEOUT_DEFAULT"
WP_BIN="$WP_BIN_DEFAULT"
REPORT_FILE=""

HAS_TIMEOUT=0
TIMEOUT_BIN=""

print_help() {
  cat <<EOF
Uso:
  $SCRIPT_NAME --action ACTION --plugin-slug SLUG [opzioni]

Azioni:
  info               Mostra informazioni sul plugin senza modificare nulla
  install-zip        Installa un plugin ZIP senza attivarlo
  activate           Attiva un plugin già installato
  deactivate         Disattiva un plugin installato
  install-activate   Installa un plugin ZIP e lo attiva

Opzioni principali:
  --action ACTION            Azione da eseguire
  --plugin-slug SLUG         Slug atteso del plugin per le verifiche
  --zip-path PATH            Percorso del file ZIP richiesto da install-zip/install-activate
  --exclude-file FILE        File con app_id e/o siteurl da escludere, una voce per riga
  --purge-cache              Esegue purge cache dopo azioni reali diverse da info
  --apply                    Esegue davvero le modifiche
  --report-file FILE         Percorso del report CSV; default in \$HOME
  --apps-root DIR            Root applicazioni; default: applications
  --wp-timeout SEC           Timeout per singolo comando WP-CLI; default: 30
  --wp-bin PATH              Binario WP-CLI; default: wp
  --help                     Mostra questo help

Comportamento:
  - Senza --apply lo script opera sempre in DRY-RUN
  - Le app non WordPress vengono saltate in sicurezza
  - Un'app viene considerata WordPress solo se:
      * esiste public_html
      * esiste wp-config.php
      * wp core is-installed termina con successo
  - Il purge cache è opzionale e non parte mai in info

Formato exclude file:
  - Una voce per riga
  - Righe vuote e righe che iniziano con # vengono ignorate
  - Match esatto su app_id oppure siteurl
  - Esempio:
      # Esclusioni operative
      123456
      https://example.com
      http://staging.example.net

Esempi:
  $SCRIPT_NAME --action info --plugin-slug breeze
  $SCRIPT_NAME --action activate --plugin-slug redis-cache --apply
  $SCRIPT_NAME --action deactivate --plugin-slug debug-bar --exclude-file ./exclude.txt --apply
  $SCRIPT_NAME --action install-zip --plugin-slug my-plugin --zip-path /home/master/applications/plugin.zip --apply
  $SCRIPT_NAME --action install-activate --plugin-slug my-plugin --zip-path /home/master/applications/plugin.zip --purge-cache --apply

CSV report:
  index,app_id,siteurl,wp_detected,wp_installed,action,zip_path,plugin_slug,pre_status,post_status,install_result,activate_result,cache_purged,note
EOF
}

color_echo() {
  local color="$1"
  shift
  printf '%b%s%b\n' "$color" "$*" "$COLOR_RESET"
}

log_info() {
  color_echo "$COLOR_BLUE" "$*"
}

log_warn() {
  color_echo "$COLOR_YELLOW" "$*"
}

log_error() {
  color_echo "$COLOR_RED" "$*"
}

log_success() {
  color_echo "$COLOR_GREEN" "$*"
}

result_color() {
  local value="${1:-}"

  case "$value" in
    installed|activated|deactivated|yes)
      printf '%s' "$COLOR_GREEN"
      ;;
    failed|verification_failed|failed_timeout)
      printf '%s' "$COLOR_RED"
      ;;
    dry_run|skipped|not_requested|partial|info_only|no)
      printf '%s' "$COLOR_YELLOW"
      ;;
    active)
      printf '%s' "$COLOR_GREEN"
      ;;
    inactive)
      printf '%s' "$COLOR_YELLOW"
      ;;
    not_installed|unknown)
      printf '%s' "$COLOR_BLUE"
      ;;
    *)
      printf '%s' "$COLOR_RESET"
      ;;
  esac
}

print_colored_value() {
  local label="$1"
  local value="$2"
  local color=""

  color="$(result_color "$value")"
  printf '  %-18s %b%s%b\n' "$label" "$color" "$value" "$COLOR_RESET"
}

csv_escape() {
  local value="${1:-}"
  value=${value//$'\n'/ }
  value=${value//$'\r'/ }
  value=${value//\"/\"\"}
  printf '"%s"' "$value"
}

append_csv_row() {
  local index="$1"
  local app_id="$2"
  local siteurl="$3"
  local wp_detected="$4"
  local wp_installed="$5"
  local action="$6"
  local zip_path="$7"
  local plugin_slug="$8"
  local pre_status="$9"
  local post_status="${10}"
  local install_result="${11}"
  local activate_result="${12}"
  local cache_purged="${13}"
  local note="${14}"

  {
    csv_escape "$index"; printf ','
    csv_escape "$app_id"; printf ','
    csv_escape "$siteurl"; printf ','
    csv_escape "$wp_detected"; printf ','
    csv_escape "$wp_installed"; printf ','
    csv_escape "$action"; printf ','
    csv_escape "$zip_path"; printf ','
    csv_escape "$plugin_slug"; printf ','
    csv_escape "$pre_status"; printf ','
    csv_escape "$post_status"; printf ','
    csv_escape "$install_result"; printf ','
    csv_escape "$activate_result"; printf ','
    csv_escape "$cache_purged"; printf ','
    csv_escape "$note"; printf '\n'
  } >> "$REPORT_FILE"
}

join_note() {
  local current="$1"
  local extra="$2"

  if [[ -z "$extra" ]]; then
    printf '%s' "$current"
  elif [[ -z "$current" ]]; then
    printf '%s' "$extra"
  else
    printf '%s;%s' "$current" "$extra"
  fi
}

detect_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    HAS_TIMEOUT=1
    TIMEOUT_BIN="timeout"
    return
  fi

  if command -v gtimeout >/dev/null 2>&1; then
    HAS_TIMEOUT=1
    TIMEOUT_BIN="gtimeout"
    return
  fi

  HAS_TIMEOUT=0
  TIMEOUT_BIN=""
}

run_wp() {
  local app_path="$1"
  shift

  local -a cmd=("$WP_BIN" "--path=$app_path")
  cmd+=("$@")

  if (( HAS_TIMEOUT == 1 )); then
    "$TIMEOUT_BIN" "$WP_TIMEOUT" "${cmd[@]}"
    return $?
  fi

  "${cmd[@]}"
}

run_wp_capture() {
  local app_path="$1"
  shift

  local output=""
  local status=0

  if output="$(run_wp "$app_path" "$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  fi

  status=$?
  printf '%s' "$output"
  return "$status"
}

plugin_status() {
  local app_path="$1"
  local slug="$2"

  if run_wp "$app_path" plugin is-installed "$slug" >/dev/null 2>&1; then
    if run_wp "$app_path" plugin is-active "$slug" >/dev/null 2>&1; then
      printf 'active'
    else
      printf 'inactive'
    fi
    return 0
  fi

  printf 'not_installed'
  return 0
}

load_excludes() {
  if [[ -z "$EXCLUDE_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$EXCLUDE_FILE" ]]; then
    log_error "File esclusioni non trovato: $EXCLUDE_FILE"
    exit 1
  fi
}

is_excluded() {
  local app_id="$1"
  local siteurl="$2"
  local line=""

  if [[ -z "$EXCLUDE_FILE" ]]; then
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue

    if [[ "$line" == "$app_id" || "$line" == "$siteurl" ]]; then
      return 0
    fi
  done < "$EXCLUDE_FILE"

  return 1
}

validate_args() {
  case "$ACTION" in
    info|install-zip|activate|deactivate|install-activate)
      ;;
    *)
      log_error "Azione non valida: $ACTION"
      print_help
      exit 1
      ;;
  esac

  if [[ -z "$PLUGIN_SLUG" ]]; then
    log_error "--plugin-slug è obbligatorio"
    exit 1
  fi

  case "$ACTION" in
    install-zip|install-activate)
      if [[ -z "$ZIP_PATH" ]]; then
        log_error "--zip-path è obbligatorio per l'azione $ACTION"
        exit 1
      fi
      if [[ ! -f "$ZIP_PATH" ]]; then
        log_error "ZIP plugin non trovato: $ZIP_PATH"
        exit 1
      fi
      ;;
  esac

  if [[ ! -d "$APPS_ROOT" ]]; then
    log_error "Directory applicazioni non trovata: $APPS_ROOT"
    exit 1
  fi

  if ! command -v "$WP_BIN" >/dev/null 2>&1; then
    log_error "WP-CLI non trovato: $WP_BIN"
    exit 1
  fi

  if ! [[ "$WP_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$WP_TIMEOUT" -le 0 ]]; then
    log_error "--wp-timeout deve essere un intero positivo"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --action)
        ACTION="${2:-}"
        shift 2
        ;;
      --plugin-slug)
        PLUGIN_SLUG="${2:-}"
        shift 2
        ;;
      --zip-path)
        ZIP_PATH="${2:-}"
        shift 2
        ;;
      --exclude-file)
        EXCLUDE_FILE="${2:-}"
        shift 2
        ;;
      --purge-cache)
        PURGE_CACHE=1
        shift
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      --apps-root)
        APPS_ROOT="${2:-}"
        shift 2
        ;;
      --wp-timeout)
        WP_TIMEOUT="${2:-}"
        shift 2
        ;;
      --wp-bin)
        WP_BIN="${2:-}"
        shift 2
        ;;
      --report-file)
        REPORT_FILE="${2:-}"
        shift 2
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        log_error "Argomento non riconosciuto: $1"
        print_help
        exit 1
        ;;
    esac
  done
}

ensure_report_file() {
  local now=""

  if [[ -z "$REPORT_FILE" ]]; then
    now="$(date +%Y%m%d-%H%M%S)"
    REPORT_FILE="$HOME/automa-plugin-handler-report-$now.csv"
  fi

  {
    printf '%s\n' 'index,app_id,siteurl,wp_detected,wp_installed,action,zip_path,plugin_slug,pre_status,post_status,install_result,activate_result,cache_purged,note'
  } > "$REPORT_FILE"
}

print_banner() {
  local mode_label="DRY-RUN"
  local mode_color="$COLOR_YELLOW"

  if (( APPLY == 1 )); then
    mode_label="APPLY"
    mode_color="$COLOR_RED"
  fi

  printf '%b%s%b\n' "$COLOR_BOLD" "Automa Plugin Handler" "$COLOR_RESET"
  printf 'Azione: %s\n' "$ACTION"
  printf 'Plugin slug: %s\n' "$PLUGIN_SLUG"
  if [[ -n "$ZIP_PATH" ]]; then
    printf 'ZIP path: %s\n' "$ZIP_PATH"
  fi
  printf 'Apps root: %s\n' "$APPS_ROOT"
  printf 'Timeout WP-CLI: %ss\n' "$WP_TIMEOUT"
  printf 'Report CSV: %s\n' "$REPORT_FILE"
  printf '%bModalità: %s%b\n' "$mode_color" "$mode_label" "$COLOR_RESET"
  if (( PURGE_CACHE == 1 )); then
    printf 'Purge cache: abilitato\n'
  else
    printf 'Purge cache: disabilitato\n'
  fi
  printf '\n'
}

main() {
  parse_args "$@"
  detect_timeout_bin
  validate_args
  load_excludes
  ensure_report_file
  print_banner

  local index=0
  local processed=0
  local wp_found=0
  local changed=0
  local failures=0
  local app_path=""

  shopt -s nullglob

  for app_path in "$APPS_ROOT"/*; do
    [[ -d "$app_path" ]] || continue
    index=$((index + 1))

    local app_id
    local public_html
    local siteurl="unknown"
    local wp_detected="no"
    local wp_installed="no"
    local pre_status="unknown"
    local post_status="unknown"
    local install_result="not_requested"
    local activate_result="not_requested"
    local cache_purged="no"
    local note=""
    local install_output=""
    local activate_output=""
    local siteurl_output=""
    local status_rc=0
    local cache_output=""

    app_id="$(basename "$app_path")"
    public_html="$app_path/public_html"

    log_info "[$index] Analisi app_id=$app_id"

    if [[ ! -d "$public_html" ]]; then
      note="$(join_note "$note" "public_html_missing")"
      log_warn "  public_html assente, salto"
      append_csv_row "$index" "$app_id" "$siteurl" "$wp_detected" "$wp_installed" "$ACTION" "$ZIP_PATH" "$PLUGIN_SLUG" "$pre_status" "$post_status" "$install_result" "$activate_result" "$cache_purged" "$note"
      continue
    fi

    if [[ ! -f "$public_html/wp-config.php" ]]; then
      note="$(join_note "$note" "wp_config_missing")"
      log_warn "  wp-config.php assente, non è WordPress"
      append_csv_row "$index" "$app_id" "$siteurl" "$wp_detected" "$wp_installed" "$ACTION" "$ZIP_PATH" "$PLUGIN_SLUG" "$pre_status" "$post_status" "$install_result" "$activate_result" "$cache_purged" "$note"
      continue
    fi

    wp_detected="yes"

    if run_wp "$public_html" core is-installed >/dev/null 2>&1; then
      wp_installed="yes"
      wp_found=$((wp_found + 1))
    else
      note="$(join_note "$note" "wp_core_not_installed")"
      log_warn "  WordPress rilevato ma non installato correttamente"
      append_csv_row "$index" "$app_id" "$siteurl" "$wp_detected" "$wp_installed" "$ACTION" "$ZIP_PATH" "$PLUGIN_SLUG" "$pre_status" "$post_status" "$install_result" "$activate_result" "$cache_purged" "$note"
      continue
    fi

    siteurl_output="$(run_wp_capture "$public_html" option get home --skip-plugins --skip-themes --quiet)"
    status_rc=$?
    if [[ $status_rc -eq 0 && -n "$siteurl_output" ]]; then
      siteurl="$siteurl_output"
    else
      siteurl_output="$(run_wp_capture "$public_html" option get siteurl --skip-plugins --skip-themes --quiet)"
      status_rc=$?
      if [[ $status_rc -eq 0 && -n "$siteurl_output" ]]; then
        siteurl="$siteurl_output"
      else
        note="$(join_note "$note" "siteurl_unavailable")"
      fi
    fi

    if is_excluded "$app_id" "$siteurl"; then
      note="$(join_note "$note" "excluded")"
      log_warn "  esclusa da file di esclusione"
      append_csv_row "$index" "$app_id" "$siteurl" "$wp_detected" "$wp_installed" "$ACTION" "$ZIP_PATH" "$PLUGIN_SLUG" "$pre_status" "$post_status" "$install_result" "$activate_result" "$cache_purged" "$note"
      continue
    fi

    processed=$((processed + 1))
    pre_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
    post_status="$pre_status"

    case "$ACTION" in
      info)
        install_result="info_only"
        activate_result="info_only"
        note="$(join_note "$note" "dry_run_info")"
        ;;

      install-zip)
        activate_result="not_requested"

        if (( APPLY == 0 )); then
          install_result="dry_run"
          note="$(join_note "$note" "would_install_zip")"
        else
          install_output="$(run_wp_capture "$public_html" plugin install "$ZIP_PATH" --force --quiet)"
          status_rc=$?
          if [[ $status_rc -eq 0 ]]; then
            post_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
            if [[ "$post_status" == "active" || "$post_status" == "inactive" ]]; then
              install_result="installed"
              note="$(join_note "$note" "zip_installed")"
              changed=$((changed + 1))
            else
              install_result="verification_failed"
              note="$(join_note "$note" "plugin_slug_not_verified_after_install")"
              failures=$((failures + 1))
            fi
          else
            install_result="failed"
            if [[ $status_rc -eq 124 ]]; then
              note="$(join_note "$note" "install_timeout")"
            else
              note="$(join_note "$note" "install_failed")"
            fi
            if [[ -n "$install_output" ]]; then
              note="$(join_note "$note" "$install_output")"
            fi
            failures=$((failures + 1))
          fi
        fi
        ;;

      activate)
        install_result="not_requested"

        if [[ "$pre_status" == "not_installed" ]]; then
          activate_result="skipped"
          note="$(join_note "$note" "plugin_not_installed")"
        elif [[ "$pre_status" == "active" ]]; then
          activate_result="skipped"
          note="$(join_note "$note" "already_active")"
        elif (( APPLY == 0 )); then
          activate_result="dry_run"
          note="$(join_note "$note" "would_activate")"
        else
          activate_output="$(run_wp_capture "$public_html" plugin activate "$PLUGIN_SLUG" --quiet)"
          status_rc=$?
          if [[ $status_rc -eq 0 ]]; then
            post_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
            if [[ "$post_status" == "active" ]]; then
              activate_result="activated"
              note="$(join_note "$note" "plugin_activated")"
              changed=$((changed + 1))
            else
              activate_result="verification_failed"
              note="$(join_note "$note" "plugin_not_active_after_activate")"
              failures=$((failures + 1))
            fi
          else
            activate_result="failed"
            if [[ $status_rc -eq 124 ]]; then
              note="$(join_note "$note" "activate_timeout")"
            else
              note="$(join_note "$note" "activate_failed")"
            fi
            if [[ -n "$activate_output" ]]; then
              note="$(join_note "$note" "$activate_output")"
            fi
            failures=$((failures + 1))
          fi
        fi
        ;;

      deactivate)
        install_result="not_requested"

        if [[ "$pre_status" == "not_installed" ]]; then
          activate_result="skipped"
          note="$(join_note "$note" "plugin_not_installed")"
        elif [[ "$pre_status" == "inactive" ]]; then
          activate_result="skipped"
          note="$(join_note "$note" "already_inactive")"
        elif (( APPLY == 0 )); then
          activate_result="dry_run"
          note="$(join_note "$note" "would_deactivate")"
        else
          activate_output="$(run_wp_capture "$public_html" plugin deactivate "$PLUGIN_SLUG" --quiet)"
          status_rc=$?
          if [[ $status_rc -eq 0 ]]; then
            post_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
            if [[ "$post_status" == "inactive" ]]; then
              activate_result="deactivated"
              note="$(join_note "$note" "plugin_deactivated")"
              changed=$((changed + 1))
            else
              activate_result="verification_failed"
              note="$(join_note "$note" "plugin_still_active_after_deactivate")"
              failures=$((failures + 1))
            fi
          else
            activate_result="failed"
            if [[ $status_rc -eq 124 ]]; then
              note="$(join_note "$note" "deactivate_timeout")"
            else
              note="$(join_note "$note" "deactivate_failed")"
            fi
            if [[ -n "$activate_output" ]]; then
              note="$(join_note "$note" "$activate_output")"
            fi
            failures=$((failures + 1))
          fi
        fi
        ;;

      install-activate)
        if (( APPLY == 0 )); then
          install_result="dry_run"
          activate_result="dry_run"
          note="$(join_note "$note" "would_install_zip")"
          note="$(join_note "$note" "would_activate")"
        else
          install_output="$(run_wp_capture "$public_html" plugin install "$ZIP_PATH" --force --quiet)"
          status_rc=$?
          if [[ $status_rc -eq 0 ]]; then
            post_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
            if [[ "$post_status" == "active" || "$post_status" == "inactive" ]]; then
              install_result="installed"
              note="$(join_note "$note" "zip_installed")"
            else
              install_result="verification_failed"
              note="$(join_note "$note" "plugin_slug_not_verified_after_install")"
              failures=$((failures + 1))
            fi
          else
            install_result="failed"
            if [[ $status_rc -eq 124 ]]; then
              note="$(join_note "$note" "install_timeout")"
            else
              note="$(join_note "$note" "install_failed")"
            fi
            if [[ -n "$install_output" ]]; then
              note="$(join_note "$note" "$install_output")"
            fi
            failures=$((failures + 1))
          fi

          if [[ "$install_result" == "installed" || "$post_status" == "inactive" || "$post_status" == "active" ]]; then
            if [[ "$post_status" == "active" ]]; then
              activate_result="skipped"
              note="$(join_note "$note" "already_active")"
            else
              activate_output="$(run_wp_capture "$public_html" plugin activate "$PLUGIN_SLUG" --quiet)"
              status_rc=$?
              if [[ $status_rc -eq 0 ]]; then
                post_status="$(plugin_status "$public_html" "$PLUGIN_SLUG")"
                if [[ "$post_status" == "active" ]]; then
                  activate_result="activated"
                  note="$(join_note "$note" "plugin_activated")"
                  changed=$((changed + 1))
                else
                  activate_result="verification_failed"
                  note="$(join_note "$note" "plugin_not_active_after_activate")"
                  failures=$((failures + 1))
                fi
              else
                activate_result="failed"
                if [[ $status_rc -eq 124 ]]; then
                  note="$(join_note "$note" "activate_timeout")"
                else
                  note="$(join_note "$note" "activate_failed")"
                fi
                if [[ -n "$activate_output" ]]; then
                  note="$(join_note "$note" "$activate_output")"
                fi
                failures=$((failures + 1))
              fi
            fi
          else
            activate_result="skipped"
            note="$(join_note "$note" "activate_skipped_due_to_install_failure")"
          fi
        fi
        ;;
    esac

    if (( APPLY == 1 )) && (( PURGE_CACHE == 1 )) && [[ "$ACTION" != "info" ]]; then
      cache_output="$(run_wp_capture "$public_html" cache flush --quiet)"
      status_rc=$?
      if [[ $status_rc -eq 0 ]]; then
        cache_purged="yes"
        note="$(join_note "$note" "cache_flushed")"
      else
        cache_purged="failed"
        if [[ $status_rc -eq 124 ]]; then
          note="$(join_note "$note" "cache_flush_timeout")"
        else
          note="$(join_note "$note" "cache_flush_failed")"
        fi
        if [[ -n "$cache_output" ]]; then
          note="$(join_note "$note" "$cache_output")"
        fi
      fi

      if run_wp "$public_html" plugin is-installed breeze >/dev/null 2>&1; then
        cache_output="$(run_wp_capture "$public_html" breeze purge --cache=all --quiet)"
        status_rc=$?
        if [[ $status_rc -eq 0 ]]; then
          cache_purged="yes"
          note="$(join_note "$note" "breeze_purged")"
        else
          if [[ "$cache_purged" == "yes" ]]; then
            cache_purged="partial"
          else
            cache_purged="failed"
          fi
          if [[ $status_rc -eq 124 ]]; then
            note="$(join_note "$note" "breeze_purge_timeout")"
          else
            note="$(join_note "$note" "breeze_purge_failed")"
          fi
          if [[ -n "$cache_output" ]]; then
            note="$(join_note "$note" "$cache_output")"
          fi
        fi
      fi
    fi

    append_csv_row "$index" "$app_id" "$siteurl" "$wp_detected" "$wp_installed" "$ACTION" "$ZIP_PATH" "$PLUGIN_SLUG" "$pre_status" "$post_status" "$install_result" "$activate_result" "$cache_purged" "$note"

    if [[ "$install_result" == "failed" || "$install_result" == "verification_failed" || "$activate_result" == "failed" || "$activate_result" == "verification_failed" ]]; then
      log_error "  stato operativo: errore"
    elif [[ "$install_result" == "dry_run" || "$activate_result" == "dry_run" ]]; then
      log_warn "  stato operativo: simulazione"
    else
      log_success "  stato operativo: completato"
    fi

    printf '  %-18s %s\n' "siteurl" "$siteurl"
    print_colored_value "stato iniziale" "$pre_status"
    print_colored_value "installazione" "$install_result"
    print_colored_value "attivazione" "$activate_result"
    print_colored_value "stato finale" "$post_status"
    print_colored_value "cache purge" "$cache_purged"
    printf '  %-18s %s\n' "note" "${note:-n/a}"
    printf '\n'
  done

  printf '\n'
  printf '%bReport:%b %s\n' "$COLOR_BOLD" "$COLOR_RESET" "$REPORT_FILE"
  printf 'App analizzate: %s\n' "$index"
  printf 'WordPress valide: %s\n' "$wp_found"
  printf 'WordPress processate: %s\n' "$processed"
  printf 'Modifiche applicate: %s\n' "$changed"
  printf 'Failure operative: %s\n' "$failures"

  if (( APPLY == 0 )); then
    log_warn "Modalità DRY-RUN: nessuna modifica reale è stata eseguita"
  fi
}

main "$@"
