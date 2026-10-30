#!/usr/bin/env bash
# Proxmox snapshot advisor. Runtime: Bash + jq + standard Ubuntu utilities only.
set -uo pipefail
umask 077
VERSION=2.0.0-bash
SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
WORKDIR=''
cleanup() {
    local pid pids
    pids=$(jobs -pr)
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    if [[ -n $WORKDIR && -d $WORKDIR && -O $WORKDIR ]]; then rm -rf -- "$WORKDIR"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 0' TERM

usage() {
    cat <<'HELP'
Usage:
  ./pve-advisor.sh analyze --input cluster.json [options]
  ./pve-advisor.sh watch --input cluster.json --interval 60 [options]
  ./pve-advisor.sh test [--case NAME]
  ./pve-advisor.sh --list-tests

Options:
  --input FILE                 Snapshot JSON (maximum 10 MiB, UTF-8)
  --format table|json          Default: table. watch JSON = one report per line
  --pretty                     Indented JSON (analyze only)
  --cpu-limit 0.80             Overload at or above the limit
  --memory-limit 0.80          Overload at or above the limit
  --vcpu-limit 4               Running vCPU / physical CPU cores
  --reserve-cpu 2              Host CPU reserve, equivalent cores per node
  --reserve-memory-gib 4       Host RAM reserve per node
  --migration-cpu 1            Extra CPU reserve on each receiving node
  --migration-memory-gib 1     Extra RAM reserve while receiving
  --max-age 300                Snapshot age in seconds; 0 = historical analysis
  --exclude-vm VMID            Repeatable; load still counted
  --exclude-node NODE          Repeatable; disallow source and target
  --max-moves 20               Maximum proposed moves, 1..100
  --beam-width 8               Bounded search width, 1..32
  --search-budget 5000         Candidate checks, 1..100000
  --timeout 30                 Per-phase jq time limit, seconds 1..120
  --interval 60               Watch refresh, seconds 1..86400
  --cycles N                   Watch iterations, 0 = until interrupted
  --output FILE                Atomically replace a JSON report file
  --output-mode 600|640        Output file permissions; default 600
  --case NAME                  Run one built-in test from --list-tests
  --help | --version

Exit: 0 = complete/no_action, 2 = invalid input/options, 3 = no_safe_plan,
      130 = Ctrl+C. watch --cycles returns the last report's exit status.
This tool proposes resource moves only. It does not execute Proxmox commands.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
COMMAND=analyze
if (($#)) && [[ $1 != -* ]]; then COMMAND=$1; shift; fi
INPUT='' FORMAT=table PRETTY=0 INTERVAL=60 CYCLES=0 OUTPUT='' OUTPUT_MODE=600 CASE=''
CPU=0.80 MEM=0.80 VCPU=4 RCPU=2 RMEM=4 MCPU=1 MMEM=1 AGE=300 MOVES=20 WIDTH=8 BUDGET=5000 TIMEOUT=30
EXCLUDED_VMS='[]' EXCLUDED_NODES='[]'
for dependency in jq awk date head wc mktemp timeout iconv; do command -v "$dependency" >/dev/null || die "Missing dependency: $dependency (Ubuntu: sudo apt-get install jq coreutils libc-bin)"; done
while (($#)); do
    case $1 in
        --help|-h) usage; exit 0 ;;
        --version) printf '%s\n' "$VERSION"; exit 0 ;;
        --list-tests) COMMAND=list-tests; shift; continue ;;
        --pretty) PRETTY=1; shift; continue ;;
        --input|--format|--cpu-limit|--memory-limit|--vcpu-limit|--reserve-cpu|--reserve-memory-gib|--migration-cpu|--migration-memory-gib|--max-age|--max-moves|--beam-width|--search-budget|--timeout|--interval|--cycles|--output|--output-mode|--case|--exclude-vm|--exclude-node)
            (($# >= 2)) || die "Missing value for $1"
            option=$1 value=$2; shift 2
            case $option in
                --input) INPUT=$value ;; --format) FORMAT=$value ;;
                --cpu-limit) CPU=$value ;; --memory-limit) MEM=$value ;; --vcpu-limit) VCPU=$value ;;
                --reserve-cpu) RCPU=$value ;; --reserve-memory-gib) RMEM=$value ;;
                --migration-cpu) MCPU=$value ;; --migration-memory-gib) MMEM=$value ;;
                --max-age) AGE=$value ;; --max-moves) MOVES=$value ;; --beam-width) WIDTH=$value ;;
                --search-budget) BUDGET=$value ;; --timeout) TIMEOUT=$value ;; --interval) INTERVAL=$value ;;
                --cycles) CYCLES=$value ;; --output) OUTPUT=$value ;; --output-mode) OUTPUT_MODE=$value ;;
                --case) CASE=$value ;;
                --exclude-vm)
                    [[ $value =~ ^[1-9][0-9]{0,14}$ ]] || die 'Invalid excluded VMID'
                    EXCLUDED_VMS=$(jq -cn --argjson old "$EXCLUDED_VMS" --arg id "$value" '$old+[$id|tonumber]') ;;
                --exclude-node)
                    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || die 'Invalid excluded node'
                    EXCLUDED_NODES=$(jq -cn --argjson old "$EXCLUDED_NODES" --arg node "$value" '$old+[$node]') ;;
            esac ;;
        *) die "Unknown option: $1" ;;
    esac
