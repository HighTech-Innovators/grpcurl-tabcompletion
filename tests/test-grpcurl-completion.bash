#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../grpcurl-autocomplete.bash"

assert() {
    if [[ $1 -ne 0 ]]; then
        echo "FAILED: $2" >&2
        exit 1
    fi
}

# get_completion <line> -- sets COMP_WORDS/COMP_CWORD/COMP_LINE/COMP_POINT and runs
# the completer, leaving results in COMPREPLY (joined with ',' also in $REPLY_JOINED).
get_completion() {
    local line=$1
    read -r -a COMP_WORDS <<< "$line"
    if [[ $line == *' ' ]]; then
        COMP_WORDS+=('')
    fi
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    COMP_LINE=$line
    COMP_POINT=${#line}
    _grpcurl_complete
    IFS=',' REPLY_JOINED="${COMPREPLY[*]}"
    IFS=' '
}

# -pl -> suggests -plaintext, not -insecure
get_completion 'grpcurl -pl'
found_plaintext=0 found_insecure=0
for r in "${COMPREPLY[@]}"; do
    [[ $r == '-plaintext' ]] && found_plaintext=1
    [[ $r == '-insecure' ]] && found_insecure=1
done
assert $(( ! found_plaintext )) "'-pl' should suggest -plaintext"
assert $found_insecure "'-pl' should not suggest -insecure"

# $myserver resolves to its real value
myserver='localhost:9999'
resolved=$(_grpcurl_resolve_word '$myserver')
assert $([[ $resolved == 'localhost:9999' ]]; echo $?) '$myserver should resolve to its real value'

# -H "Authorization: $myToken" resolves the variable (bash has one namespace, no
# separate $env: form needed)
myToken='abc'
resolved=$(_grpcurl_resolve_word 'Authorization: $myToken')
assert $([[ $resolved == 'Authorization: abc' ]]; echo $?) '-H value with $myToken should resolve'

# mypkg.MyService/ classified as method completion for that service (no live server:
# expect empty result, not an error)
get_completion 'grpcurl -plaintext $myserver mypkg.MyService/'

# $(Get-Random)-style subexpression as address is unresolvable -> no completions
get_completion 'grpcurl -plaintext $(date) '
assert $(( ${#COMPREPLY[@]} != 0 )) 'unresolvable address (subexpression) should yield no completions'

# Dot-by-dot service narrowing and dot-form method auto-continue, without a live
# server: seed the cache arrays directly so _grpcurl_list short-circuits to them.
GRPCURL_CACHE_TIME['-plaintext|localhost:9999|list']=$SECONDS
GRPCURL_CACHE_ITEMS['-plaintext|localhost:9999|list']=$'contoso.MyService\ncontoso.OtherService\ngrpcbin.GRPCBin'
GRPCURL_CACHE_TIME['-plaintext|localhost:9999|list|contoso.MyService']=$SECONDS
GRPCURL_CACHE_ITEMS['-plaintext|localhost:9999|list|contoso.MyService']=$'contoso.MyService.SayHello\ncontoso.MyService.SayGoodbye'

get_completion 'grpcurl -plaintext $myserver co'
assert $([[ $REPLY_JOINED == 'contoso.' ]]; echo $?) "'co' should narrow to the single shared segment 'contoso.'"

get_completion 'grpcurl -plaintext $myserver contoso.m'
assert $([[ $REPLY_JOINED == 'contoso.MyService' ]]; echo $?) "'contoso.m' (case-insensitive) should complete to the leaf 'contoso.MyService'"

get_completion 'grpcurl -plaintext $myserver contoso.MyService'
found_hello=0 found_goodbye=0
for r in "${COMPREPLY[@]}"; do
    [[ $r == 'contoso.MyService.SayHello' ]] && found_hello=1
    [[ $r == 'contoso.MyService.SayGoodbye' ]] && found_goodbye=1
done
assert $(( ! found_hello )) 'exact service match should auto-continue into dot-form methods'
assert $(( ! found_goodbye )) 'exact service match should list all methods when no method prefix given'

get_completion 'grpcurl -plaintext $myserver contoso.myservice.sayh'
assert $([[ $REPLY_JOINED == 'contoso.MyService.SayHello' ]]; echo $?) 'dot-form method typing (case-insensitive) should narrow to the matching method, using real casing'

get_completion 'grpcurl -plaintext $myserver contoso.MyService/'
found=0
for r in "${COMPREPLY[@]}"; do [[ $r == 'contoso.MyService/SayHello' ]] && found=1; done
assert $(( ! found )) 'explicit slash-typed method completion should still work'

# 'list' and 'describe' verbs are offered in the slot right after the address
get_completion 'grpcurl -plaintext $myserver '
found_list=0 found_describe=0
for r in "${COMPREPLY[@]}"; do
    [[ $r == 'list' ]] && found_list=1
    [[ $r == 'describe' ]] && found_describe=1
done
assert $(( ! found_list )) "empty word after address should offer 'list'"
assert $(( ! found_describe )) "empty word after address should offer 'describe'"

# COMP_WORDBREAKS must exclude '.', '/', and ':' -- bash uses it to split every word in
# COMP_WORDS, not just the current one. Leaving ':' in would split a host:port address
# into two COMP_WORDS entries, and the second fragment (e.g. '443') would get mistaken
# for the verb by the parse loop below, silently suppressing 'list'/'describe'.
assert $([[ $COMP_WORDBREAKS != *[.\/:]* ]]; echo $?) "COMP_WORDBREAKS must not contain '.', '/', or ':'"

# Regression: a real host:port address (with embedded dots too) must not be mistaken
# for a verb, which would suppress the list/describe verb-slot offer.
get_completion 'grpcurl myhost.example.com:443 li'
assert $([[ $REPLY_JOINED == 'list' ]]; echo $?) "'li' after a colon-containing address should still offer 'list'"

get_completion 'grpcurl -plaintext $myserver l'
assert $([[ $REPLY_JOINED == 'list' ]]; echo $?) "'l' should narrow verb completion to 'list' only"

# once a verb is already typed, 'list'/'describe' should not be re-offered for the symbol slot
get_completion 'grpcurl -plaintext $myserver list co'
found_list=0
for r in "${COMPREPLY[@]}"; do [[ $r == 'list' ]] && found_list=1; done
assert $found_list "'list'/'describe' should not be re-offered once a verb is already typed"
assert $([[ $REPLY_JOINED == 'contoso.' ]]; echo $?) 'symbol narrowing after an explicit verb should still work'

# 'describe' also discovers standalone message/enum types via each known service's
# own rpc signatures. Seed 'describe' cache entries so no live server is needed.
GRPCURL_CACHE_TIME['-plaintext|localhost:9999|describe|contoso.MyService']=$SECONDS
GRPCURL_CACHE_ITEMS['-plaintext|localhost:9999|describe|contoso.MyService']=$'contoso.MyService is a service:\nservice MyService {\nrpc SayHello ( .contoso.my.reqtypes.type.BatchReadItemsRequest ) returns ( .contoso.my.reqtypes.type.BatchReadItemsResponse );\nrpc SayGoodbye ( .contoso.MyService.Empty ) returns ( .contoso.MyService.Empty );\nrpc Read ( .contoso.my.reqtypes.type.ReadItemRequest ) returns ( .contoso.my.restypes.widget.v1.Widget ) {\n  option (.google.api.http) = { get: "/widget.v1/{id=**}" };\n}\n}'
GRPCURL_CACHE_TIME['-plaintext|localhost:9999|describe|contoso.OtherService']=$SECONDS
GRPCURL_CACHE_ITEMS['-plaintext|localhost:9999|describe|contoso.OtherService']=$'contoso.OtherService is a service:\nservice OtherService {\n}'
GRPCURL_CACHE_TIME['-plaintext|localhost:9999|describe|grpcbin.GRPCBin']=$SECONDS
GRPCURL_CACHE_ITEMS['-plaintext|localhost:9999|describe|grpcbin.GRPCBin']=$'grpcbin.GRPCBin is a service:\nservice GRPCBin {\n}'

# 'contoso.my.' matches no real service -- only reachable via the discovered request
# type, proving discovery + wiring works and is gated on the 'describe' verb.
get_completion 'grpcurl -plaintext $myserver describe contoso.my.'
assert $([[ $REPLY_JOINED == 'contoso.my.reqtypes.,contoso.my.restypes.' || $REPLY_JOINED == 'contoso.my.restypes.,contoso.my.reqtypes.' ]]; echo $?) "'describe contoso.my.' should narrow into both discovered-type package segments sharing that prefix"

# a method annotated with an option block (header ends in '{') must still contribute
# its response type -- this was the actual bug in the PS version's regex.
get_completion 'grpcurl -plaintext $myserver describe contoso.my.restypes.'
assert $([[ $REPLY_JOINED == 'contoso.my.restypes.widget.' ]]; echo $?) "response type of an option-annotated rpc (header ending in '{') should still be discovered"

get_completion 'grpcurl -plaintext $myserver list co'
assert $([[ $REPLY_JOINED == 'contoso.' ]]; echo $?) "'list co' should still narrow to the service segment only, ignoring describe-only types"

get_completion 'grpcurl -plaintext $myserver co'
assert $([[ $REPLY_JOINED == 'contoso.' ]]; echo $?) "no-verb 'co' should still narrow to the service segment only, ignoring describe-only types"

# An exact type match must not attempt a bogus method-list call against a message
# type -- every describe/list call needed was already seeded above, so no new cache
# keys should appear.
keys_before=$(printf '%s\n' "${!GRPCURL_CACHE_TIME[@]}" | sort)
get_completion 'grpcurl -plaintext $myserver describe contoso.my.reqtypes.type.BatchReadItemsRequest'
keys_after=$(printf '%s\n' "${!GRPCURL_CACHE_TIME[@]}" | sort)
assert $([[ $keys_before == "$keys_after" ]]; echo $?) 'exact type match should add no new cache entries (no bogus list/describe call on a message type)'

# _grpcurl_list against a refusing port returns nothing within the poll budget, does not hang
declare -a refuse_conn=('-plaintext' '127.0.0.1:1')
result=$(_grpcurl_list refuse_conn '')
assert $([[ -z $result ]]; echo $?) 'expected no results from a refusing port'

echo "All checks passed."
