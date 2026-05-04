#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="/usr/local/sbin/apt-mirror-health"
CONFIG_PATH="/etc/default/apt-mirror-health"
HOOK_PATH="/etc/apt/apt.conf.d/99mirror-health"
SOURCE_FILE="${SOURCE_FILE:-/etc/apt/sources.list.d/ubuntu.sources}"
BACKUP_FILE="/var/backups/ubuntu.sources.apt-mirror-health.initial"

PRIMARY_ARCHIVE_URI="${PRIMARY_ARCHIVE_URI:-http://us.archive.ubuntu.com/ubuntu/}"
PRIMARY_SECURITY_URI="${PRIMARY_SECURITY_URI:-http://security.ubuntu.com/ubuntu/}"
FALLBACK_URI="${FALLBACK_URI:-https://mirrors.edge.kernel.org/ubuntu/}"
CODENAME="${CODENAME:-}"
RUN_INITIAL_CHECK="1"

usage() {
    cat <<'EOF'
Usage: sudo ./install-apt-mirror-health.sh [OPTIONS]

Installs a mirror health process for Ubuntu apt sources. The process checks
Ubuntu default mirrors before apt update/upgrade, fails over to kernel.org when
the defaults are unhealthy, and auto-restores defaults after recovery.

Options:
  --no-initial-check  Install only; do not run the health process immediately.
  --help             Show this help.

Optional environment overrides:
  SOURCE_FILE=/etc/apt/sources.list.d/ubuntu.sources
  PRIMARY_ARCHIVE_URI=http://us.archive.ubuntu.com/ubuntu/
  PRIMARY_SECURITY_URI=http://security.ubuntu.com/ubuntu/
  FALLBACK_URI=https://mirrors.edge.kernel.org/ubuntu/
  CODENAME=noble

After install:
  sudo apt-mirror-health --status
  sudo apt-mirror-health --check
  sudo apt-mirror-health --failover
  sudo apt-mirror-health --restore
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-initial-check)
            RUN_INITIAL_CHECK="0"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n\n' "$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "${EUID}" -ne 0 ]]; then
    printf 'Run as root: sudo %s\n' "$0" >&2
    exit 1
fi

if [[ -z "$CODENAME" && -r /etc/os-release ]]; then
    # shellcheck source=/etc/os-release
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
fi

if [[ -z "$CODENAME" ]]; then
    printf 'Could not discover Ubuntu codename. Re-run with CODENAME=noble, jammy, etc.\n' >&2
    exit 1
fi

if [[ ! -e "$SOURCE_FILE" ]]; then
    printf 'Expected Ubuntu deb822 source file not found: %s\n' "$SOURCE_FILE" >&2
    printf 'This installer is intentionally scoped to modern Ubuntu deb822 sources.\n' >&2
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    printf 'curl is required and was not found. Install curl before running this installer.\n' >&2
    exit 1
fi

install -d -o root -g root -m 0755 /usr/local/sbin /etc/default /etc/apt/apt.conf.d /var/backups

if [[ -e "$SOURCE_FILE" && ! -e "$BACKUP_FILE" ]]; then
    cp -a "$SOURCE_FILE" "$BACKUP_FILE"
fi

tmp_script="$(mktemp)"
cat > "$tmp_script" <<'APT_MIRROR_HEALTH_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${APT_MIRROR_HEALTH_CONFIG:-/etc/default/apt-mirror-health}"

SOURCE_FILE="/etc/apt/sources.list.d/ubuntu.sources"
BACKUP_FILE="/var/backups/ubuntu.sources.apt-mirror-health.initial"
STATE_DIR="/var/lib/apt-mirror-health"
STATE_FILE="${STATE_DIR}/state"
LOCK_FILE="/run/apt-mirror-health.lock"

PRIMARY_ARCHIVE_URI="http://us.archive.ubuntu.com/ubuntu/"
PRIMARY_SECURITY_URI="http://security.ubuntu.com/ubuntu/"
FALLBACK_URI="https://mirrors.edge.kernel.org/ubuntu/"
CODENAME=""