done
[[ $COMMAND == analyze || $COMMAND == watch || $COMMAND == test || $COMMAND == list-tests ]] || die "Unknown command: $COMMAND"
[[ $FORMAT == table || $FORMAT == json ]] || die 'format must be table or json'
[[ $OUTPUT_MODE == 600 || $OUTPUT_MODE == 640 ]] || die 'output-mode must be 600 or 640'
[[ $COMMAND != watch || $PRETTY == 0 ]] || die 'watch JSON uses JSONL; omit --pretty'
POLICY=$(jq -cn --args '$ARGS.positional | map(if test("^[+]?[0-9]*[.]?[0-9]+$") then sub("^\\+";"") | (if startswith(".") then "0"+. else . end) | tonumber else error("invalid numeric option") end) as $n
  | if ($n|length)!=14 or any($n[]; (isfinite|not)) then error("invalid numeric option") else
    {cpu_limit:$n[0],memory_limit:$n[1],vcpu_limit:$n[2],reserve_cpu:$n[3],reserve_memory:($n[4]*1073741824|floor),
     migration_cpu:$n[5],migration_memory:($n[6]*1073741824|floor),max_age_seconds:$n[7],max_moves:$n[8],beam_width:$n[9],search_budget:$n[10],timeout:$n[11],interval:$n[12],cycles:$n[13]}
    | if .cpu_limit<=0 or .cpu_limit>1 or .memory_limit<=0 or .memory_limit>1 or .vcpu_limit<=0 or .vcpu_limit>1000000
      or .reserve_cpu>1000000 or .reserve_memory>1073741824000000 or .migration_cpu>1000000 or .migration_memory>1073741824000000
      or .max_age_seconds>315360000 or .max_moves<1 or .max_moves>100 or .beam_width<1 or .beam_width>32
      or .search_budget<1 or .search_budget>100000 or .timeout<1 or .timeout>120 or .interval<1 or .interval>86400 or .cycles>1000000
      or any([.max_moves,.beam_width,.search_budget,.timeout,.interval,.cycles][]; floor!=.)
      then error("numeric option outside allowed range") else . end end' -- "$CPU" "$MEM" "$VCPU" "$RCPU" "$RMEM" "$MCPU" "$MMEM" "$AGE" "$MOVES" "$WIDTH" "$BUDGET" "$TIMEOUT" "$INTERVAL" "$CYCLES" 2>/dev/null) || die 'Invalid numeric option; see --help'
POLICY=$(jq -cn --argjson p "$POLICY" --argjson v "$EXCLUDED_VMS" --argjson n "$EXCLUDED_NODES" '$p+{excluded_vms:$v,excluded_nodes:$n}')
TIMEOUT=$(jq -r '.timeout' <<<"$POLICY")
INTERVAL=$(jq -r '.interval' <<<"$POLICY")
CYCLES=$(jq -r '.cycles' <<<"$POLICY")
WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/pve-advisor.XXXXXXXX") || die 'Cannot create private temporary directory'

# Streaming decoded JSON paths detect duplicate keys, including escaped spellings.
read -r -d '' STREAM_GUARD <<'JQ' || true
reduce inputs as $e ({open:[[]],seen:{"[]":{}}};
  $e[0] as $p |
  if ($p|length)>32 or (($e|length)==2 and ($e[1]|type|IN("array","object")) and ($p|length)>=32) then error("JSON nesting exceeds 32")
  elif ($e|length)==1 then
    (($p|length)-1) as $level |
    .open=.open[:$level] | .seen |= with_entries(select((.key|fromjson|length)<$level))
  else
    if (.open|length)==0 then .open=[[]] | .seen={"[]":{}} else . end |
    reduce range(1;($p|length)+1) as $i (.;
      $p[:$i] as $edge | ($p[:($i-1)]|tojson) as $parent | ($p[$i-1]|tostring) as $key |
      if $i<($p|length) and .open[$i]==$edge then .
      elif .seen[$parent][$key]==true then error("Duplicate JSON object key")
      else .seen[$parent][$key]=true |
        if $i<($p|length) then .open[$i]=$edge | .seen[($edge|tojson)]={} else . end
      end)
  end) | true
JQ

read -r -d '' ENGINE <<'JQ' || true
def safe: tostring|gsub("[^ -~]";"?")|.[0:160];
def ident: if type=="string" then test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$") else false end;
def integer($lo;$hi): if type=="number" then isfinite and floor==. and . >= $lo and . <= $hi else false end;
def fraction: if type=="number" then isfinite and .>=0 and .<=1 else false end;
def issue($code;$record;$message): {code:$code,record:$record,message:$message,blocking:true};
def ratios($n;$l;$transient):
  {cpu:(($l.cpu+$P.reserve_cpu+(if $transient then $P.migration_cpu else 0 end))/$n.cpu_cores),
   memory:(($l.memory_budget+$P.reserve_memory+(if $transient then $P.migration_memory else 0 end))/$n.mem_total),
   vcpu_overcommit:($l.vcpus/$n.cpu_cores)};
def reasons($n;$l): ratios($n;$l;false) as $r |
  [if $r.cpu >= $P.cpu_limit then "cpu" else empty end,
   if $r.memory >= $P.memory_limit then "memory" else empty end,
   if $r.vcpu_overcommit >= $P.vcpu_limit then "vcpu_overcommit" else empty end];
def over($N;$S): [$N[]|select(.status=="online")|. as $n|select((reasons($n;$S.loads[$n.node])|length)>0)|.node];
def excess($N;$S): [$N[]|select(.status=="online")|. as $n|ratios($n;$S.loads[$n.node];false) as $r |
  [($r.cpu/$P.cpu_limit),($r.memory/$P.memory_limit),($r.vcpu_overcommit/$P.vcpu_limit)][] |
  if .>=1 then .-1+1e-9 else 0 end] | add // 0;
def transition($N;$S;$v;$t):
  if $v.node==$t.node or $t.status!="online" or ($v.movable|not)
     or ($P.excluded_vms|index($v.vmid))!=null or ($P.excluded_nodes|index($v.node))!=null
     or ($P.excluded_nodes|index($t.node))!=null or ($S.moves|map(.vmid)|index($v.vmid))!=null
     or ($v.allowed_nodes!=null and ($v.allowed_nodes|index($t.node))==null) then null
  else $S.loads[$v.node] as $src | $S.loads[$t.node] as $dst |
    ($v.vcpus*$v.cpu_usage) as $cpu |
    {cpu:($dst.cpu+$cpu),memory:($dst.memory+$v.mem_used),memory_budget:($dst.memory_budget+$v.mem_max),
     vcpus:($dst.vcpus+$v.vcpus),running:($dst.running+1)} as $received |
    ratios($t;$received;true) as $r |
    if $r.cpu >= $P.cpu_limit or $r.memory >= $P.memory_limit or $r.vcpu_overcommit >= $P.vcpu_limit or $received.memory_budget>9007199254740991 then null
    else $S |
      .loads[$v.node]={cpu:([0,($src.cpu-$cpu)]|max),memory:($src.memory-$v.mem_used),memory_budget:($src.memory_budget-$v.mem_used),vcpus:($src.vcpus-$v.vcpus),running:($src.running-1)} |
      .loads[$t.node]=$received |
      .moves += [{step:((.moves|length)+1),vmid:$v.vmid,name:$v.name,source:$v.node,target:$t.node,
                  cpu_cores:$cpu,mem_used_bytes:$v.mem_used,mem_reserved_bytes:$v.mem_max,vcpus:$v.vcpus,target_transient_ratios:$r}]
    end end;
def score($N;$S): [excess($N;$S),([$S.moves[].mem_reserved_bytes]|add//0),
  ([$N[]|select(.status=="online")|. as $n|ratios($n;$S.loads[$n.node];false)|[.cpu,.memory,.vcpu_overcommit]|map(.*.)|add]|add//0),
  ($S.moves|map([.vmid,.target]))];
def search($N;$V;$initial):
  reduce range(0;$P.max_moves) as $depth
    ({beam:[$initial],next:[],checks:0,limited:false,solution:null};
     if .solution!=null or .checks >= $P.search_budget or (.beam|length)==0 then .
     else .next=[] |
       reduce .beam[] as $state (.;
         over($N;$state) as $sources |
         reduce ($V[]|select(.status=="running" and .movable)|select(.node as $s|$sources|index($s))|
                 select(.vmid as $id|($state.moves|map(.vmid)|index($id))==null)) as $v (.;
           reduce ($N[]|select(.node!=$v.node)) as $target (.;
             if .checks >= $P.search_budget then .limited=true else
               .checks+=1 | transition($N;$state;$v;$target) as $candidate |
               if $candidate==null then .
               elif (over($N;$candidate)|length)==0 then
                 if .solution==null or score($N;$candidate)<score($N;.solution) then .solution=$candidate else . end
               elif excess($N;$candidate)<excess($N;$state) then
                 .next += [$candidate] |
                 .next |= (unique_by(.moves|map([.vmid,.target])|sort)|sort_by(score($N;.))) |
                 if (.next|length)>$P.beam_width then .limited=true | .next=.next[:$P.beam_width] else . end
               else . end
             end))) |
       .beam=.next
     end) | .limited=(.limited or .checks >= $P.search_budget or (.solution==null and (.beam|length)>0));
def rows($N;$V;$loads;$valid):
  [$N[] as $n | $loads[$n.node] as $l | reasons($n;$l) as $why |
   ([$V[]|select(.node==$n.node and .status!="running")|.vcpus]|add//0) as $inactive |
   {node:$n.node,status:$n.status,metrics_complete:$valid,cpu_cores:$n.cpu_cores,cpu_used_cores:$l.cpu,
    cpu_used_ratio:($l.cpu/$n.cpu_cores),mem_total_bytes:$n.mem_total,mem_used_bytes:$l.memory,
    mem_used_ratio:($l.memory/$n.mem_total),planning_memory_bytes:$l.memory_budget,running_vcpus:$l.vcpus,
    vcpu_overcommit_ratio:($l.vcpus/$n.cpu_cores),configured_vcpus_all:($l.vcpus+$inactive),
    configured_overcommit_ratio_all:(($l.vcpus+$inactive)/$n.cpu_cores),running_vms:$l.running,
    effective_cpu_ratio:(ratios($n;$l;false)).cpu,effective_memory_ratio:(ratios($n;$l;false)).memory,
    state:(if $n.status=="offline" then "OFFLINE" elif $n.status!="online" then "UNKNOWN"
           elif ($why|length)>0 then "OVERLOADED" elif $valid then "OK" else "UNKNOWN" end),
    overload_reasons:(if $n.status=="online" then $why else [] end)}];
def report:
  . as $raw |
  (if type=="object" then . else {} end) as $root |
  (if ($root.nodes|type)=="array" and ($root.nodes|length)<=256 then $root.nodes else [] end) as $nodes |
  (if ($root.vms|type)=="array" and ($root.vms|length)<=20000 then $root.vms else [] end) as $vms |
  [ $nodes[]|select(type=="object")|select(.node|ident)|select((.cpu_cores|integer(1;1000000)) and (.mem_total|integer(1;9007199254740991))) ] |
  unique_by(.node)|sort_by(.node) as $N |
  ($vms|map(select(type=="object"))|map(select(.vmid|integer(1;9007199254740991)))|group_by(.vmid)|map({key:(.[0].vmid|tostring),value:length})|from_entries) as $ids |
  ([
    if ($raw|type)!="object" then issue("invalid_root";"$";"Expected one JSON object") else empty end,
    if ($root.cluster|ident|not) then issue("invalid_cluster";"cluster";"Missing or invalid cluster name") else empty end,
    if $collected==null then issue("invalid_timestamp";"collected_at";"Expected RFC3339 timestamp with timezone")
    elif $collected>$now+60 then issue("future_snapshot";"collected_at";"Snapshot is more than 60 seconds in the future")
    elif $P.max_age_seconds>0 and $now-$collected>$P.max_age_seconds then issue("stale_snapshot";"collected_at";"Snapshot is too old") else empty end,
    if ($root.nodes|type)!="array" or ($root.nodes|length)>256 then issue("invalid_collection";"nodes";"Expected array, maximum 256 nodes") else empty end,
    if ($root.vms|type)!="array" or ($root.vms|length)>20000 then issue("invalid_collection";"vms";"Expected array, maximum 20000 VMs") else empty end,
    if ($N|length)==0 then issue("no_nodes";"nodes";"No usable node capacity") else empty end,
    ($nodes|to_entries[]|.key as $i|.value as $n|("nodes[\($i)] node=\($n.node? // "?"|safe)") as $at |
      if ($n|type)!="object" then issue("invalid_node";$at;"Expected object") else
        if ($n.node|ident|not) then issue("invalid_node";$at;"Invalid node name") else empty end,
        if (($n.cpu_cores|integer(1;1000000)) and ($n.mem_total|integer(1;9007199254740991))|not) then issue("invalid_capacity";$at;"CPU cores and RAM bytes must be positive safe integers") else empty end,
        if ($n.mem_total|integer(1;1073741823)) then issue("suspicious_capacity";$at;"RAM below 1 GiB; verify byte units, no automatic conversion") else empty end,
        if ($n.status|IN("online","offline")|not) then issue("invalid_status";$at;"Node status must be online/offline") else empty end,
        if ($nodes|map(select(type=="object" and .node==$n.node))|length)>1 then issue("duplicate_node";$at;"Duplicate node identifier") else empty end
      end),
    ($vms|to_entries[]|.key as $i|.value as $v|("vms[\($i)] vmid=\($v.vmid? // "?"|safe) node=\($v.node? // "?"|safe)") as $at |
      if ($v|type)!="object" then issue("invalid_vm";$at;"Expected object") else
        if ($v.vmid|integer(1;9007199254740991)|not) or ($v.node|type)!="string" or ($N|map(.node)|index($v.node))==null then issue("invalid_vm_reference";$at;"Invalid VMID or unknown node") else empty end,
        if ($ids[($v.vmid|tostring)]//0)>1 then issue("duplicate_vmid";$at;"Ambiguous VMID; provisional accounting on listed nodes") else empty end,
        if ($v.status|IN("running","stopped")|not) then issue("invalid_status";$at;"Only stable running/stopped statuses are supported") else empty end,
        if $v.status=="running" and ($N|map(select(.node==$v.node and .status!="online"))|length)>0 then issue("running_on_offline";$at;"Running VM on a node that is not online") else empty end,
        if ($v.vcpus|integer(1;1000000)|not) then issue("invalid_vcpus";$at;"vcpus must be a positive integer <=1000000") else empty end,
        if ($v.cpu_usage|fraction|not) then issue("invalid_cpu";$at;"cpu_usage must be numeric in [0,1]; percentages are not inferred") else empty end,
        if ($v.mem_max|integer(1;9007199254740991)|not) then issue("invalid_mem_max";$at;"mem_max must be positive safe integer bytes") else empty end,
        if ($v.mem_used|integer(0;9007199254740991)|not) or (($v.mem_max|type)=="number" and $v.mem_used>$v.mem_max) then issue("invalid_mem_used";$at;"mem_used must be nonnegative safe integer bytes <= mem_max") else empty end,
        if (($v|has("locked")) and ($v.locked|type)!="boolean") or (($v|has("migration_allowed")) and ($v.migration_allowed|type)!="boolean") then issue("invalid_migration_metadata";$at;"locked/migration_allowed must be boolean") else empty end,
        if ($v|has("allowed_nodes")) then
          if ($v.allowed_nodes|type)!="array" then issue("invalid_migration_metadata";$at;"allowed_nodes must be array of known nodes")
          elif any($v.allowed_nodes[]; . as $n|($N|map(.node)|index($n))==null) then issue("invalid_migration_metadata";$at;"allowed_nodes contains unknown node") else empty end
        else empty end
      end)
  ]) as $warnings |
  [$vms[]|select(type=="object")|select((.node|type)=="string")|select(.node as $n|$N|map(.node)|index($n))|
    {vmid:(if (.vmid|integer(1;9007199254740991)) then .vmid else 0 end),name:(.name//.vmid|safe),node:.node,status:.status,
     vcpus:(if (.vcpus|integer(1;1000000)) then .vcpus else 0 end),cpu_usage:(if (.cpu_usage|fraction) then .cpu_usage else 0 end),
     mem_used:(if (.mem_used|integer(0;9007199254740991)) then .mem_used else 0 end),
     mem_max:(if (.mem_max|integer(1;9007199254740991)) then .mem_max else 0 end),
     movable:(.migration_allowed!=false and .locked!=true),allowed_nodes:(.allowed_nodes//null)}] | sort_by(.vmid) as $V |
  (reduce $N[] as $n ({}; .[$n.node]={cpu:0,memory:0,memory_budget:0,vcpus:0,running:0}) |
    reduce ($V[]|select(.status=="running")) as $v (.; .[$v.node].cpu+=($v.vcpus*$v.cpu_usage) |
       .[$v.node].memory+=$v.mem_used | .[$v.node].memory_budget+=$v.mem_used | .[$v.node].vcpus+=$v.vcpus | .[$v.node].running+=1)) as $loads |
  ($warnings + [ $N[] as $n|select($loads[$n.node].memory>9007199254740991)|issue("numeric_limit";$n.node;"RAM sum exceeds exact integer limit") ]) as $W |
  (($W|length)==0) as $valid |
  {loads:$loads,moves:[]} as $initial |
  (if $valid and (over($N;$initial)|length)>0 then search($N;$V;$initial) else {solution:null,checks:0,limited:false} end) as $found |
  (if $found.solution!=null then
    reduce $found.solution.moves[] as $move ({state:$initial,ok:true};
      ($V|map(select(.vmid==$move.vmid))[0]) as $v | ($N|map(select(.node==$move.target))[0]) as $target |
      if .ok and $v!=null and $target!=null and $move.source==$v.node then transition($N;.state;$v;$target) as $next |
         if $next!=null and $next.moves[-1]==$move then .state=$next else .ok=false end else .ok=false end) |
    if .ok and (over($N;.state)|length)==0 then .state else null end
   else null end) as $verified |
  (if $valid|not then "blocked" elif (over($N;$initial)|length)==0 then "no_action"
   elif $verified!=null then "complete" else "no_safe_plan" end) as $status |
  {schema_version:1,engine:"bash+jq",cluster:($root.cluster//"unknown"|safe),collected_at:(if $collected!=null then $root.collected_at else null end),
   analyzed_at:($now|todateiso8601),valid_until_epoch:([$now+([10,($P.interval*2)]|max),
       (if $P.max_age_seconds>0 and $collected!=null then $collected+$P.max_age_seconds else $now+([10,($P.interval*2)]|max) end)]|min),
   data_valid:$valid,policy:$P,nodes:rows($N;$V;$loads;$valid),warnings:$W,
   plan:{status:$status,resource_safe:($status|IN("complete","no_action")),execution_ready:false,
         migrations:(if $verified!=null then $verified.moves else [] end),
         after:rows($N;$V;(if $verified!=null then $verified.loads else $loads end);$valid),
         unresolved_nodes:(if $verified!=null then [] else over($N;$initial) end),candidate_checks:$found.checks,search_limited:$found.limited,
         reason:(if $status=="blocked" then "Correct blocking input warnings before planning."
                 elif $status=="complete" then "Sequential replay passed all online node resource thresholds."
                 elif $status=="no_action" then "All online nodes are below thresholds."
                 else "No complete safe plan found within bounded search; no partial moves published." end),
         preflight:["Refresh and revalidate before each sequential migration.","Verify PVE CPU/architecture, versions, storage, bridges, network, HA/affinity, locks and passthrough.",
                    "VM usage omits host/Ceph processes; tune host reserves. CPU demand is assumed constant; existing VMs can grow RAM.",
                    "Resource recommendation only; live migration eligibility is not established by this snapshot."]}}
; report
JQ

input_error() {
    local message=$1
    jq -cn --arg message "$message" --argjson p "$POLICY" --argjson now "$(date +%s)" '
      {schema_version:1,engine:"bash+jq",cluster:"unknown",collected_at:null,analyzed_at:($now|todateiso8601),valid_until_epoch:$now,
       data_valid:false,policy:$p,nodes:[],warnings:[{code:"input_error",record:"$",message:($message|gsub("[^ -~]";"?")|.[0:300]),blocking:true}],
       plan:{status:"blocked",resource_safe:false,execution_ready:false,migrations:[],after:[],unresolved_nodes:[],reason:"Input cannot be safely analyzed."}}' >"$WORKDIR/report.json"
}

analyze_cycle() {
    local now collected=null stamp error
    now=$(date +%s)
    if [[ ! -f $INPUT || ! -r $INPUT ]]; then input_error 'Input must be a readable regular file'
    elif ! timeout -k 2 "$TIMEOUT" head -c 10485761 -- "$INPUT" >"$WORKDIR/raw" 2>"$WORKDIR/error"; then input_error 'Cannot read snapshot within time limit'
    elif (( $(wc -c <"$WORKDIR/raw") > 10485760 )); then input_error 'Snapshot exceeds 10 MiB limit'
    elif ! iconv -f UTF-8 -t UTF-8 "$WORKDIR/raw" >/dev/null 2>"$WORKDIR/error"; then input_error 'Snapshot is not valid UTF-8'
    elif ! LC_ALL=C awk '
      function reject(message) { print message > "/dev/stderr"; bad=1; exit 1; }
      function flush_token() {
        if (token!="" && token!="true" && token!="false" && token!="null" &&
            token !~ /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) reject("Invalid JSON literal");
        token="";
      }
      { for(i=1;i<=length($0);i++) { c=substr($0,i,1);
          if(quoted) { if(escaped) escaped=0; else if(c=="\\") escaped=1; else if(c=="\"") quoted=0; }
          else if(c=="\"") { flush_token(); quoted=1; }
          else if(c=="{" || c=="[") { flush_token(); depth++; if(depth>32) reject("JSON nesting exceeds 32"); }
          else if(c=="}" || c=="]") { flush_token(); depth--; if(depth<0) reject("Unexpected closing JSON delimiter"); }
          else if(c ~ /[[:space:]:,]/) flush_token();
          else { token=token c; if(length(token)>128) reject("JSON numeric/literal token exceeds 128 characters"); }
        } if(!quoted) flush_token(); }
      END { if(!bad) flush_token(); exit bad?1:0; }' "$WORKDIR/raw" 2>"$WORKDIR/error"; then
        error=$(head -c 250 "$WORKDIR/error"); input_error "Lexical validation failed: $error"
    elif ! timeout -k 2 "$TIMEOUT" jq -n --stream "$STREAM_GUARD" "$WORKDIR/raw" >/dev/null 2>"$WORKDIR/error"; then
        error=$(head -c 250 "$WORKDIR/error"); input_error "JSON validation failed (or timed out): $error"
    elif ! timeout -k 2 "$TIMEOUT" jq -c -s 'if length==1 then .[0] else error("Expected exactly one JSON document") end' "$WORKDIR/raw" >"$WORKDIR/snapshot.json" 2>"$WORKDIR/error"; then
        error=$(head -c 250 "$WORKDIR/error"); input_error "JSON parse failed: $error"
    else
        stamp=$(jq -er 'if type=="object" and (.collected_at|type)=="string" then .collected_at | select(length<=64 and (explode|all(.[]; .>=32 and .<127))) else empty end' "$WORKDIR/snapshot.json" 2>/dev/null) || stamp=''
        if [[ $stamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ && ${#stamp} -le 64 ]]; then
            collected=$(date --date="$stamp" +%s 2>/dev/null) || collected=null
        fi
        if ! timeout -k 2 "$TIMEOUT" jq -c --argjson P "$POLICY" --argjson now "$now" --argjson collected "$collected" "$ENGINE" "$WORKDIR/snapshot.json" >"$WORKDIR/report.json" 2>"$WORKDIR/error"; then
            error=$(head -c 250 "$WORKDIR/error"); input_error "Analysis failed safely (or timed out): $error"
        fi
    fi
    # The snapshot can expire while the bounded planner is running.
    now=$(date +%s)
    jq -c --argjson now "$now" 'if .data_valid and .policy.max_age_seconds>0 and .valid_until_epoch<$now then
       .data_valid=false | .plan.status="blocked" | .plan.resource_safe=false | .plan.migrations=[] | .plan.after=.nodes |
       .warnings += [{code:"stale_snapshot",record:"collected_at",message:"Snapshot/report expired during analysis",blocking:true}]
       else . end' "$WORKDIR/report.json" >"$WORKDIR/final.json" || return 2
    mv -- "$WORKDIR/final.json" "$WORKDIR/report.json"
    jq -r '.warnings[]|"WARNING [\(.code)] \(.record): \(.message)"' "$WORKDIR/report.json" >&2
    if [[ -n $OUTPUT ]]; then
        local tempout
        tempout=$(mktemp "$(dirname -- "$OUTPUT")/.pve-report.XXXXXXXX") || return 2
        if ! cat -- "$WORKDIR/report.json" >"$tempout" || ! chmod "$OUTPUT_MODE" "$tempout" || ! mv -fT -- "$tempout" "$OUTPUT"; then
            rm -f -- "$tempout"; printf 'ERROR: Cannot atomically write output\n' >&2; return 2
        fi
    fi
    if [[ $FORMAT == json ]]; then
        if ((PRETTY)); then jq -Ma . "$WORKDIR/report.json"; else jq -Mac . "$WORKDIR/report.json"; fi
    else render_table; fi
    jq -r 'if .data_valid|not then 2 elif .plan.resource_safe then 0 else 3 end' "$WORKDIR/report.json" >"$WORKDIR/status"
    return "$(<"$WORKDIR/status")"
}

render_nodes() {
    local selector=$1 node cpu memory oc state quality why
    printf '%-16s %14s %20s %12s %-12s %-8s %s\n' NODE 'CPU cores/%' 'RAM GiB/%' 'vCPU/core' STATE DATA REASONS
    while IFS=$'\t' read -r node cpu memory oc state quality why; do
        printf '%-16s %14s %20s %12s %-12s %-8s %s\n' "$node" "$cpu" "$memory" "$oc" "$state" "$quality" "$why"
    done < <(jq -r "$selector"'[] | [.node, (((.cpu_used_cores*100|round)/100|tostring)+"/"+((.cpu_used_ratio*1000|round)/10|tostring)+"%"),
      (((.mem_used_bytes/1073741824*100|round)/100|tostring)+"/"+((.mem_used_ratio*1000|round)/10|tostring)+"%"),
      (((.vcpu_overcommit_ratio*100|round)/100|tostring)+"x"),.state,(if .metrics_complete then "complete" else "PARTIAL" end),
      (if (.overload_reasons|length)>0 then .overload_reasons|join(",") else "-" end)]|@tsv' "$WORKDIR/report.json")
}
render_table() {
    jq -r '"Cluster: \(.cluster) | collected: \(.collected_at)","CPU/RAM = running VM sums. PARTIAL values are provisional.",
      "Limits: CPU \(.policy.cpu_limit*100)%, RAM \(.policy.memory_limit*100)%, vCPU \(.policy.vcpu_limit)x; host reserve \(.policy.reserve_cpu) cores + \(.policy.reserve_memory/1073741824) GiB."' "$WORKDIR/report.json"
    render_nodes '.nodes'
    jq -r '"Plan: \(.plan.status) | \(.plan.reason)"' "$WORKDIR/report.json"
    if jq -e '.plan.migrations|length>0' "$WORKDIR/report.json" >/dev/null; then
        printf '\n%-5s %-10s %-24s %-16s %-16s %s\n' STEP VMID VM FROM TO 'RAM reserve GiB'
        while IFS=$'\t' read -r step vmid name src dst ram; do
            printf '%-5s %-10s %-24s %-16s %-16s %s\n' "$step" "$vmid" "$name" "$src" "$dst" "$ram"
        done < <(jq -r '.plan.migrations[]|[.step,.vmid,.name,.source,.target,(.mem_reserved_bytes/1073741824)]|@tsv' "$WORKDIR/report.json")
        printf '\nProjected after (incoming RAM reserved at mem_max):\n'
        render_nodes '.plan.after'
        printf 'Refresh snapshot and complete PVE preflight before each sequential migration.\n'
    fi
}

# __SELF_TESTS__
run_test_report() {
    "$SELF" analyze --input "$TEST_DIR/input.json" --max-age 0 --format json "$@" >"$TEST_DIR/report.json" 2>"$TEST_DIR/error.log"
    TEST_RC=$?
}
assert_test_report() { [[ $TEST_RC == "$1" ]] && jq -e "$2" "$TEST_DIR/report.json" >/dev/null; }
mutate_test() { jq "$1" "$TEST_DIR/base.json" >"$TEST_DIR/input.json"; }
test_accounting() {
    mutate_test '.'; run_test_report
    assert_test_report 0 '.nodes[0] | .cpu_used_cores==7 and .mem_used_bytes==23622320128 and .running_vcpus==8 and .configured_vcpus_all==24 and .vcpu_overcommit_ratio==1'
}
test_overload_thresholds() {
    local change reason
    for reason in cpu memory vcpu_overcommit; do
        case $reason in
            cpu) change='.nodes[0].cpu_cores=10 | .vms=[.vms[0]] | .vms[0].vcpus=8 | .vms[0].cpu_usage=1' ;;
            memory) change='.nodes[0].mem_total=10737418240 | .vms=[.vms[0]] | .vms[0].mem_used=8589934592' ;;
            vcpu_overcommit) change='.nodes[0].cpu_cores=10 | .vms=[.vms[0]] | .vms[0].vcpus=40 | .vms[0].cpu_usage=0' ;;
        esac
        mutate_test "$change"
        run_test_report --reserve-cpu 0 --reserve-memory-gib 0 --migration-cpu 0 --migration-memory-gib 0
        jq -e --arg r "$reason" '.nodes[0].state=="OVERLOADED" and (.nodes[0].overload_reasons|index($r))!=null' "$TEST_DIR/report.json" >/dev/null || return 1
    done
}
test_invalid_json() {
    printf '{"nodes": [' >"$TEST_DIR/input.json"; run_test_report
    assert_test_report 2 '.data_valid==false and .plan.status=="blocked" and (.plan.migrations|length)==0 and .warnings[0].code=="input_error"' && grep -q 'WARNING' "$TEST_DIR/error.log"
}
test_missing_field() {
    mutate_test 'del(.vms[0].vcpus)'; run_test_report
    assert_test_report 2 'any(.warnings[]; .code=="invalid_vcpus" and (.record|contains("vms[0] vmid=101"))) and .plan.migrations==[]'
}
test_invalid_metrics() {
    mutate_test '.vms[0].cpu_usage=31 | .vms[1].mem_used=null'; run_test_report
    assert_test_report 2 'any(.warnings[];.code=="invalid_cpu") and any(.warnings[];.code=="invalid_mem_used") and .data_valid==false'
}
test_duplicate_vmid() {
    mutate_test '.vms += [.vms[0]+{node:"b"}]'; run_test_report
    assert_test_report 2 'any(.warnings[];.code=="duplicate_vmid") and .plan.migrations==[]'
}
test_unknown_node() {
    mutate_test '.vms[0].node="missing"'; run_test_report
    assert_test_report 2 'any(.warnings[];.code=="invalid_vm_reference") and .plan.status=="blocked"'
}
test_duplicate_keys() {
    printf '%s\n' '{"a":{"x":1},"\u0061":{"y":2}}' >"$TEST_DIR/input.json"; run_test_report
    assert_test_report 2 '.warnings[0].code=="input_error" and (.warnings[0].message|contains("Duplicate JSON object key"))'
}
test_stale_snapshot() {
    mutate_test '.collected_at=(now-600|todateiso8601)'; run_test_report --max-age 300
    assert_test_report 2 'any(.warnings[];.code=="stale_snapshot") and .plan.migrations==[]'
}
test_complete_plan() {
    mutate_test '.'; run_test_report
    assert_test_report 0 '.plan.status=="complete" and .plan.resource_safe and .plan.migrations[0].vmid==102 and .plan.migrations[0].source=="a" and .plan.migrations[0].target=="c" and all(.plan.after[];.state=="OK") and all(.plan.migrations[]; .target_transient_ratios.cpu<0.8 and .target_transient_ratios.memory<0.8 and .target_transient_ratios.vcpu_overcommit<4) and ([.plan.after[]|select(.node=="c")|.planning_memory_bytes-.mem_used_bytes][0])==2147483648'
}
test_constraints() {
    mutate_test '.nodes[1].status="offline" | .vms|=map(select(.node!="b")) | .vms[1].locked=true'; run_test_report
    assert_test_report 0 '.plan.status=="complete" and all(.plan.migrations[];.target=="c" and .vmid==101)' || return 1
    run_test_report --exclude-vm 101
    assert_test_report 3 '.plan.status=="no_safe_plan" and .plan.migrations==[]'
}
make_capacity_test() {
    jq --argjson gb "$1" '
      def n($name;$cores;$mem): {node:$name,status:"online",cpu_cores:$cores,mem_total:($mem*1073741824)};
      def v($id;$node): {vmid:$id,name:("vm-"+($id|tostring)),node:$node,status:"running",vcpus:4,cpu_usage:1,mem_used:1073741824,mem_max:17179869184};
      .nodes=[n("a";8;64),n("b";8;64),n("c";32;$gb)] | .vms=[v(1;"a"),v(2;"a"),v(3;"b"),v(4;"b")]' "$TEST_DIR/base.json" >"$TEST_DIR/input.json"
}
test_no_safe_plan() {
    make_capacity_test 32; run_test_report
    assert_test_report 3 '.data_valid and .plan.status=="no_safe_plan" and .plan.resource_safe==false and .plan.migrations==[]'
}
test_multiple_sources() {
    make_capacity_test 128; run_test_report
    assert_test_report 0 '.plan.status=="complete" and (.plan.migrations|length)==2 and ([.plan.migrations[].source]|sort)==["a","b"] and all(.plan.after[];.state=="OK")'
}
test_healthy() {
    mutate_test '.vms=[.vms[2]]'; run_test_report
    assert_test_report 0 '.plan.status=="no_action" and .plan.resource_safe and .plan.migrations==[]'
}
test_formats() {
    mutate_test '.'
    "$SELF" analyze --input "$TEST_DIR/input.json" --max-age 0 >"$TEST_DIR/table.txt" 2>"$TEST_DIR/error.log" || return 1
    grep -q 'Plan: complete' "$TEST_DIR/table.txt" && grep -q 'VMID' "$TEST_DIR/table.txt" || return 1
    "$SELF" analyze --input "$TEST_DIR/input.json" --max-age 0 --format json --pretty >"$TEST_DIR/report.json" 2>"$TEST_DIR/error.log" || return 1
    jq -e '.plan.status=="complete" and .engine=="bash+jq"' "$TEST_DIR/report.json" >/dev/null
}
wait_test_rows() {
    local count=$1 pid=$2 i
    for ((i=0;i<200;i++)); do
        if (( $(wc -l <"$TEST_DIR/watch.jsonl") >= count )); then return 0; fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.05
    done
    return 1
}
test_watch_recovery() {
    cp -- "$TEST_DIR/base.json" "$TEST_DIR/input.json"
    "$SELF" watch --input "$TEST_DIR/input.json" --max-age 0 --format json --interval 1 --cycles 3 --output "$TEST_DIR/output.json" >"$TEST_DIR/watch.jsonl" 2>"$TEST_DIR/watch.log" &
    local pid=$! failed=0
    if wait_test_rows 1 "$pid"; then
        printf '{bad}' >"$TEST_DIR/next.json"; mv -fT -- "$TEST_DIR/next.json" "$TEST_DIR/input.json"
        if wait_test_rows 2 "$pid"; then cp -- "$TEST_DIR/base.json" "$TEST_DIR/next.json"; mv -fT -- "$TEST_DIR/next.json" "$TEST_DIR/input.json"; else failed=1; fi
    else failed=1; fi
    if ((failed)); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1; fi
    wait "$pid" || return 1
    jq -se 'map(.plan.status)==["complete","blocked","complete"]' "$TEST_DIR/watch.jsonl" >/dev/null &&
      jq -e '.plan.status=="complete"' "$TEST_DIR/output.json" >/dev/null && grep -q 'WARNING' "$TEST_DIR/watch.log"
}
self_tests() {
    local names=(accounting overload_thresholds invalid_json missing_field invalid_metrics duplicate_vmid unknown_node duplicate_keys stale_snapshot complete_plan constraints no_safe_plan multiple_sources healthy formats watch_recovery)
    local name passed=0 failed=0 found=0
    if [[ $COMMAND == list-tests ]]; then printf '%s\n' "${names[@]}"; return 0; fi
    TEST_DIR="$WORKDIR/tests"; mkdir -m 700 -- "$TEST_DIR"
    jq -n '
      def n($name;$cpu;$gb): {node:$name,status:"online",cpu_cores:$cpu,mem_total:($gb*1073741824)};
      def v($id;$node;$cpu;$use;$mem;$max;$status): {vmid:$id,name:("vm-"+($id|tostring)),node:$node,status:$status,vcpus:$cpu,cpu_usage:$use,mem_used:($mem*1073741824),mem_max:($max*1073741824)};
      {cluster:"self-test",collected_at:(now|todateiso8601),nodes:[n("a";8;32),n("b";16;64),n("c";16;64)],
       vms:[v(101;"a";4;0.9;12;14;"running"),v(102;"a";4;0.85;10;12;"running"),v(201;"b";4;0.25;8;12;"running"),v(301;"c";2;0.2;4;8;"running"),v(103;"a";16;0;0;16;"stopped")]}' >"$TEST_DIR/base.json"
    for name in "${names[@]}"; do
        [[ -z $CASE || $CASE == "$name" ]] || continue
        found=1
        if "test_$name"; then printf 'PASS %s\n' "$name"; ((passed+=1))
        else printf 'FAIL %s\n' "$name"; ((failed+=1)); head -c 1000 "$TEST_DIR/error.log" >&2; printf '\n' >&2; fi
    done
    ((found)) || { printf 'ERROR: Unknown test case; use --list-tests\n' >&2; return 2; }
    printf 'Tests: %s passed, %s failed\n' "$passed" "$failed"
    ((failed==0))
}
if [[ $COMMAND == test || $COMMAND == list-tests ]]; then self_tests; exit $?; fi
[[ -n $INPUT ]] || die '--input is required'
if [[ -n $OUTPUT ]]; then
    [[ -d $(dirname -- "$OUTPUT") ]] || die 'Output directory must already exist'
    [[ $(readlink -m -- "$INPUT") != "$(readlink -m -- "$OUTPUT")" && $(readlink -m -- "$SELF") != "$(readlink -m -- "$OUTPUT")" ]] || die 'Output must not overwrite input or the script'
fi
cycle=0
while :; do
    analyze_cycle; status=$?
    ((cycle+=1))
    if [[ $COMMAND == analyze ]] || (( CYCLES>0 && cycle>=CYCLES )); then exit "$status"; fi
    sleep "$INTERVAL" &
    wait $! || true
done
