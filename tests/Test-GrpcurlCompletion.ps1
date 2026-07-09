#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'grpcurl-autocomplete.psd1') -Force

function Assert($condition, $message) {
    if (-not $condition) { throw "FAILED: $message" }
}

function Get-Completion($line, [switch]$AtEnd) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
    $commandAst = $ast.EndBlock.Statements[0].PipelineElements[0]
    $cursor = $line.Length
    $wordToComplete = ''
    $last = $commandAst.CommandElements[-1]
    if ($last.Extent.EndOffset -eq $cursor) {
        $wordToComplete = $last.Extent.Text
    }
    Get-GrpcurlCompletion -WordToComplete $wordToComplete -CommandAst $commandAst -CursorPosition $cursor
}

# -pl -> suggests -plaintext, not -insecure
$r = Get-Completion 'grpcurl -pl'
Assert ($r.CompletionText -contains '-plaintext') "'-pl' should suggest -plaintext"
Assert (-not ($r.CompletionText -contains '-insecure')) "'-pl' should not suggest -insecure"

# $myserver resolves to its real value (exercised via the module's private resolver)
$myserver = 'localhost:9999'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput('grpcurl -plaintext $myserver ', [ref]$tokens, [ref]$errors)
$commandAst = $ast.EndBlock.Statements[0].PipelineElements[0]
$addressAst = $commandAst.CommandElements[2]
$resolved = & (Get-Module grpcurl-autocomplete) { param($a) Resolve-GrpcurlToken $a } $addressAst
Assert ($resolved -eq 'localhost:9999') "`$myserver should resolve to its real value"

# -H "Authorization: $env:myToken" resolves the env var
$env:myToken = 'abc'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput('grpcurl -H "Authorization: $env:myToken" $myserver ', [ref]$tokens, [ref]$errors)
$commandAst = $ast.EndBlock.Statements[0].PipelineElements[0]
$headerValueAst = $commandAst.CommandElements[2]
$resolved = & (Get-Module grpcurl-autocomplete) { param($a) Resolve-GrpcurlToken $a } $headerValueAst
Assert ($resolved -eq 'Authorization: abc') "-H value with `$env:myToken should resolve"

# mypkg.MyService/ classified as method completion for that service (no live server: expect empty result, not throw)
Get-Completion 'grpcurl -plaintext $myserver mypkg.MyService/' | Out-Null

# $(Get-Random) as address is unresolvable -> no completions
$r = Get-Completion 'grpcurl -plaintext $(Get-Random) '
Assert (($null -eq $r) -or ($r.Count -eq 0)) "unresolvable address (subexpression) should yield no completions"

# Dot-by-dot service narrowing and dot-form method auto-continue, without a live server:
# seed the module's list cache directly so Invoke-GrpcurlList short-circuits to it.
& (Get-Module grpcurl-autocomplete) {
    $script:ListCache['-plaintext|localhost:9999|list'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('contoso.MyService', 'contoso.OtherService', 'grpcbin.GRPCBin')
    }
    $script:ListCache['-plaintext|localhost:9999|list|contoso.MyService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('contoso.MyService.SayHello', 'contoso.MyService.SayGoodbye')
    }
}

$r = Get-Completion 'grpcurl -plaintext $myserver co'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.') "'co' should narrow to the single shared segment 'contoso.'"

$r = Get-Completion 'grpcurl -plaintext $myserver contoso.m'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.MyService') "'contoso.m' (case-insensitive) should complete to the leaf 'contoso.MyService'"

$r = Get-Completion 'grpcurl -plaintext $myserver contoso.MyService'
Assert ($r.CompletionText -contains 'contoso.MyService.SayHello') "exact service match should auto-continue into dot-form methods"
Assert ($r.CompletionText -contains 'contoso.MyService.SayGoodbye') "exact service match should list all methods when no method prefix given"

$r = Get-Completion 'grpcurl -plaintext $myserver contoso.myservice.sayh'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.MyService.SayHello') "dot-form method typing (case-insensitive) should narrow to the matching method, using real casing"

$r = Get-Completion 'grpcurl -plaintext $myserver contoso.MyService/'
Assert ($r.CompletionText -contains 'contoso.MyService/SayHello') "explicit slash-typed method completion should still work"

# 'list' and 'describe' verbs are offered in the slot right after the address
$r = Get-Completion 'grpcurl -plaintext $myserver '
Assert ($r.CompletionText -contains 'list') "empty word after address should offer 'list'"
Assert ($r.CompletionText -contains 'describe') "empty word after address should offer 'describe'"