LATENCY_MAX_MS="3000"
CONNECT_TIMEOUT="5"
TOTAL_TIMEOUT="15"
MIN_BYTES_PER_SEC="50000"
LOW_SPEED_TIME="5"
PROBE_ATTEMPTS="2"
PRE_APT_PROBE_ATTEMPTS="1"
RESTORE_REQUIRED_GOOD_CHECKS="2"
RESTORE_CHECK_INTERVAL_SECONDS="1800"
FORCE_IPV4="1"
CURL_BIN="/usr/bin/curl"

STATE_MODE=""
GOOD_PRIMARY_CHECKS="0"
LAST_PRIMARY_HEALTH=""
LAST_RUN_EPOCH="0"
PRIMARY_REPORT_TEXT=""
FALLBACK_REPORT_TEXT=""
LAST_PROBE_REPORT=""

usage() {
    cat <<'EOF'
Usage: apt-mirror-health MODE

Modes:
  --check      Probe primary and fallback mirrors without changing apt sources.
  --pre-apt    Probe and automatically fail over or restore apt sources.
  --failover   Switch Ubuntu sources to the fallback mirror if it is healthy.
  --restore    Restore Ubuntu sources to the configured primary mirrors.
  --status     Print current source mode and saved state.
EOF
}

log_msg() {
    if command -v logger >/dev/null 2>&1; then
        logger -t apt-mirror-health -- "$*"
    fi
}

die() {
    printf 'apt-mirror-health: %s\n' "$*" >&2
    log_msg "error: $*"
    exit 1
}

ensure_trailing_slash() {
    local uri="$1"
    printf '%s/\n' "${uri%/}"
}

require_uint() {
    local name="$1"
    local value="${!name}"
    [[ "$value" =~ ^[0-9]+$ ]] || die "${name} must be an unsigned integer"
}

load_config() {
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck source=/etc/default/apt-mirror-health
        . "$CONFIG_FILE"
    fi

    if [[ -z "${CODENAME:-}" && -r /etc/os-release ]]; then
        # shellcheck source=/etc/os-release
        . /etc/os-release
        CODENAME="${VERSION_CODENAME:-}"
    fi

    [[ -n "${CODENAME:-}" ]] || die "CODENAME is not set and could not be discovered from /etc/os-release"

    PRIMARY_ARCHIVE_URI="$(ensure_trailing_slash "$PRIMARY_ARCHIVE_URI")"
    PRIMARY_SECURITY_URI="$(ensure_trailing_slash "$PRIMARY_SECURITY_URI")"
    FALLBACK_URI="$(ensure_trailing_slash "$FALLBACK_URI")"

    require_uint LATENCY_MAX_MS
    require_uint CONNECT_TIMEOUT
    require_uint TOTAL_TIMEOUT
    require_uint MIN_BYTES_PER_SEC
    require_uint LOW_SPEED_TIME
    require_uint PROBE_ATTEMPTS
    require_uint PRE_APT_PROBE_ATTEMPTS
    require_uint RESTORE_REQUIRED_GOOD_CHECKS
    require_uint RESTORE_CHECK_INTERVAL_SECONDS

    (( PROBE_ATTEMPTS >= 1 )) || PROBE_ATTEMPTS="1"
    (( PRE_APT_PROBE_ATTEMPTS >= 1 )) || PRE_APT_PROBE_ATTEMPTS="1"
    (( RESTORE_REQUIRED_GOOD_CHECKS >= 1 )) || RESTORE_REQUIRED_GOOD_CHECKS="1"
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "$1 must be run as root"
}

with_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_msg "another apt-mirror-health run is active; skipping"
        return 0
    fi
    "$@"
}

ensure_state_dir() {
    install -d -o root -g root -m 0755 "$STATE_DIR"
}

read_state() {
    STATE_MODE=""
    GOOD_PRIMARY_CHECKS="0"
    LAST_PRIMARY_HEALTH=""
    LAST_RUN_EPOCH="0"

    [[ -r "$STATE_FILE" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            MODE)
                STATE_MODE="$value"
                ;;
            GOOD_PRIMARY_CHECKS)
                if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
                    GOOD_PRIMARY_CHECKS="$value"
                fi
                ;;
            LAST_PRIMARY_HEALTH)
                LAST_PRIMARY_HEALTH="$value"
                ;;
            LAST_RUN_EPOCH)
                if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
                    LAST_RUN_EPOCH="$value"
                fi
                ;;
        esac
    done < "$STATE_FILE"
}

