#!/usr/bin/env bash
# Repoint the Wazuh manager's OpenCTI integration, and/or move agents to a new
# manager address. Everything is a dry run until you pass --apply.
#
#   # 1. OpenCTI moved to a new URL
#   ./scripts/wazuh-retarget.sh --new-url https://opencti.internal.example
#   ./scripts/wazuh-retarget.sh --new-url https://opencti.internal.example --apply
#
#   # 2. Same, driven from your workstation over SSH
#   ./scripts/wazuh-retarget.sh --ssh manager@wazuh-server \
#       --new-url https://opencti.internal.example --apply
#
#   # 3. The MANAGER moved: push the new address to every agent
#   ./scripts/wazuh-retarget.sh --manager-address wazuh.internal.example --apply
#
# Touches, on the manager:
#   /var/ossec/etc/ossec.conf                  <hook_url> in the <integration> block
#   /var/ossec/integrations/opencti.env        OPENCTI_URL
#   /var/ossec/etc/shared/default/agent.conf   centralised manager address
#
# Never touches OPENCTI_TOKEN. The token keeps working because the platform data
# is restored intact — rotate it separately.
set -euo pipefail

WAZUH_DIR="${WAZUH_DIR:-/var/ossec}"
OSSEC_CONF="$WAZUH_DIR/etc/ossec.conf"
INTEG_ENV="$WAZUH_DIR/integrations/opencti.env"
AGENT_CONF="$WAZUH_DIR/etc/shared/default/agent.conf"

NEW_URL=""
NEW_MANAGER=""
SSH_TARGET=""
APPLY=0
SKIP_CHECK=0
VERIFY_SECONDS="${VERIFY_SECONDS:-20}"

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --new-url)         NEW_URL="${2:-}"; shift 2 ;;
    --manager-address) NEW_MANAGER="${2:-}"; shift 2 ;;
    --ssh)             SSH_TARGET="${2:-}"; shift 2 ;;
    --apply)           APPLY=1; shift ;;
    --dry-run)         APPLY=0; shift ;;
    --skip-check)      SKIP_CHECK=1; shift ;;
    --verify-seconds)  VERIFY_SECONDS="${2:-20}"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 ;;
  esac
done

if [ -z "$NEW_URL" ] && [ -z "$NEW_MANAGER" ]; then
  echo "nothing to do: pass --new-url and/or --manager-address" >&2
  usage 1
fi

NEW_URL="${NEW_URL%/}"
NEW_URL="${NEW_URL%/graphql}"

runq() {
  if [ -n "$SSH_TARGET" ]; then ssh "$SSH_TARGET" "$1"; else bash -c "$1"; fi
}
say()  { printf '%s\n' "$*"; }
plan() { if [ "$APPLY" -eq 1 ]; then say "  RUN   $*"; else say "  WOULD $*"; fi; }

STAMP="$(date +%Y%m%dT%H%M%S)"
[ "$APPLY" -eq 1 ] || say "DRY RUN — nothing will change. Add --apply to execute."

