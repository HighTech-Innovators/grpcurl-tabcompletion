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
declare -A GRPCURL_CACHE_TIME
declare -A GRPCURL_CACHE_ITEMS

# Matches a full 'rpc Name ( [stream] .Type ) returns ( [stream] .Type )' header line
# from `describe <service>` output. See grpcurl-autocomplete.psm1 for the rationale
# (scalar types never match; both ';'- and '{'-terminated headers must match).
GRPCURL_RPC_TYPE_PATTERN='^rpc[[:space:]]+[^[:space:]]+[[:space:]]*\([[:space:]]*(stream[[:space:]]+)?\.([^[:space:])]+)[[:space:]]*\)[[:space:]]*returns[[:space:]]*\([[:space:]]*(stream[[:space:]]+)?\.([^[:space:])]+)[[:space:]]*\)[[:space:]]*(;|\{)[[:space:]]*$'

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

# Discovers standalone message/enum types referenced by each service's own RPC
# signatures (one hop only), by running `describe <svc>` for every known service
# concurrently and sharing a single ~2s poll budget across all of them.
_grpcurl_referenced_types() {
    local -n conn_args=$1
    local -n svc_list_ref=$2
    local -A pending_pid pending_tmp pending_key
    local svc cache_key tmp

    for svc in "${svc_list_ref[@]}"; do
        printf -v cache_key '%s|' "${conn_args[@]}" describe "$svc"
        cache_key=${cache_key%|}
        if [[ -n ${GRPCURL_CACHE_TIME[$cache_key]+x} ]] && (( SECONDS - GRPCURL_CACHE_TIME[$cache_key] < 300 )); then
            continue
        fi
        tmp=$(mktemp)
        grpcurl "${conn_args[@]}" describe "$svc" >"$tmp" 2>/dev/null &
        pending_pid[$svc]=$!
        pending_tmp[$svc]=$tmp
        pending_key[$svc]=$cache_key
    done

    # ponytail: poll-count deadline (20 x 100ms) instead of a wall-clock deadline --
    # avoids a GNU-timeout/date-precision dependency; swap for EPOCHREALTIME if
    # bash 5+ becomes a hard requirement.
    local tick all_done
    for ((tick = 0; tick < 20; tick++)); do
        all_done=1
        for svc in "${!pending_pid[@]}"; do
            kill -0 "${pending_pid[$svc]}" 2>/dev/null && all_done=0
        done
        (( all_done )) && break
        sleep 0.1
    done

    local items
    for svc in "${!pending_pid[@]}"; do
        items=''
        if kill -0 "${pending_pid[$svc]}" 2>/dev/null; then
            kill "${pending_pid[$svc]}" 2>/dev/null
            wait "${pending_pid[$svc]}" 2>/dev/null
        else
            wait "${pending_pid[$svc]}" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                items=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "${pending_tmp[$svc]}" | grep -v '^$')
            fi
        fi
        rm -f "${pending_tmp[$svc]}"
        GRPCURL_CACHE_TIME[${pending_key[$svc]}]=$SECONDS
        GRPCURL_CACHE_ITEMS[${pending_key[$svc]}]=$items
    done

    local -A types=()
    local line t1 t2 cache_key_lookup
    for svc in "${svc_list_ref[@]}"; do
        printf -v cache_key_lookup '%s|' "${conn_args[@]}" describe "$svc"
        cache_key_lookup=${cache_key_lookup%|}
        while IFS= read -r line; do
            if [[ $line =~ $GRPCURL_RPC_TYPE_PATTERN ]]; then
                t1=${BASH_REMATCH[2]#.}
                t2=${BASH_REMATCH[4]#.}
                types[$t1]=1
                types[$t2]=1
            fi
        done <<< "${GRPCURL_CACHE_ITEMS[$cache_key_lookup]}"
    done

    (( ${#types[@]} > 0 )) && printf '%s\n' "${!types[@]}"
}

# Registered with `complete -o nospace` so bash never auto-appends a trailing
# space -- we add it ourselves, except after a partial dot-segment (ends in '.'),
# so the user can keep tabbing through 'contoso.' -> 'contoso.MyService' without
# having to backspace over an unwanted space first.
_grpcurl_finish() {
    local e
    for e in "$@"; do
        if [[ $e == *. ]]; then
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

    # Otherwise, narrow the package/service hierarchy one dot-segment at a time,
    # e.g. 'pr' -> 'contoso.', 'contoso.e' -> 'contoso.MyService'.
    local -A segments=()
    local dot_index segment cur_len=${#cur}
    for svc in "${narrow_candidates[@]}"; do
        (( ${#svc} > cur_len )) || continue
        [[ ${svc,,} == "${cur,,}"* ]] || continue
        local tail=${svc:cur_len}
        if [[ $tail == *"."* ]]; then
            local after_dot=${tail#*.}
            segment=${svc:0:$((cur_len + ${#tail} - ${#after_dot}))}
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