write_state() {
    local mode="$1"
    local good_checks="$2"
    local primary_health="${3:-unknown}"
    local fallback_health="${4:-unknown}"
    local tmp

    ensure_state_dir
    tmp="$(mktemp "${STATE_DIR}/state.XXXXXX")"
    {
        printf 'MODE=%s\n' "$mode"
        printf 'GOOD_PRIMARY_CHECKS=%s\n' "$good_checks"
        printf 'LAST_PRIMARY_HEALTH=%s\n' "$primary_health"
        printf 'LAST_FALLBACK_HEALTH=%s\n' "$fallback_health"
        printf 'LAST_RUN_EPOCH=%s\n' "$(date +%s)"
    } > "$tmp"
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

repo_inrelease_url() {
    local base_uri="$1"
    local suite="$2"
    printf '%sdists/%s/InRelease\n' "$base_uri" "$suite"
}

probe_once() {
    local label="$1"
    local url="$2"
    local tmp err_file out rc err_text
    local http_code time_total speed_download time_ms speed_bps
    local curl_args=()

    if [[ ! -x "$CURL_BIN" ]]; then
        LAST_PROBE_REPORT="${label}: curl not found at ${CURL_BIN}"
        return 1
    fi

    tmp="$(mktemp "${TMPDIR:-/tmp}/apt-mirror-health.body.XXXXXX")"
    err_file="$(mktemp "${TMPDIR:-/tmp}/apt-mirror-health.err.XXXXXX")"

    if [[ "${FORCE_IPV4}" == "1" || "${FORCE_IPV4,,}" == "true" ]]; then
        curl_args+=("-4")
    fi

    curl_args+=(
        "--fail"
        "--location"
        "--silent"
        "--show-error"
        "--output" "$tmp"
        "--write-out" "%{http_code} %{time_total} %{speed_download}"
        "--connect-timeout" "$CONNECT_TIMEOUT"
        "--max-time" "$TOTAL_TIMEOUT"
        "--retry" "0"
    )

    if (( MIN_BYTES_PER_SEC > 0 && LOW_SPEED_TIME > 0 )); then
        curl_args+=("--speed-limit" "$MIN_BYTES_PER_SEC" "--speed-time" "$LOW_SPEED_TIME")
    fi

    if out="$("$CURL_BIN" "${curl_args[@]}" "$url" 2>"$err_file")"; then
        rm -f "$err_file" "$tmp"
    else
        rc="$?"
        err_text="$(tr '\n' ' ' < "$err_file" | sed 's/[[:space:]]*$//')"
        rm -f "$err_file" "$tmp"
        LAST_PROBE_REPORT="${label}: curl failed rc=${rc}${err_text:+ (${err_text})}"
        return 1
    fi

    read -r http_code time_total speed_download <<< "$out"
    if [[ "$http_code" != "200" ]]; then
        LAST_PROBE_REPORT="${label}: unexpected HTTP status ${http_code:-unknown}"
        return 1
    fi

    time_ms="$(awk -v t="${time_total:-0}" 'BEGIN { printf "%.0f", t * 1000 }')"
    speed_bps="$(awk -v s="${speed_download:-0}" 'BEGIN { printf "%.0f", s }')"

    if (( LATENCY_MAX_MS > 0 && time_ms > LATENCY_MAX_MS )); then
        LAST_PROBE_REPORT="${label}: slow response ${time_ms}ms > ${LATENCY_MAX_MS}ms"
        return 1
    fi

    if (( MIN_BYTES_PER_SEC > 0 && speed_bps < MIN_BYTES_PER_SEC )); then
        LAST_PROBE_REPORT="${label}: slow transfer ${speed_bps} B/s < ${MIN_BYTES_PER_SEC} B/s"
        return 1
    fi

    LAST_PROBE_REPORT="${label}: ok ${time_ms}ms, ${speed_bps} B/s"
    return 0
}

probe_url() {
    local label="$1"
    local url="$2"
    local attempt
    local last_failure=""

    for (( attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++ )); do
        if probe_once "$label" "$url"; then
            if (( attempt > 1 )); then
                LAST_PROBE_REPORT="${LAST_PROBE_REPORT} on attempt ${attempt}"
            fi
            return 0
        fi
        last_failure="$LAST_PROBE_REPORT"
    done

    LAST_PROBE_REPORT="${last_failure} after ${PROBE_ATTEMPTS} attempt(s)"
    return 1
}

append_primary_report() {
    PRIMARY_REPORT_TEXT+="${LAST_PROBE_REPORT}"$'\n'
}

append_fallback_report() {
    FALLBACK_REPORT_TEXT+="${LAST_PROBE_REPORT}"$'\n'
}

check_primary() {
    local ok=0
    PRIMARY_REPORT_TEXT=""

    if probe_url "primary archive ${CODENAME}-updates" "$(repo_inrelease_url "$PRIMARY_ARCHIVE_URI" "${CODENAME}-updates")"; then
        append_primary_report
    else
        ok=1
        append_primary_report
    fi

    if probe_url "primary security ${CODENAME}-security" "$(repo_inrelease_url "$PRIMARY_SECURITY_URI" "${CODENAME}-security")"; then
        append_primary_report
    else
        ok=1
        append_primary_report
    fi

    return "$ok"
}

check_fallback() {
    local ok=0
    FALLBACK_REPORT_TEXT=""

    if probe_url "fallback archive ${CODENAME}-updates" "$(repo_inrelease_url "$FALLBACK_URI" "${CODENAME}-updates")"; then
        append_fallback_report
    else
        ok=1
        append_fallback_report
    fi

    if probe_url "fallback security ${CODENAME}-security" "$(repo_inrelease_url "$FALLBACK_URI" "${CODENAME}-security")"; then
        append_fallback_report
    else
        ok=1
        append_fallback_report
    fi

    return "$ok"
}

detect_current_mode() {
    [[ -r "$SOURCE_FILE" ]] || {
        printf 'missing\n'
        return 0
    }

    local uris=()
    local uri
    local all_fallback=1
    local all_primaryish=1

    while read -r uri; do
        [[ -n "$uri" ]] || continue
        uris+=("$(ensure_trailing_slash "$uri")")
    done < <(awk '/^URIs:[[:space:]]*/ { print $2 }' "$SOURCE_FILE")

    if (( ${#uris[@]} == 0 )); then
        printf 'custom\n'
        return 0
    fi

    for uri in "${uris[@]}"; do
        if [[ "$uri" != "$FALLBACK_URI" ]]; then
            all_fallback=0
        fi

        case "$uri" in
            "$PRIMARY_ARCHIVE_URI"|"$PRIMARY_SECURITY_URI"|"http://archive.ubuntu.com/ubuntu/"|"http://us.archive.ubuntu.com/ubuntu/"|"http://security.ubuntu.com/ubuntu/")
                ;;
            *)
                all_primaryish=0
                ;;
        esac
    done

    if (( all_fallback == 1 )); then
        printf 'fallback\n'
    elif (( all_primaryish == 1 )); then
        printf 'primary\n'
    else
        printf 'custom\n'
    fi
}

backup_source_once() {
    if [[ -e "$SOURCE_FILE" && ! -e "$BACKUP_FILE" ]]; then
        cp -a "$SOURCE_FILE" "$BACKUP_FILE"
    fi
}

write_sources() {
    local mode="$1"
    local archive_uri security_uri tmp

    case "$mode" in
        primary)
            archive_uri="$PRIMARY_ARCHIVE_URI"
            security_uri="$PRIMARY_SECURITY_URI"
            ;;
        fallback)
            archive_uri="$FALLBACK_URI"
            security_uri="$FALLBACK_URI"
            ;;
        *)
            die "unsupported source mode: ${mode}"
            ;;
    esac

    backup_source_once

    tmp="$(mktemp "${SOURCE_FILE}.tmp.XXXXXX")"
    cat > "$tmp" <<EOF