$r = Get-Completion 'grpcurl -plaintext $myserver l'
Assert (@($r.CompletionText) -join ',' -eq 'list') "'l' should narrow verb completion to 'list' only"

# once a verb is already typed, 'list'/'describe' should not be re-offered for the symbol slot
$r = Get-Completion 'grpcurl -plaintext $myserver list co'
Assert (-not ($r.CompletionText -contains 'list')) "'list'/'describe' should not be re-offered once a verb is already typed"
Assert (@($r.CompletionText) -join ',' -eq 'contoso.') "symbol narrowing after an explicit verb should still work"

# 'describe' also discovers standalone message/enum types (not just services), via each
# known service's own rpc signatures. Seed 'describe' cache entries so no live server is needed.
& (Get-Module grpcurl-autocomplete) {
    $script:ListCache['-plaintext|localhost:9999|describe|contoso.MyService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @(
            'contoso.MyService is a service:',
            'service MyService {',
            'rpc SayHello ( .contoso.my.reqtypes.type.BatchReadItemsRequest ) returns ( .contoso.my.reqtypes.type.BatchReadItemsResponse );',
            'rpc SayGoodbye ( .contoso.MyService.Empty ) returns ( .contoso.MyService.Empty );',
            # a method with a google.api.http-style option block ends its header in '{', not ';' --
            # real-world REST-mapped services annotate nearly every method this way.
            'rpc Read ( .contoso.my.reqtypes.type.ReadItemRequest ) returns ( .contoso.my.restypes.widget.v1.Widget ) {',
            '  option (.google.api.http) = { get: "/widget.v1/{id=**}" };',
            '}',
            '}'
        )
    }
    $script:ListCache['-plaintext|localhost:9999|describe|contoso.OtherService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('contoso.OtherService is a service:', 'service OtherService {', '}')
    }
    $script:ListCache['-plaintext|localhost:9999|describe|grpcbin.GRPCBin'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('grpcbin.GRPCBin is a service:', 'service GRPCBin {', '}')
    }
}

# 'contoso.my.' matches no real service (case-insensitively 'contoso.myservice' alone
# would also match the 'MyService' name itself) -- only reachable via the discovered request type,
# proving discovery + wiring works and is gated on the 'describe' verb.
$r = Get-Completion 'grpcurl -plaintext $myserver describe contoso.my.'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.my.reqtypes.,contoso.my.restypes.') "'describe contoso.my.' should narrow into both discovered-type package segments sharing that prefix"

# a method annotated with an option block (header ends in '{') must still contribute its
# response type -- this was the actual bug: such lines silently failed to match before.
$r = Get-Completion 'grpcurl -plaintext $myserver describe contoso.my.restypes.'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.my.restypes.widget.') "response type of an option-annotated rpc (header ending in '{') should still be discovered"

$r = Get-Completion 'grpcurl -plaintext $myserver list co'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.') "'list co' should still narrow to the service segment only, ignoring describe-only types"

$r = Get-Completion 'grpcurl -plaintext $myserver co'
Assert (@($r.CompletionText) -join ',' -eq 'contoso.') "no-verb 'co' should still narrow to the service segment only, ignoring describe-only types"

# An exact type match must not attempt a bogus method-list call against a message type --
# every describe/list call needed was already seeded above, so no new cache keys should appear.
$keysBefore = & (Get-Module grpcurl-autocomplete) { @($script:ListCache.Keys) }
Get-Completion 'grpcurl -plaintext $myserver describe contoso.my.reqtypes.type.BatchReadItemsRequest' | Out-Null
$keysAfter = & (Get-Module grpcurl-autocomplete) { @($script:ListCache.Keys) }
Assert ((($keysAfter | Sort-Object) -join ',') -eq (($keysBefore | Sort-Object) -join ',')) "exact type match should add no new cache entries (no bogus list/describe call on a message type)"

# Invoke-GrpcurlList against a refusing port returns @() within timeout, does not throw
& (Get-Module grpcurl-autocomplete) {
    $result = Invoke-GrpcurlList -ConnectionArgs @('-plaintext', '127.0.0.1:1') -Service $null
    if ($result.Count -ne 0) { throw "FAILED: expected no results from a refusing port" }
}

Write-Host "All checks passed." -ForegroundColor Green
