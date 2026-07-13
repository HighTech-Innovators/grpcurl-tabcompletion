# Bash port of grpcurl-autocomplete.psm1 -- see README.md for setup.
# Requires bash 4+ (associative arrays) and grpcurl on PATH.

# Flag name -> does it consume the next word as its value (from `grpcurl -help`).
declare -A GRPCURL_FLAGS=(
    ['-H']=1
    ['-allow-unknown-fields']=0
    ['-alts']=0
    ['-alts-handshaker-service']=1
    ['-alts-target-service-account']=1
    ['-authority']=1
    ['-cacert']=1
    ['-cert']=1
    ['-connect-timeout']=1
    ['-d']=1
    ['-emit-defaults']=0
    ['-expand-headers']=0
    ['-format']=1
    ['-format-error']=0
    ['-help']=0
    ['-import-path']=1
    ['-insecure']=0
    ['-keepalive-time']=1
    ['-key']=1
    ['-max-msg-sz']=1
    ['-max-time']=1
    ['-msg-template']=0
    ['-plaintext']=0
    ['-proto']=1
    ['-proto-out-dir']=1
    ['-protoset']=1
    ['-protoset-out']=1
    ['-reflect-header']=1
    ['-rpc-header']=1
    ['-servername']=1
    ['-unix']=0
    ['-use-reflection']=1
    ['-user-agent']=1
    ['-v']=0
    ['-version']=0
    ['-vv']=0
)

# ponytail: 300s TTL, no eviction -- matches the PowerShell version's tradeoff.
declare -A GRPCURL_CACHE_TIME=()
declare -A GRPCURL_CACHE_ITEMS=()

# Matches a full 'rpc Name ( [stream] .Type ) returns ( [stream] .Type )' header line
# from `describe <service>` output. See grpcurl-autocomplete.psm1 for the rationale
# (scalar types never match; both ';'- and '{'-terminated headers must match).
GRPCURL_RPC_TYPE_PATTERN='^rpc[[:space:]]+[^[:space:]]+[[:space:]]*\([[:space:]]*(stream[[:space:]]+)?\.([^[:space:])]+)[[:space:]]*\)[[:space:]]*returns[[:space:]]*\([[:space:]]*(stream[[:space:]]+)?\.([^[:space:])]+)[[:space:]]*\)[[:space:]]*(;|\{)[[:space:]]*$'

# Matches a message field line referencing another message/enum type, e.g.
# '  .pkg.Type field_name = 3;' or '  repeated .pkg.Type field_name = 5;'.
# A type is often only reachable this way -- as a field of another message --
# never as any RPC's direct request/response type, so this is a second, distinct
# discovery source from GRPCURL_RPC_TYPE_PATTERN, not a variant of it.
GRPCURL_FIELD_TYPE_PATTERN='^[[:space:]]*(repeated[[:space:]]+)?\.([^[:space:])]+)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+;[[:space:]]*$'

# Resolves $VAR / ${VAR} references in a word to the shell variable's current value.
# Refuses to touch $(...) / `...` -- never eval the word, since that would execute
# arbitrary code from an unsubmitted command line on every Tab press. Prints the
# resolved word and returns 0, or returns 1 (nothing printed) if unresolvable.
_grpcurl_resolve_word() {
    local word=$1
    if [[ $word == *'$('* || $word == *'`'* ]]; then
        return 1
    fi
    local result='' rest=$word name
    while [[ $rest =~ ^([^$]*)\$\{([A-Za-z_][A-Za-z0-9_]*)\}(.*)$ ]] ||
          [[ $rest =~ ^([^$]*)\$([A-Za-z_][A-Za-z0-9_]*)(.*)$ ]]; do
        name=${BASH_REMATCH[2]}
        result+="${BASH_REMATCH[1]}${!name}"
        rest=${BASH_REMATCH[3]}
    done
    result+=$rest
    printf '%s' "$result"
    return 0
}