Types: deb
URIs: ${archive_uri}
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: ${security_uri}
Suites: ${CODENAME}-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    chown root:root "$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$SOURCE_FILE"
    log_msg "wrote ${SOURCE_FILE} in ${mode} mode"
}

run_check() {
    local current primary_status fallback_status primary_ok=0 fallback_ok=0

    current="$(detect_current_mode)"
    if check_primary; then
        primary_status="healthy"
        primary_ok=1
    else
        primary_status="unhealthy"
    fi

    if check_fallback; then
        fallback_status="healthy"
        fallback_ok=1
    else
        fallback_status="unhealthy"
    fi

    printf 'source-file: %s\n' "$SOURCE_FILE"
    printf 'current-mode: %s\n' "$current"
    printf 'primary: %s\n%s' "$primary_status" "$PRIMARY_REPORT_TEXT"
    printf 'fallback: %s\n%s' "$fallback_status" "$FALLBACK_REPORT_TEXT"

    if (( primary_ok == 1 )); then
        return 0
    fi

    if (( fallback_ok == 1 )); then
        return 2
    fi

    return 1
}

run_status() {
    local current
    current="$(detect_current_mode)"
    read_state

    printf 'source-file: %s\n' "$SOURCE_FILE"
    printf 'current-mode: %s\n' "$current"
    printf 'state-file: %s\n' "$STATE_FILE"
    if [[ -r "$STATE_FILE" ]]; then
        sed -n '1,80p' "$STATE_FILE"
    else
        printf 'state: absent\n'
    fi
}

