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
        Items = @('pricer.EvoService', 'pricer.FooService', 'grpcbin.GRPCBin')
    }
    $script:ListCache['-plaintext|localhost:9999|list|pricer.EvoService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('pricer.EvoService.SayHello', 'pricer.EvoService.SayGoodbye')
    }
}

$r = Get-Completion 'grpcurl -plaintext $myserver pr'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.') "'pr' should narrow to the single shared segment 'pricer.'"

$r = Get-Completion 'grpcurl -plaintext $myserver pricer.e'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.EvoService') "'pricer.e' (case-insensitive) should complete to the leaf 'pricer.EvoService'"

$r = Get-Completion 'grpcurl -plaintext $myserver pricer.EvoService'
Assert ($r.CompletionText -contains 'pricer.EvoService.SayHello') "exact service match should auto-continue into dot-form methods"
Assert ($r.CompletionText -contains 'pricer.EvoService.SayGoodbye') "exact service match should list all methods when no method prefix given"

$r = Get-Completion 'grpcurl -plaintext $myserver pricer.evoservice.sayh'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.EvoService.SayHello') "dot-form method typing (case-insensitive) should narrow to the matching method, using real casing"

$r = Get-Completion 'grpcurl -plaintext $myserver pricer.EvoService/'
Assert ($r.CompletionText -contains 'pricer.EvoService/SayHello') "explicit slash-typed method completion should still work"

# 'list' and 'describe' verbs are offered in the slot right after the address
$r = Get-Completion 'grpcurl -plaintext $myserver '
Assert ($r.CompletionText -contains 'list') "empty word after address should offer 'list'"
Assert ($r.CompletionText -contains 'describe') "empty word after address should offer 'describe'"

$r = Get-Completion 'grpcurl -plaintext $myserver l'
Assert (@($r.CompletionText) -join ',' -eq 'list') "'l' should narrow verb completion to 'list' only"

# once a verb is already typed, 'list'/'describe' should not be re-offered for the symbol slot
$r = Get-Completion 'grpcurl -plaintext $myserver list pr'
Assert (-not ($r.CompletionText -contains 'list')) "'list'/'describe' should not be re-offered once a verb is already typed"
Assert (@($r.CompletionText) -join ',' -eq 'pricer.') "symbol narrowing after an explicit verb should still work"

# 'describe' also discovers standalone message/enum types (not just services), via each
# known service's own rpc signatures. Seed 'describe' cache entries so no live server is needed.
& (Get-Module grpcurl-autocomplete) {
    $script:ListCache['-plaintext|localhost:9999|describe|pricer.EvoService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @(
            'pricer.EvoService is a service:',
            'service EvoService {',
            'rpc SayHello ( .pricer.evo.dtoflow.type.BatchReadDtosRequest ) returns ( .pricer.evo.dtoflow.type.BatchReadDtosResponse );',
            'rpc SayGoodbye ( .pricer.EvoService.Empty ) returns ( .pricer.EvoService.Empty );',
            # a method with a google.api.http-style option block ends its header in '{', not ';' --
            # real-world REST-mapped services annotate nearly every method this way.
            'rpc Read ( .pricer.evo.dtoflow.type.ReadDtoRequest ) returns ( .pricer.evo.dtos.canvasdesign.v1.Canvasdesign ) {',
            '  option (.google.api.http) = { get: "/canvasdesign.v1/{id=**}" };',
            '}',
            '}'
        )
    }
    $script:ListCache['-plaintext|localhost:9999|describe|pricer.FooService'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('pricer.FooService is a service:', 'service FooService {', '}')
    }
    $script:ListCache['-plaintext|localhost:9999|describe|grpcbin.GRPCBin'] = @{
        Time  = [DateTime]::UtcNow
        Items = @('grpcbin.GRPCBin is a service:', 'service GRPCBin {', '}')
    }
}

# 'pricer.evo.' matches no real service (case-insensitively 'pricer.evo' alone would also
# match the 'EvoService' name itself) -- only reachable via the discovered request type,
# proving discovery + wiring works and is gated on the 'describe' verb.
$r = Get-Completion 'grpcurl -plaintext $myserver describe pricer.evo.'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.evo.dtoflow.,pricer.evo.dtos.') "'describe pricer.evo.' should narrow into both discovered-type package segments sharing that prefix"

# a method annotated with an option block (header ends in '{') must still contribute its
# response type -- this was the actual bug: such lines silently failed to match before.
$r = Get-Completion 'grpcurl -plaintext $myserver describe pricer.evo.dtos.'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.evo.dtos.canvasdesign.') "response type of an option-annotated rpc (header ending in '{') should still be discovered"

$r = Get-Completion 'grpcurl -plaintext $myserver list pr'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.') "'list pr' should still narrow to the service segment only, ignoring describe-only types"

$r = Get-Completion 'grpcurl -plaintext $myserver pr'
Assert (@($r.CompletionText) -join ',' -eq 'pricer.') "no-verb 'pr' should still narrow to the service segment only, ignoring describe-only types"

# An exact type match must not attempt a bogus method-list call against a message type --
# every describe/list call needed was already seeded above, so no new cache keys should appear.
$keysBefore = & (Get-Module grpcurl-autocomplete) { @($script:ListCache.Keys) }
Get-Completion 'grpcurl -plaintext $myserver describe pricer.evo.dtoflow.type.BatchReadDtosRequest' | Out-Null
$keysAfter = & (Get-Module grpcurl-autocomplete) { @($script:ListCache.Keys) }
Assert ((($keysAfter | Sort-Object) -join ',') -eq (($keysBefore | Sort-Object) -join ',')) "exact type match should add no new cache entries (no bogus list/describe call on a message type)"

# Invoke-GrpcurlList against a refusing port returns @() within timeout, does not throw
& (Get-Module grpcurl-autocomplete) {
    $result = Invoke-GrpcurlList -ConnectionArgs @('-plaintext', '127.0.0.1:1') -Service $null
    if ($result.Count -ne 0) { throw "FAILED: expected no results from a refusing port" }
}

Write-Host "All checks passed." -ForegroundColor Green
