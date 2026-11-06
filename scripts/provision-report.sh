#!/usr/bin/env bash
#
# provision-report.sh - final provisioning report for cattle-not-laptops.
#
# The script replaces the former Python callback. Ansible is run with the
# ansible.posix.jsonl stdout callback; the JSONL stream is stored, rendered
# live in a readable form, and analysed with jq/awk at the end of the run.
#
# Usage:
#   provision-report.sh run <ansible command...>   # run + live output + report
#   provision-report.sh report [events.jsonl]      # regenerate report only
#
# Outputs:
#   report log : /var/log/ansipull-report.log      (PROVISIONING_REPORT_LOG)
#   events log : /var/log/ansipull-events.jsonl    (PROVISIONING_EVENTS_LOG)
#   journal    : stdout of the wrapper, plus syslog tag cattle-not-laptops
#
# When /var/log is not writable the logs fall back to
# ${XDG_STATE_HOME:-$HOME/.local/state}/cattle-not-laptops/.
#
# Requires: bash, jq, awk, sed, logger (optional).

set -uo pipefail

PROG=${0##*/}
DEFAULT_REPORT_LOG=/var/log/ansipull-report.log
DEFAULT_EVENTS_LOG=/var/log/ansipull-events.jsonl
FALLBACK_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/cattle-not-laptops
JOURNAL_TAG=cattle-not-laptops

info() { printf '%s\n' "$*" >&2; }
die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  provision-report.sh run <ansible command...>
      Run Ansible with ansible.posix.jsonl, stream a readable log, then
      generate the final provisioning report.

  provision-report.sh report [events.jsonl]
      Generate the final report from a JSONL events file (default:
      /var/log/ansipull-events.jsonl or the fallback path).

Environment:
  PROVISIONING_REPORT_LOG   report log path (default /var/log/ansipull-report.log)
  PROVISIONING_EVENTS_LOG   raw events path (default /var/log/ansipull-events.jsonl)
EOF
}

# Return a writable path: the preferred one when its directory is writable,
# otherwise the same file name inside the per-user fallback directory.
resolve_path() {
  local preferred=$1 fallback_dir=$2 dir
  dir=$(dirname -- "$preferred")
  if [ -d "$dir" ] && [ -w "$dir" ]; then
    printf '%s' "$preferred"
    return 0
  fi
  mkdir -p -- "$fallback_dir" 2>/dev/null || true
  printf '%s/%s' "$fallback_dir" "$(basename -- "$preferred")"
}

