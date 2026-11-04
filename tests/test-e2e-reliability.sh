#!/usr/bin/env bash
# Reliability measurements must not pass without a working direct baseline.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
source "$ROOT/tests/lib/common.sh"
# Load the real probes without provisioning hosts or running the scenario.
sed -n '/^ping_loss_n(){/,/^}/p; /^ping_flood(){/,/^}/p; /^iperf_udp_loss(){/,/^}/p; /^valid_loss(){/,/^}/p; /^worse_by_margin(){/,/^}/p; /^assert_loss(){/,/^}/p; /^probe_pair(){/,/^}/p' \
  "$ROOT/tests/e2e/reliability/run.sh" > "$TEST_TMP/probes.sh"
source "$TEST_TMP/probes.sh"
MARGIN=0.5
RATE=50M
DURATION=10

check(){
  if "$@" > "$TEST_TMP/output" 2>&1; then
    printf 'PASS %s\n' "$*"
  else
    cat "$TEST_TMP/output" >&2
    printf 'FAIL %s\n' "$*" >&2
    exit 1
  fi
}

loss_comparisons(){ (
  local value
  assert_loss clean 0 0
  assert_loss boundary 0.5 0
  assert_loss common-loss 100 100
  assert_loss scientific 1e-8 0
  [[ "$FAILS" == 0 ]] || return 1
  assert_loss excess 0.501 0
  [[ "$FAILS" == 1 ]] || return 1
  for value in '' null false nan -1 100.1 '0 0' $'0\n0'; do
    FAILS=0
    assert_loss missing-baseline 0 "$value"
    [[ "$FAILS" == 1 ]] || return 1
    FAILS=0
    assert_loss missing-tunnel "$value" 0
    [[ "$FAILS" == 1 ]] || return 1
  done
) ; }

ping_failures(){ (
  local probe rc result status
  on(){
    if [[ "$status" == 1 ]]; then
      echo '100 packets transmitted, 0 received, 100% packet loss'
    else
      echo '100 packets transmitted, 100 received, 0% packet loss'
    fi
    return "$status"
  }
  for probe in ping_loss_n ping_flood; do
    for status in 0 1 2 127 255; do
      rc=0
      result="$("$probe" host target 100 0.01)" || rc=$?
      if [[ "$status" == 0 ]]; then
        [[ "$rc" == 0 && "$result" == 0 ]] || return 1
      elif [[ "$status" == 1 ]]; then
        [[ "$rc" == 0 && "$result" == 100 ]] || return 1
      else
        [[ "$rc" != 0 && -z "$result" ]] || return 1
      fi
    done
  done
) ; }

iperf_failures(){ (
  local mode rc result calls="$TEST_TMP/iperf-calls"
  on(){
    printf '%s\n' "$2" >> "$calls"
    case "$2" in
      *'systemd-run --unit=ipsrv'*) [[ "$mode" != setup-failure ]] ;;
      'iperf3 -c '*)
        case "$mode" in
          empty-json) : ;;
          missing-metric) echo '{"end":{}}' ;;
          truncated-json) echo '{"end":{"sum":' ;;
          *) echo '{"end":{"sum":{"lost_percent":0}}}' ;;
        esac
        [[ "$mode" != client-failure ]] ;;
    esac
  }
  for mode in success setup-failure client-failure empty-json missing-metric truncated-json; do
    : > "$calls"
    rc=0
    result="$(iperf_udp_loss client target server)" || rc=$?
    if [[ "$mode" == success ]]; then
      [[ "$rc" == 0 && "$result" == 0 ]] || return 1
    elif [[ "$mode" == setup-failure || "$mode" == client-failure ]]; then
      [[ "$rc" != 0 && -z "$result" ]] || return 1
    else
      FAILS=0
      assert_loss "$mode" "$result" 0
      [[ "$FAILS" == 1 ]] || return 1
    fi
    # Server cleanup still runs after setup or client failure.
    [[ "$(tail -1 "$calls")" == 'systemctl stop ipsrv 2>/dev/null; systemctl reset-failed ipsrv 2>/dev/null' ]] || return 1
    if [[ "$mode" == setup-failure ]] && grep -q '^iperf3 -c ' "$calls"; then return 1; fi
  done
) ; }

check loss_comparisons
check ping_failures
check iperf_failures

# A separate shell keeps errexit active even though check itself uses an if.
cat > "$TEST_TMP/pair.sh" <<'SH'
set -euo pipefail
source "$RELIABILITY_COMMON"
source "$RELIABILITY_PROBES"
HOSTS=(a b)
PUBS=(public-a public-b)
VPNS=(mesh-a mesh-b)
RAW="$RELIABILITY_RAW"
MARGIN=0.5
PING_COUNT=100
FLOOD_COUNT=100
RATE=50M
DURATION=10
ping_loss_n(){ echo 0; return 1; }
ping_flood(){ echo 0; return 1; }
iperf_udp_loss(){ echo 0; return 1; }
probe_pair 0 1
[[ "$FAILS" == 3 ]]
[[ "$(wc -l < "$RAW")" -eq 3 ]]
awk -F '\t' 'NF != 5 || $4 != "?" || $5 != "?" {exit 1}' "$RAW"
SH
check env RELIABILITY_COMMON="$ROOT/tests/lib/common.sh" \
  RELIABILITY_PROBES="$TEST_TMP/probes.sh" RELIABILITY_RAW="$TEST_TMP/pair.raw" \
  bash "$TEST_TMP/pair.sh"