# Runs `grpcurl <ConnectionArgs...> list [Service]`, caching by joined argv (300s TTL).
# Prints one item per line. Bounded to ~2s (20 x 100ms polls) so a hanging/refusing
# server can't stall completion.
_grpcurl_list() {
    local -n conn_args=$1
    local service=$2
    local -a argv=("${conn_args[@]}" list)
    [[ -n $service ]] && argv+=("$service")

    local cache_key
    printf -v cache_key '%s|' "${argv[@]}"
    cache_key=${cache_key%|}

    local now=$SECONDS
    if [[ -n ${GRPCURL_CACHE_TIME[$cache_key]+x} ]] && (( now - GRPCURL_CACHE_TIME[$cache_key] < 300 )); then
        [[ -n ${GRPCURL_CACHE_ITEMS[$cache_key]} ]] && printf '%s\n' "${GRPCURL_CACHE_ITEMS[$cache_key]}"
        return
    fi

    local tmp items=''
    tmp=$(mktemp)
    grpcurl "${argv[@]}" >"$tmp" 2>/dev/null &
    local pid=$!
    local tick
    for ((tick = 0; tick < 20; tick++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    else
        wait "$pid" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            items=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$tmp" | grep -v '^$')
        fi
    fi
    rm -f "$tmp"

    GRPCURL_CACHE_TIME[$cache_key]=$SECONDS
    GRPCURL_CACHE_ITEMS[$cache_key]=$items
    [[ -n $items ]] && printf '%s\n' "$items"
}

# Runs `describe <name>` for every name in $2 not already cached, concurrently,
# sharing a single ~2s poll budget across all of them, and writes each result into
# GRPCURL_CACHE_TIME/GRPCURL_CACHE_ITEMS under its own 'describe|<name>' key.
_grpcurl_describe_batch() {
    local -n __db_conn=$1
    local -n __db_names=$2
    # `=()` initializers are required here, not stylistic -- under `set -u`, an
    # associative array declared via `local -A x` with no elements yet assigned
    # reads as unbound when its length is checked (bash's local-var "set" tracking
    # lags array creation until the first element write).
    local -A pending_pid=() pending_tmp=() pending_key=()
    local name cache_key tmp

    for name in "${__db_names[@]}"; do
        printf -v cache_key '%s|' "${__db_conn[@]}" describe "$name"
        cache_key=${cache_key%|}
        if [[ -n ${GRPCURL_CACHE_TIME[$cache_key]+x} ]] && (( SECONDS - GRPCURL_CACHE_TIME[$cache_key] < 300 )); then
            continue
        fi
        tmp=$(mktemp)
        grpcurl "${__db_conn[@]}" describe "$name" >"$tmp" 2>/dev/null &
        pending_pid[$name]=$!
        pending_tmp[$name]=$tmp
        pending_key[$name]=$cache_key
    done
    (( ${#pending_pid[@]} == 0 )) && return

    # ponytail: poll-count deadline (20 x 100ms) instead of a wall-clock deadline --
    # avoids a GNU-timeout/date-precision dependency; swap for EPOCHREALTIME if
    # bash 5+ becomes a hard requirement.
    local tick all_done
    for ((tick = 0; tick < 20; tick++)); do
        all_done=1
        for name in "${!pending_pid[@]}"; do
            kill -0 "${pending_pid[$name]}" 2>/dev/null && all_done=0
        done
        (( all_done )) && break
        sleep 0.1
    done

    local items
    for name in "${!pending_pid[@]}"; do
        items=''
        if kill -0 "${pending_pid[$name]}" 2>/dev/null; then
            kill "${pending_pid[$name]}" 2>/dev/null
            wait "${pending_pid[$name]}" 2>/dev/null
        else
            wait "${pending_pid[$name]}" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                items=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${pending_tmp[$name]}" | grep -v '^$')
            fi
        fi
        rm -f "${pending_tmp[$name]}"
        GRPCURL_CACHE_TIME[${pending_key[$name]}]=$SECONDS
        GRPCURL_CACHE_ITEMS[${pending_key[$name]}]=$items
    done
}

# Discovers standalone message/enum types reachable from the known services: first
# each service's own RPC request/response types, then -- since a type is often only
# reachable as a field of another message, never as any RPC's direct request/response
# (e.g. a shared type referenced only from within a nested submessage) -- each newly
# discovered type's own field types, repeated until a round finds nothing new.
_grpcurl_referenced_types() {
    local -n conn_args=$1
    local -n svc_list_ref=$2
    local -A discovered=()
    local svc cache_key line t1 t2 t

    # Cache the crawl's own OUTPUT, not just the describe calls it depends on -- every
    # round re-walks every discovered type's cached lines through two regexes, which is
    # cheap once but adds up fast in bash's interpreted `[[ =~ ]]` when replayed on every
    # keystroke of a symbol (typing 'd', 'dt', 'dto', ... each re-triggers the full
    # crawl even though every underlying describe call is already a cache hit). This
    # was the actual bottleneck -- confirmed by it staying slow even against a
    # near-zero-latency LAN server, where the network portion above is already fast.
    local types_cache_key
    printf -v types_cache_key 'types|%s|%s' "${conn_args[*]}" "${svc_list_ref[*]}"
    if [[ -n ${GRPCURL_CACHE_TIME[$types_cache_key]+x} ]] && (( SECONDS - GRPCURL_CACHE_TIME[$types_cache_key] < 300 )); then
        [[ -n ${GRPCURL_CACHE_ITEMS[$types_cache_key]} ]] && printf '%s\n' "${GRPCURL_CACHE_ITEMS[$types_cache_key]}"
        return
    fi

    _grpcurl_describe_batch conn_args svc_list_ref
    local -a frontier=()
    for svc in "${svc_list_ref[@]}"; do
        printf -v cache_key '%s|' "${conn_args[@]}" describe "$svc"
        cache_key=${cache_key%|}
        while IFS= read -r line; do
            if [[ $line =~ $GRPCURL_RPC_TYPE_PATTERN ]]; then
                t1=${BASH_REMATCH[2]#.}
                t2=${BASH_REMATCH[4]#.}
                for t in "$t1" "$t2"; do
                    if [[ -z ${discovered[$t]+x} ]]; then
                        discovered[$t]=1
                        frontier+=("$t")
                    fi
                done
            fi
        done <<< "${GRPCURL_CACHE_ITEMS[$cache_key]}"
    done

    # ponytail: extra rounds share a single ~2s budget (deadline, not per-round), plus
    # a 4-round hard cap -- giving each round its own full 2s made worst case scale as
    # rounds x 2s (up to ~12s and felt "so slow" in practice). A slow/hanging network
    # call still costs its round the full budget, but that can now only happen once,
    # not once per round. Results are cached for 300s, so a repeat Tab press, or a
    # deeper describe reusing already-crawled types, stays fast regardless.
    local extra_rounds_deadline=$((SECONDS + 2))
    local round
    for ((round = 0; round < 4 && ${#frontier[@]} > 0 && SECONDS < extra_rounds_deadline; round++)); do
        local -a next_frontier=()
        _grpcurl_describe_batch conn_args frontier
        for svc in "${frontier[@]}"; do
            printf -v cache_key '%s|' "${conn_args[@]}" describe "$svc"
            cache_key=${cache_key%|}
            while IFS= read -r line; do
                if [[ $line =~ $GRPCURL_FIELD_TYPE_PATTERN ]]; then
                    t=${BASH_REMATCH[2]}
                    if [[ -z ${discovered[$t]+x} ]]; then
                        discovered[$t]=1
                        next_frontier+=("$t")
                    fi
                fi
            done <<< "${GRPCURL_CACHE_ITEMS[$cache_key]}"
        done
        frontier=("${next_frontier[@]}")
    done

    local result=''
    (( ${#discovered[@]} > 0 )) && result=$(printf '%s\n' "${!discovered[@]}")
    GRPCURL_CACHE_TIME[$types_cache_key]=$SECONDS
    GRPCURL_CACHE_ITEMS[$types_cache_key]=$result
    [[ -n $result ]] && printf '%s\n' "$result"
}

# Registered with `complete -o nospace` so bash never auto-appends a trailing
# space -- we add it ourselves, except after a partial dot-segment or a service
# name offered in slash form (ends in '.' or '/'), so the user can keep tabbing
# through 'contoso.' -> 'contoso.MyService/' -> its methods without having to
# backspace over an unwanted space first.
_grpcurl_finish() {
    local e
    for e in "$@"; do
        if [[ $e == *[./] ]]; then
            COMPREPLY+=("$e")
        else
            COMPREPLY+=("$e ")
        fi
    done
}

_grpcurl_complete() {
    COMPREPLY=()
    local cur=${COMP_WORDS[COMP_CWORD]}
    local -a connection_args=()
    local address='' address_seen=0 verb=''
    local i word resolved

    for ((i = 1; i < COMP_CWORD; i++)); do
        word=${COMP_WORDS[i]}
        if [[ $word == -* ]]; then
            if [[ -n ${GRPCURL_FLAGS[$word]+x} ]]; then
                if [[ ${GRPCURL_FLAGS[$word]} -eq 1 ]] && (( i + 1 < COMP_CWORD )); then
                    ((i++))
                    resolved=$(_grpcurl_resolve_word "${COMP_WORDS[i]}") && connection_args+=("$word" "$resolved")
                elif [[ ${GRPCURL_FLAGS[$word]} -eq 0 ]]; then
                    connection_args+=("$word")
                fi
            fi
            continue
        fi
        if (( ! address_seen )); then
            resolved=$(_grpcurl_resolve_word "$word") && { address=$resolved; address_seen=1; }
        elif [[ -z $verb ]]; then
            verb=$word
        fi
    done

    if [[ $cur == -* ]]; then
        local -a flags=()
        local flag
        for flag in "${!GRPCURL_FLAGS[@]}"; do
            [[ $flag == "$cur"* ]] && flags+=("$flag")
        done
        IFS=$'\n' flags=($(sort <<< "${flags[*]}"))
        _grpcurl_finish "${flags[@]}"
        return
    fi

    if (( ! address_seen )); then
        # The current bare word is the address itself -- nothing to complete.
        return
    fi

    connection_args+=("$address")

    # 'list'/'describe' only make sense in the verb slot, i.e. when nothing after
    # the address has been typed yet -- not once a verb (or symbol) already has.
    local -a verb_completions=()
    if [[ -z $verb && $cur != *"/"* ]]; then
        local v
        for v in list describe; do
            [[ ${v,,} == "${cur,,}"* ]] && verb_completions+=("$v")
        done
    fi

    if [[ $cur == *"/"* ]]; then
        local service=${cur%/*} method_prefix=${cur##*/}
        local -a methods=()
        local m
        while IFS= read -r m; do
            [[ -n $m ]] || continue
            [[ $m == "$service."* ]] && m=${m#"$service".}
            [[ $m == "$method_prefix"* ]] && methods+=("$service/$m")
        done < <(_grpcurl_list connection_args "$service")
        IFS=$'\n' methods=($(sort <<< "${methods[*]}"))
        _grpcurl_finish "${methods[@]}"
        return
    fi

    local -a services=()
    while IFS= read -r word; do
        [[ -n $word ]] && services+=("$word")
    done < <(_grpcurl_list connection_args "")

    # If the typed text already names a known service (bare, or service + '.'),
    # grpcurl also accepts 'service.method' as a symbol -- switch into method
    # completion using dot form, without requiring a literal '/'.
    local matched_service='' svc
    for svc in "${services[@]}"; do
        if [[ ${svc,,} == "${cur,,}" || ${cur,,} == "${svc,,}."* ]]; then
            if [[ ${#svc} -gt ${#matched_service} ]]; then
                matched_service=$svc
            fi
        fi
    done

    if [[ -n $matched_service ]]; then
        local method_prefix=${cur:${#matched_service}}
        method_prefix=${method_prefix#.}
        local -a methods=()
        local m
        while IFS= read -r m; do
            [[ -n $m ]] || continue
            [[ $m == "$matched_service."* ]] && m=${m#"$matched_service".}
            [[ ${m,,} == "${method_prefix,,}"* ]] && methods+=("$matched_service.$m")
        done < <(_grpcurl_list connection_args "$matched_service")
        IFS=$'\n' methods=($(sort <<< "${methods[*]}"))
        _grpcurl_finish "${verb_completions[@]}" "${methods[@]}"
        return
    fi

    # Under 'describe', standalone message/enum types are valid completion targets
    # too -- discover them from each known service's own RPC signatures (one hop
    # only: request/response types of that service's methods, not their fields).
    local -a narrow_candidates=("${services[@]}")
    if [[ ${verb,,} == describe ]]; then
        local -a discovered=()
        while IFS= read -r word; do
            [[ -n $word ]] && discovered+=("$word")
        done < <(_grpcurl_referenced_types connection_args services)
        local -A seen=()
        local combined=()
        for svc in "${narrow_candidates[@]}" "${discovered[@]}"; do
            [[ -n ${seen[$svc]+x} ]] && continue
            seen[$svc]=1
            combined+=("$svc")
        done
        narrow_candidates=("${combined[@]}")
    fi

    # A full leaf match that names an actual service (as opposed to a describe-only
    # message/enum type) has methods worth tabbing into next -- offer it in slash
    # form ('ReaderService/') instead of a bare name, so the very next Tab lists
    # its methods instead of starting a new (nonsensical) word.
    local -A is_service=()
    for svc in "${services[@]}"; do is_service[$svc]=1; done

    # Otherwise, narrow the package/service hierarchy one dot-segment at a time,
    # e.g. 'pr' -> 'contoso.', 'contoso.e' -> 'contoso.MyService/'.
    local -A segments=()
    local dot_index segment cur_len=${#cur}
    for svc in "${narrow_candidates[@]}"; do
        (( ${#svc} > cur_len )) || continue
        [[ ${svc,,} == "${cur,,}"* ]] || continue
        local tail=${svc:cur_len}
        if [[ $tail == *"."* ]]; then
            local after_dot=${tail#*.}
            segment=${svc:0:$((cur_len + ${#tail} - ${#after_dot}))}
        elif [[ -n ${is_service[$svc]+x} ]]; then
            segment="$svc/"
        else
            segment=$svc
        fi
        segments[$segment]=1
    done

    local -a sorted_segments=()
    IFS=$'\n' sorted_segments=($(sort <<< "${!segments[*]}"))
    _grpcurl_finish "${verb_completions[@]}" "${sorted_segments[@]}"
}

COMP_WORDBREAKS=${COMP_WORDBREAKS//[.\/:]/}
complete -o nospace -F _grpcurl_complete grpcurl