pre_apt_impl() {
    local current primary_status fallback_status
    local primary_ok=0 fallback_ok=0
    local now age

    ensure_state_dir
    read_state
    current="$(detect_current_mode)"

    case "$current" in
        primary|fallback)
            ;;
        *)
            log_msg "source mode is ${current}; no automatic changes made"
            write_state "$current" "0" "unknown" "unknown"
            return 0
            ;;
    esac

    if [[ "$current" == "fallback" && "$LAST_PRIMARY_HEALTH" == "unhealthy" && "$RESTORE_CHECK_INTERVAL_SECONDS" -gt 0 ]]; then
        now="$(date +%s)"
        age="$(( now - LAST_RUN_EPOCH ))"
        if (( age >= 0 && age < RESTORE_CHECK_INTERVAL_SECONDS )); then
            log_msg "primary mirrors recently unhealthy ${age}s ago; staying on fallback without probing"
            return 0
        fi
    fi

    if check_primary; then
        primary_status="healthy"
        primary_ok=1
    else
        primary_status="unhealthy"
    fi

    if [[ "$current" == "primary" ]]; then
        if (( primary_ok == 1 )); then
            write_state "primary" "0" "$primary_status" "not_checked"
            log_msg "primary mirrors healthy; no source change"
            return 0
        fi

        if check_fallback; then
            fallback_status="healthy"
            fallback_ok=1
        else
            fallback_status="unhealthy"
        fi

        if (( fallback_ok == 1 )); then
            write_sources "fallback"
            write_state "fallback" "0" "$primary_status" "$fallback_status"
            log_msg "primary mirrors unhealthy; switched to fallback mirror"
        else
            write_state "primary" "0" "$primary_status" "$fallback_status"
            log_msg "primary and fallback mirrors unhealthy; no source change"
        fi
        return 0
    fi

    if (( primary_ok == 1 )); then
        GOOD_PRIMARY_CHECKS="$(( GOOD_PRIMARY_CHECKS + 1 ))"
        if (( GOOD_PRIMARY_CHECKS >= RESTORE_REQUIRED_GOOD_CHECKS )); then
            write_sources "primary"
            write_state "primary" "0" "$primary_status" "not_checked"
            log_msg "primary mirrors healthy for ${RESTORE_REQUIRED_GOOD_CHECKS} check(s); restored defaults"
        else
            write_state "fallback" "$GOOD_PRIMARY_CHECKS" "$primary_status" "not_checked"
            log_msg "primary mirrors healthy check ${GOOD_PRIMARY_CHECKS}/${RESTORE_REQUIRED_GOOD_CHECKS}; staying on fallback"
        fi
    else
        if check_fallback; then
            fallback_status="healthy"
        else
            fallback_status="unhealthy"
        fi
        write_state "fallback" "0" "$primary_status" "$fallback_status"
        log_msg "primary mirrors still unhealthy; staying on fallback"
    fi
}

run_pre_apt() {
    need_root "--pre-apt"
    PROBE_ATTEMPTS="$PRE_APT_PROBE_ATTEMPTS"
    with_lock pre_apt_impl
}

