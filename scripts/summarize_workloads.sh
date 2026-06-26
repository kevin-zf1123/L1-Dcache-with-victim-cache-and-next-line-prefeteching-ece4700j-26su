#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim"
OUTPUT="${SIM_DIR}/workload_results.csv"

mkdir -p "${SIM_DIR}"

awk '
BEGIN {
    print "name,ways,victim_entries,vc_mode,prefetch,pb_entries,pb_mode,accesses,hits,misses,victim_hits,mem_reads,mem_writes,useful,useless,pollution,dropped,pb_alloc,pb_promote,pb_evict,pb_full_drop,cycles"
}
/^WORKLOAD_RESULT / {
    delete value
    for (field = 2; field <= NF; field++) {
        split($field, pair, "=")
        value[pair[1]] = pair[2]
    }
    print value["name"] "," value["ways"] "," value["vc"] "," \
          value["vc_mode"] "," \
          value["prefetch"] "," value["pb"] "," value["pb_mode"] "," \
          value["accesses"] "," value["hits"] "," \
          value["misses"] "," value["victim_hits"] "," value["mem_reads"] "," \
          value["mem_writes"] "," value["useful"] "," value["useless"] "," \
          value["pollution"] "," value["dropped"] "," value["pb_alloc"] "," \
          value["pb_promote"] "," value["pb_evict"] "," \
          value["pb_full_drop"] "," value["cycles"]
}
' "${SIM_DIR}"/workload_*.log "${SIM_DIR}"/trace_replay_*.log > "${OUTPUT}"

echo "Workload CSV written to ${OUTPUT}."