# ------------------------------------------------------------- OpenCTI URL
if [ -n "$NEW_URL" ]; then
  say
  say "== OpenCTI URL -> $NEW_URL"
  say "   manager: ${SSH_TARGET:-this host}"

  current="$(runq "grep -oP '(?<=<hook_url>)[^<]+' '$OSSEC_CONF' 2>/dev/null | head -1" || true)"
  say "   current hook_url: ${current:-<none found>}"

  if [ "$SKIP_CHECK" -eq 0 ]; then
    code="$(runq "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$NEW_URL/graphql' || echo unreachable")"
    case "$code" in
      200|400|401|403|405) say "   reachability: HTTP $code — good (auth/verb replies are expected on /graphql)" ;;
      *) say "   WARNING: '$code' from $NEW_URL/graphql — fix DNS/TLS/firewall first" ;;
    esac
    hostonly="$(printf '%s' "$NEW_URL" | sed -E 's#^https?://##; s#[:/].*##')"
    cert="$(runq "echo | openssl s_client -connect '$hostonly:443' -servername '$hostonly' 2>/dev/null | openssl x509 -noout -subject -dates 2>/dev/null" || true)"
    [ -n "$cert" ] && say "   certificate: $cert"
  fi

  plan "back up ossec.conf and opencti.env (.bak.$STAMP)"
  plan "set <hook_url> to $NEW_URL"
  plan "set OPENCTI_URL=$NEW_URL"
  plan "systemctl restart wazuh-manager"

  if [ "$APPLY" -eq 1 ]; then
    runq "cp -a '$OSSEC_CONF' '$OSSEC_CONF.bak.$STAMP'"
    runq "cp -a '$INTEG_ENV' '$INTEG_ENV.bak.$STAMP'"

    runq "sed -i 's#<hook_url>[^<]*</hook_url>#<hook_url>$NEW_URL</hook_url>#g' '$OSSEC_CONF'"

    if runq "grep -q '^OPENCTI_URL=' '$INTEG_ENV'" 2>/dev/null; then
      runq "sed -i 's#^OPENCTI_URL=.*#OPENCTI_URL=$NEW_URL#' '$INTEG_ENV'"
    else
      runq "printf 'OPENCTI_URL=%s\n' '$NEW_URL' >> '$INTEG_ENV'"
    fi

    say "   now hook_url:    $(runq "grep -oP '(?<=<hook_url>)[^<]+' '$OSSEC_CONF' | head -1")"
    say "   now OPENCTI_URL: $(runq "grep '^OPENCTI_URL=' '$INTEG_ENV'")"

    runq "systemctl restart wazuh-manager"
    say "   wazuh-manager restarted"
  fi
fi

# --------------------------------------------------------- agent addressing
py_agent_conf() {
  local script
  script="$(cat <<'PYEOF'
import sys, re, pathlib
path, addr = sys.argv[1], sys.argv[2]
BEGIN = "<!-- BEGIN opencti-airgap:manager-address -->"
END = "<!-- END opencti-airgap:manager-address -->"
block = (
    BEGIN + "\n"
    "<agent_config>\n"
    "  <client>\n"
    "    <server>\n"
    f"      <address>{addr}</address>\n"
    "      <port>1514</port>\n"
    "      <protocol>tcp</protocol>\n"
    "    </server>\n"
    "  </client>\n"
    "</agent_config>\n"
    + END
)
p = pathlib.Path(path)
text = p.read_text() if p.exists() else ""
if BEGIN in text and END in text:
    text = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), block, text, flags=re.S)
elif text.strip():
    text = text.rstrip() + "\n\n" + block + "\n"
else:
    text = block + "\n"
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(text)
print("wrote", path)
PYEOF
)"
  if [ -n "$SSH_TARGET" ]; then
    printf '%s' "$script" | ssh "$SSH_TARGET" python3 - "$AGENT_CONF" "$NEW_MANAGER"
  else
    printf '%s' "$script" | python3 - "$AGENT_CONF" "$NEW_MANAGER"
  fi
}

if [ -n "$NEW_MANAGER" ]; then
  say
  say "== manager address -> $NEW_MANAGER (centralised agent.conf)"
  say "   file: $AGENT_CONF"
  present="$(runq "grep -c 'BEGIN opencti-airgap:manager-address' '$AGENT_CONF' 2>/dev/null || true")"
  say "   managed block already present: ${present:-0}"

  plan "write/update the managed block with <address>$NEW_MANAGER</address>"
  plan "systemctl restart wazuh-manager so agents receive the new centralised config"

  if [ "$APPLY" -eq 1 ]; then
    runq "cp -a '$AGENT_CONF' '$AGENT_CONF.bak.$STAMP' 2>/dev/null || true"
    py_agent_conf
    runq "systemctl restart wazuh-manager"
    say "   wazuh-manager restarted"
    say "   agents pick this up on their next connection to the manager"
  fi
fi

# ---------------------------------------------------------------- verify
if [ "$APPLY" -eq 1 ]; then
  say
  say "== verify — do not skip this"
  say "   This integration fails SILENTLY: no output looks identical to 'no IoCs matched'."
  say "   Trigger one alert from a monitored endpoint, then watch:"
  say "     tail -f $WAZUH_DIR/logs/integrations.log"
  if [ "${VERIFY_SECONDS:-0}" -gt 0 ] 2>/dev/null; then
    say "   watching for ${VERIFY_SECONDS}s ..."
    runq "timeout ${VERIFY_SECONDS}s tail -n 0 -F '$WAZUH_DIR/logs/integrations.log'" || true
  fi
else
  say
  say "Nothing changed. Re-run with --apply."
fi