# True when the task whose YAML reference is "path:line" has ignore_errors.
task_has_ignore_errors() {
  local ref=${1:-} file start
  [ -n "$ref" ] || return 1
  file=${ref%:*}
  start=${ref##*:}
  [ -r "$file" ] || return 1
  case $start in
    ''|*[!0-9]*) return 1 ;;
  esac
  awk -v start="$start" '
    NR < start { next }
    NR > start && /^[[:space:]]*-[[:space:]]+name:/ { exit }
    /ignore_errors:[[:space:]]*(true|yes|"true"|"yes")/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# Shared jq helpers used by every query below.
JQ_FUNCS=$(cat <<'JQ'
def clean: tostring | gsub("[\\t\\r\\n]+"; " ");
def short_action: (. // "") | tostring | split(".") | last;
def item_label($r; $task):
  ( [ $r.item, $r.args.name, $r.args.path, $r.args.dest ]
    | map(select(. != null and (. | tostring) != ""))
    | if length > 0 then .[0] else $task end
    | if type == "array" then map(tostring) | join(",") else tostring end );
def classify($r; $task):
  ($r.action | short_action) as $a
  | ($r.args.state // "" | tostring) as $state
  | (item_label($r; $task) | clean) as $label
  | if ($a | IN("package", "dnf", "yum", "apt", "rpm")) then
      if $state == "absent"
      then ["removed", "package removed: \($label)"]
      else ["installed", "package installed/updated: \($label)"]
      end
    elif $a == "yum_repository" then
      ["modified", "package repository configured: \($label)"]
    elif $a == "sysctl" then
      ["modified", "sysctl \($label) = \($r.args.value // "?" | clean)"]
    elif $a == "git" then
      ["modified", "git repository synced: \($label)"]
    elif ($a | IN("copy", "template", "file", "lineinfile", "blockinfile",
                  "get_url", "unarchive", "archive")) then
      if $state == "absent"
      then ["removed", "path removed: \($label)"]
      else ["modified", "file changed: \($label)"]
      end
    elif ($a | IN("service", "systemd")) then
      if ($state | IN("stopped", "disabled", "absent"))
      then ["removed", "service \($state): \($label)"]
      else ["modified", "service \(($state // "started") | clean): \($label)"]
      end
    elif ($a | IN("command", "shell", "raw", "script")) then
      ["modified", "command ran: \($task | clean)" +
                   (if $r.item != null then " [\($r.item | clean)]" else "" end)]
    else
      ["modified", "changed: \($task | clean)" +
                   (if $r.item != null then " [\($r.item | clean)]" else "" end)]
    end;
JQ
)

jq_run() {
  local program=$1
  shift
  jq -r "$JQ_FUNCS
$program" "$@"
}

# Live renderer: one JSONL line in, zero or more readable lines out.
render_event() {
  jq -r '
    if ._event == "v2_playbook_on_task_start" then
      "\nTASK [\(.task.name)]"
    elif ._event == "v2_runner_on_ok" then
      .hosts | to_entries[] | .key as $host | .value as $r
      | if ($r.results | type) == "array" then
          $r.results[]
          | (if .changed then "changed" else "ok" end) as $state
          | "\($state): [\($host)]" +
            (if .item != null then " \(.item | tostring)" else "" end) +
            (if (.msg // "") != "" and .msg != "All items completed"
             then " => \(.msg)" else "" end)
        else
          (if $r.changed then "changed" else "ok" end) as $state
          | "\($state): [\($host)]" +
            (if ($r.msg // "") != "" then " => \($r.msg)" else "" end)
        end
    elif ._event == "v2_runner_on_failed" then
      .hosts | to_entries[] | .key as $host | .value as $r
      | if ($r.results | type) == "array" then
          $r.results[] | select(.failed)
          | "fatal: [\($host)]" +
            (if .item != null then " \(.item | tostring)" else "" end) +
            " => \(.msg // "failed")"
        else
          "fatal: [\($host)] => \($r.msg // "failed")"
        end
    elif ._event == "v2_runner_on_skipped" then
      .hosts | to_entries[] | "skipping: [\(.key)]"
    elif ._event == "v2_runner_on_unreachable" then
      .hosts | to_entries[] | "unreachable: [\(.key)] => \(.value.msg // "unreachable")"
    elif ._event == "v2_playbook_on_stats" then
      "\nPLAY RECAP",
      (.stats | to_entries[]
       | "\(.key): ok=\(.value.ok) changed=\(.value.changed) failed=\(.value.failures) ignored=\(.value.ignored) skipped=\(.value.skipped) unreachable=\(.value.unreachable)")
    else empty
    end
  ' <<<"${1:-}" 2>/dev/null
}

# Read Ansible output, store JSONL events and print a readable stream.
stream_filter() {
  local events=$1 line
  while IFS= read -r line; do
    case $line in
      '{"_event"'*)
        printf '%s\n' "$line" >>"$events"
        render_event "$line"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done
}

# Build the report body into <tmp>/report.txt.
build_report() {
  local events=$1 tmp=$2 status=$3 report_file=$4
  local playbook started finished hosts
  local -a sections=(installed modified removed ignored failed unreachable skipped)

  : >"$tmp/rows.tsv"
  : >"$tmp/failed.tsv"

  # Changed / ok results (also the successful items of a partly failed loop).
  if [ -s "$events" ]; then
    jq_run '
      select(._event == "v2_runner_on_ok")
      | .task.name as $tname
      | .hosts | to_entries[]
      | .key as $host
      | .value as $h
      | ( if ($h.results | type) == "array" then
            $h.results[]
            | { item: .item,
                changed: (.changed // false),
                action: ($h.action // .action),
                args: ((.invocation.module_args) // ($h.invocation.module_args) // {}) }
          else
            { item: $h.item,
              changed: ($h.changed // false),
              action: $h.action,
              args: ($h.invocation.module_args // {}) }
          end )
      | select(.changed)
      | classify(.; $tname) as $c
      | [$c[0], $host, ($tname | clean), ($c[1] | clean)] | @tsv
    ' "$events" >>"$tmp/rows.tsv" 2>/dev/null || true

    # Failures: keep path so bash can tell ignore_errors from real failures.
    jq_run '
      select(._event == "v2_runner_on_failed")
      | .task.name as $tname
      | .task.path as $tpath
      | .hosts | to_entries[]
      | .key as $host
      | .value as $h
      | ( if ($h.results | type) == "array" then
            $h.results[]
            | { item: .item,
                changed: (.changed // false),
                failed: (.failed // false),
                msg: (.msg // ""),
                action: ($h.action // .action),
                args: ((.invocation.module_args) // ($h.invocation.module_args) // {}) }
          else
            { item: $h.item,
              changed: ($h.changed // false),
              failed: true,
              msg: ($h.msg // "failed"),
              action: $h.action,
              args: ($h.invocation.module_args // {}) }
          end )
      | if .failed then
          ["__FAILED__", $host, ($tname | clean), (.msg | clean), ($tpath // ""),
           (if .item != null then (.item | clean) else "" end)] | @tsv
        elif .changed then
          classify(.; $tname) as $c
          | [$c[0], $host, ($tname | clean), ($c[1] | clean), ($tpath // ""), ""] | @tsv
        else empty end
    ' "$events" >>"$tmp/failed.tsv" 2>/dev/null || true

    if [ -s "$tmp/failed.tsv" ]; then
      local cat host task detail path item label
      while IFS=$'\t' read -r cat host task detail path item; do
        [ -n "${cat:-}" ] || continue
        label=$task
        [ -n "${item:-}" ] && label="$task [$item]"
        if [ "$cat" = "__FAILED__" ]; then
          if task_has_ignore_errors "${path:-}"; then
            printf 'ignored\t%s\t%s\t%s\n' "$host" "$label" "$detail" >>"$tmp/rows.tsv"
          else
            printf 'failed\t%s\t%s\t%s\n' "$host" "$label" "$detail" >>"$tmp/rows.tsv"
          fi
        else
          printf '%s\t%s\t%s\t%s\n' "$cat" "$host" "$task" "$detail" >>"$tmp/rows.tsv"
        fi
      done <"$tmp/failed.tsv"
    fi

    jq_run '
      select(._event == "v2_runner_on_skipped")
      | .task.name as $tname
      | .hosts | to_entries[]
      | ["skipped", .key, ($tname | clean),
         ((.value.skip_reason // .value.msg // "condition not met") | clean)] | @tsv
    ' "$events" >>"$tmp/rows.tsv" 2>/dev/null || true

    jq_run '
      select(._event == "v2_runner_on_unreachable")
      | .task.name as $tname
      | .hosts | to_entries[]
      | ["unreachable", .key, ($tname | clean),
         ((.value.msg // "unreachable") | clean)] | @tsv
    ' "$events" >>"$tmp/rows.tsv" 2>/dev/null || true
  fi

  # Redact credentials embedded in URLs (https://TOKEN@host/...).
  sed -E -i 's#(https?://)[^/@[:space:]]+@#\1***@#g' "$tmp/rows.tsv" 2>/dev/null || true

  playbook=$(jq -r 'select(._event == "v2_playbook_on_play_start") | .play.path // empty' "$events" 2>/dev/null | head -n 1)
  [ -n "$playbook" ] || playbook="local.yml"
  case $playbook in
    *:[0-9]*) playbook=${playbook%:*} ;;
  esac
  started=$(jq -r 'select(._event == "v2_playbook_on_play_start") | ._timestamp // empty' "$events" 2>/dev/null | head -n 1)
  if [ -n "$started" ]; then
    started=$(date -d "$started" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$started")
  else
    started="unknown"
  fi
  finished=$(date '+%Y-%m-%d %H:%M:%S %Z')
  hosts=$(jq -r 'select(._event == "v2_playbook_on_stats") | .stats | keys[]' "$events" 2>/dev/null | paste -sd, -)
  [ -n "$hosts" ] || hosts="localhost"

  {
    printf '%s\n' "================================================================================"
    printf '%s\n' " CATTLE NOT LAPTOPS - FINAL PROVISIONING REPORT"
    printf '%s\n' "================================================================================"
    printf ' Playbook : %s\n' "$playbook"
    printf ' Started  : %s\n' "$started"
    printf ' Finished : %s\n' "$finished"
    printf ' Hosts    : %s\n' "$hosts"
    printf ' Events   : %s\n' "$events"
    printf ' Log      : %s\n' "$report_file"
    printf ' Status   : exit %s\n' "$status"
    printf '%s\n\n' "--------------------------------------------------------------------------------"

    local section title count
    for section in "${sections[@]}"; do
      case $section in
        installed)   title="INSTALLED / UPDATED" ;;
        modified)    title="MODIFIED" ;;
        removed)     title="REMOVED" ;;
        ignored)     title="IGNORED (failure did not stop the run)" ;;
        failed)      title="FAILED" ;;
        unreachable) title="UNREACHABLE" ;;
        skipped)     title="SKIPPED" ;;
      esac
      count=$(awk -F'\t' -v c="$section" '$1 == c { n++ } END { print n + 0 }' "$tmp/rows.tsv")
      printf ' %s (%s)\n' "$title" "$count"
      if [ "$count" -eq 0 ]; then
        printf '   (none)\n'
      else
        awk -F'\t' -v c="$section" '$1 == c { printf "   [%s] %s: %s\n", $2, $3, $4 }' "$tmp/rows.tsv"
      fi
      printf '\n'
    done

    printf '%s\n' "--------------------------------------------------------------------------------"
    printf '%s\n' " SUMMARY"
    if jq -e 'select(._event == "v2_playbook_on_stats")' "$events" >/dev/null 2>&1; then
      jq -r '
        select(._event == "v2_playbook_on_stats")
        | .stats | to_entries[]
        | "   \(.key): ok=\(.value.ok) changed=\(.value.changed) failed=\(.value.failures) ignored=\(.value.ignored) skipped=\(.value.skipped) unreachable=\(.value.unreachable)"
      ' "$events"
    else
      printf '%s\n' "   no stats (the run ended before the play recap)"
    fi
    printf '%s\n' "================================================================================"
  } >"$tmp/report.txt"
}

# Print the report, append it to the log and send it to the journal.
emit_report() {
  local tmp=$1 report_file=$2
  local body
  body=$(cat "$tmp/report.txt")

  if mkdir -p -- "$(dirname -- "$report_file")" 2>/dev/null &&
     printf '%s\n' "$body" >>"$report_file" 2>/dev/null; then
    chmod 600 "$report_file" 2>/dev/null || true
    info "provisioning report: $report_file"
  else
    info "warning: cannot write report log $report_file"
  fi

  # stdout is captured by the systemd journal; logger covers manual runs.
  printf '%s\n' "$body"
  if [ -z "${JOURNAL_STREAM:-}" ] && command -v logger >/dev/null 2>&1; then
    printf '%s\n' "$body" | logger -t "$JOURNAL_TAG" -- 2>/dev/null || true
  fi
}

report_mode() {
  local events=${1:-}
  local report_file fallback_dir tmp

  command -v jq >/dev/null 2>&1 || die "jq is required (install it with: sudo dnf install -y jq)"
  fallback_dir=$FALLBACK_DIR
  events=${events:-$(resolve_path "${PROVISIONING_EVENTS_LOG:-$DEFAULT_EVENTS_LOG}" "$fallback_dir")}
  report_file=$(resolve_path "${PROVISIONING_REPORT_LOG:-$DEFAULT_REPORT_LOG}" "$fallback_dir")

  if [ ! -r "$events" ]; then
    die "events file not readable: $events"
  fi

  tmp=$(mktemp -d "${TMPDIR:-/tmp}/provision-report.XXXXXX") || die "cannot create temporary directory"
  build_report "$events" "$tmp" "${PROVISIONING_STATUS:-0}" "$report_file"
  emit_report "$tmp" "$report_file"
  rm -rf -- "$tmp"
}

run_mode() {
  local -a cmd=("$@")
  local events_file report_file fallback_dir status

  [ "${#cmd[@]}" -gt 0 ] || die "usage: $PROG run <ansible command...>"
  command -v jq >/dev/null 2>&1 || die "jq is required (install it with: sudo dnf install -y jq)"
  command -v "${cmd[0]}" >/dev/null 2>&1 || die "command not found: ${cmd[0]}"

  fallback_dir=$FALLBACK_DIR
  events_file=$(resolve_path "${PROVISIONING_EVENTS_LOG:-$DEFAULT_EVENTS_LOG}" "$fallback_dir")
  report_file=$(resolve_path "${PROVISIONING_REPORT_LOG:-$DEFAULT_REPORT_LOG}" "$fallback_dir")

  mkdir -p -- "$(dirname -- "$events_file")" 2>/dev/null || true
  : >"$events_file"
  chmod 600 "$events_file" 2>/dev/null || true
  info "events log: $events_file"

  ANSIBLE_STDOUT_CALLBACK=ansible.posix.jsonl \
  ANSIBLE_JSON_INDENT=0 \
  ANSIBLE_NOCOLOR=1 \
  ANSIBLE_FORCE_COLOR=0 \
    "${cmd[@]}" 2>&1 | stream_filter "$events_file"
  status=${PIPESTATUS[0]}

  printf '\n'
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/provision-report.XXXXXX") || die "cannot create temporary directory"
  build_report "$events_file" "$tmp" "$status" "$report_file"
  emit_report "$tmp" "$report_file"
  rm -rf -- "$tmp"

  return "$status"
}

main() {
  case ${1:-} in
    run)
      shift
      run_mode "$@"
      ;;
    report)
      shift
      report_mode "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