run_failover_impl() {
    local fallback_status

    if check_fallback; then
        fallback_status="healthy"
        write_sources "fallback"
        write_state "fallback" "0" "not_checked" "$fallback_status"
        printf 'Switched Ubuntu sources to fallback: %s\n' "$FALLBACK_URI"
    else
        fallback_status="unhealthy"
        write_state "$(detect_current_mode)" "0" "not_checked" "$fallback_status"
        printf 'Fallback mirror is unhealthy; no source change made.\n%s' "$FALLBACK_REPORT_TEXT" >&2
        return 1
    fi
}

run_failover() {
    need_root "--failover"
    with_lock run_failover_impl
}

run_restore_impl() {
    write_sources "primary"
    write_state "primary" "0" "manual_restore" "not_checked"
    printf 'Restored Ubuntu sources to primary defaults.\n'
}

run_restore() {
    need_root "--restore"
    with_lock run_restore_impl
}

main() {
    local mode="${1:-}"

    load_config

    case "$mode" in
        --check)
            run_check
            ;;
        --pre-apt)
            run_pre_apt
            ;;
        --failover)
            run_failover
            ;;
        --restore)
            run_restore
            ;;
        --status)
            run_status
            ;;
        -h|--help|"")
            usage
            ;;
        *)
            usage >&2
            return 64
            ;;
    esac
}

main "$@"
APT_MIRROR_HEALTH_SCRIPT

install -o root -g root -m 0755 "$tmp_script" "$SCRIPT_PATH"
rm -f "$tmp_script"

tmp_config="$(mktemp)"
cat > "$tmp_config" <<EOF
# Tunables for /usr/local/sbin/apt-mirror-health.
#
# The primary defaults keep normal Ubuntu traffic on the configured archive
# while restoring the security pocket to Ubuntu's canonical security endpoint.
SOURCE_FILE="${SOURCE_FILE}"
PRIMARY_ARCHIVE_URI="${PRIMARY_ARCHIVE_URI}"
PRIMARY_SECURITY_URI="${PRIMARY_SECURITY_URI}"
FALLBACK_URI="${FALLBACK_URI}"
CODENAME="${CODENAME}"

# A mirror must be reachable and reasonably fast to be considered healthy.
LATENCY_MAX_MS="3000"
CONNECT_TIMEOUT="5"
TOTAL_TIMEOUT="15"
MIN_BYTES_PER_SEC="50000"
LOW_SPEED_TIME="5"
PROBE_ATTEMPTS="2"
PRE_APT_PROBE_ATTEMPTS="1"

# Auto-restore only after consecutive healthy primary checks.
RESTORE_REQUIRED_GOOD_CHECKS="2"
RESTORE_CHECK_INTERVAL_SECONDS="1800"

# Avoid common IPv6 routing failures unless explicitly disabled.
FORCE_IPV4="1"
EOF

install -o root -g root -m 0644 "$tmp_config" "$CONFIG_PATH"
rm -f "$tmp_config"

tmp_hook="$(mktemp)"
cat > "$tmp_hook" <<'EOF'
APT::Update::Pre-Invoke {
	"[ $(id -u) -ne 0 ] || [ ! -x /usr/local/sbin/apt-mirror-health ] || /usr/bin/timeout 45 /usr/local/sbin/apt-mirror-health --pre-apt >/dev/null 2>&1 || true";
};

binary::apt::AptCli::Hooks::Upgrade {
	"[ $(id -u) -ne 0 ] || [ ! -x /usr/local/sbin/apt-mirror-health ] || /usr/bin/timeout 45 /usr/local/sbin/apt-mirror-health --pre-apt >/dev/null 2>&1 || true";
};
EOF

install -o root -g root -m 0644 "$tmp_hook" "$HOOK_PATH"
rm -f "$tmp_hook"

bash -n "$SCRIPT_PATH"
apt-config dump >/dev/null

printf 'Installed apt mirror health process.\n'
printf '  script: %s\n' "$SCRIPT_PATH"
printf '  config: %s\n' "$CONFIG_PATH"
printf '  apt hook: %s\n' "$HOOK_PATH"
printf '  source backup: %s\n' "$BACKUP_FILE"

if [[ "$RUN_INITIAL_CHECK" == "1" ]]; then
    printf '\nRunning initial pre-apt health check...\n'
    "$SCRIPT_PATH" --pre-apt
    "$SCRIPT_PATH" --status
else
    printf '\nSkipped initial health check. Run manually with:\n'
    printf '  sudo apt-mirror-health --check\n'
fi
