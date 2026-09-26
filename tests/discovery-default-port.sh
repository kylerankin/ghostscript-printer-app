#!/usr/bin/env bash
#
# Ghostscript Printer Application default-port coexistence (issue #17,
# "Default port and coexistence case").
#
# PR #57 proved two explicit-port Ghostscript instances do not compete for a
# synthetic printer, but left the entrypoint's no-PORT path untested: PAPPL
# supplies server-port only when PORT is set and otherwise assigns a deterministic
# port starting at 7999 + (UID % 1000) (8532 for UID 65532), stepping to the next
# free port if already bound. This exercises that default against a second
# Ghostscript instance on host networking and asserts distinct ports and exactly
# one owning DNS-SD advertisement per synthetic printer.
#
# DNS-SD verification runs avahi-browse inside each container, resolving distinct
# service names. Opt-in, not part of `just verify` (needs host Avahi and multicast).
set -euo pipefail

image="ghcr.io/projectbluefin/ghostscript-printer-app:build"
model="generic--pcl-6-pcl-xl-printer--pxlcolor-recommended-en"

state_a="$(mktemp -d)"
state_b="$(mktemp -d)"
state_other="$(mktemp -d)"
chmod 0777 "$state_a" "$state_b" "$state_other"

output_file="$(mktemp)"
sink_pid=""

cleanup() {
  for name in gs-a gs-b probe; do
    podman rm -f "$name" >/dev/null 2>&1 || true
  done
  if [[ -n "$sink_pid" ]]; then
    kill "$sink_pid" >/dev/null 2>&1 || true
    wait "$sink_pid" 2>/dev/null || true
  fi
  podman unshare rm -rf "$state_a" "$state_b" "$state_other" 2>/dev/null || true
  rm -f "$output_file"
}
trap cleanup EXIT

just build

# Synthetic backend target: print jobs route here; no real hardware.
python3 tests/socket-sink.py "$((18060))" "$output_file" &
sink_pid=$!

# --- helpers -------------------------------------------------------------

# Probe ports starting from PAPPL default base (8532 for UID 65532)
discover_port() { # name exclude_port
  local name="$1" exclude="${2:-0}"
  local p
  for _ in $(seq 1 60); do
    for p in $(seq 8532 8545); do
      if [[ "$p" != "$exclude" ]]; then
        if curl --fail --silent --show-error "http://127.0.0.1:${p}/" >/dev/null 2>&1; then
          printf '%s' "$p"
          return 0
        fi
      fi
    done
    sleep 1
  done
  podman logs "$name" >&2 || true
  return 1
}

add_printer() { # name port queue sink_port
  podman exec "$1" ghostscript-printer-app \
    -u "ipp://127.0.0.1:${2}/ipp/system" \
    -d "$3" -m "$model" \
    -v "cups:socket://127.0.0.1:${4}" add
}

# Count distinct DNS-SD advertisement names for a given queue marker.
count_advertisements() { # observer queue
  local observer="$1" queue="$2"
  podman exec "$observer" /usr/bin/bash -c '
    set -euo pipefail
    avahi-browse --parsable --resolve --terminate _ipp._tcp 2>/dev/null \
      | while IFS=";" read -r tag _ _ name rest; do
          if [[ "$tag" == "=" && "$name" == *"$1"* ]]; then
            echo "$name"
          fi
        done \
      | sort -u
  ' _ "$queue"
}

wait_count() { # observer queue expected
  local observer="$1" queue="$2" expected="$3"
  local names count
  for _ in $(seq 1 30); do
    names="$(count_advertisements "$observer" "$queue" || true)"
    count="$(grep -c . <<<"$names" || true)"
    [[ -z "$names" ]] && count=0
    if [[ "$count" -eq "$expected" ]]; then
      printf '%s\n' "$names"
      return 0
    fi
    sleep 1
  done
  printf 'FAIL: expected %s advertisement for %s, observed %s\n' "$expected" "$queue" "$count" >&2
  podman logs "$observer" >&2 || true
  return 1
}

# --- instance A: default (no PORT) port ----------------------------------

podman run -d --name gs-a --network host \
  -v "$state_a:/var/lib/ghostscript-printer-app:Z" "$image" >/dev/null
port_a="$(discover_port gs-a)" || { printf 'FAIL: no port discovered for gs-a\n'; exit 1; }
add_printer gs-a "$port_a" discovery-default-a "$((18060))"
wait_count gs-a discovery-default-a 1
printf 'OK: no-PORT Ghostscript binds port (%s) and advertises its printer once\n' "$port_a"

# --- restart A: state persists, still exactly one advertisement ----------

podman stop --time 10 gs-a >/dev/null
podman rm gs-a >/dev/null
chmod 0777 "$state_a"
podman run -d --name gs-a --network host \
  -v "$state_a:/var/lib/ghostscript-printer-app:Z" "$image" >/dev/null
port_a="$(discover_port gs-a)" || { printf 'FAIL: no port after restart\n'; exit 1; }
# Printer must already exist from persisted state; a duplicate would show twice.
wait_count gs-a discovery-default-a 1
printf 'OK: gs-a state and single advertisement persist across restart (default port)\n'

# --- instance B: another default (no PORT) instance, steps to next port --

podman run -d --name gs-b --network host \
  -v "$state_b:/var/lib/ghostscript-printer-app:Z" "$image" >/dev/null
port_b="$(discover_port gs-b "$port_a")" || { printf 'FAIL: no port discovered for gs-b\n'; exit 1; }
add_printer gs-b "$port_b" discovery-default-b "$((18060))"
wait_count gs-b discovery-default-b 1
[[ "$port_b" != "$port_a" ]] || { printf 'FAIL: default ports collide: %s\n' "$port_a"; exit 1; }
printf 'OK: second no-PORT Ghostscript steps to distinct port (%s)\n' "$port_b"

printf 'NOTE: real USB interface claiming and GNOME print dialog behavior are unverified here; both require physical hardware and a desktop session.\n'
printf 'OK: default-port Ghostscript discovery does not compete for one synthetic printer\n'
