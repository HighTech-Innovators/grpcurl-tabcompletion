#Requires -Version 7.0

# Flag name -> does it consume the next token as its value (from `grpcurl -help`).
$script:GrpcurlFlags = @{
    '-H'                          = $true
    '-allow-unknown-fields'       = $false
    '-alts'                       = $false
    '-alts-handshaker-service'    = $true
    '-alts-target-service-account'= $true
    '-authority'                  = $true
    '-cacert'                     = $true
    '-cert'                       = $true
    '-connect-timeout'            = $true
    '-d'                          = $true
    '-emit-defaults'              = $false
    '-expand-headers'             = $false
    '-format'                     = $true
    '-format-error'               = $false
    '-help'                       = $false
    '-import-path'                = $true
    '-insecure'                   = $false
    '-keepalive-time'             = $true
    '-key'                        = $true
    '-max-msg-sz'                 = $true
    '-max-time'                   = $true
    '-msg-template'               = $false
    '-plaintext'                  = $false
    '-proto'                      = $true
    '-proto-out-dir'              = $true
    '-protoset'                   = $true
    '-protoset-out'               = $true
    '-reflect-header'             = $true
    '-rpc-header'                 = $true
    '-servername'                 = $true
    '-unix'                       = $false
    '-use-reflection'             = $true
    '-user-agent'                 = $true
    '-v'                          = $false
    '-version'                    = $false
    '-vv'                         = $false
}

# ponytail: 300s TTL, no eviction -- add LRU only if used against dozens of distinct addresses in one session
$script:ListCache = @{}

function Resolve-GrpcurlVariable {
    param([System.Management.Automation.Language.VariableExpressionAst]$Ast)
    try {
        if ($Ast.VariablePath.DriveName -eq 'env') {
            $name = $Ast.VariablePath.UserPath -replace '^env:', ''
            return [System.Environment]::GetEnvironmentVariable($name)
        }
        if ($Ast.VariablePath.IsVariable) {
            $v = $ExecutionContext.SessionState.PSVariable.Get($Ast.VariablePath.UserPath)
            if ($v) { return $v.Value }
        }
        return $null
    } catch {
        return $null
    }
}

function Resolve-GrpcurlExpandableString {
    param([System.Management.Automation.Language.ExpandableStringExpressionAst]$Ast)
    $result = $Ast.Value
    $baseOffset = $Ast.Extent.StartOffset + 1
    $nested = $Ast.NestedExpressions | Sort-Object { $_.Extent.StartOffset } -Descending
    foreach ($n in $nested) {
        $resolved = Resolve-GrpcurlToken $n
        if ($null -eq $resolved) { return $null }
        $localStart = $n.Extent.StartOffset - $baseOffset
        $localLen = $n.Extent.EndOffset - $n.Extent.StartOffset
        if ($localStart -lt 0 -or ($localStart + $localLen) -gt $result.Length) { return $null }
        $result = $result.Substring(0, $localStart) + [string]$resolved + $result.Substring($localStart + $localLen)
    }
    return $result
}

function Resolve-GrpcurlToken {
    param($Ast)
    if ($null -eq $Ast) { return $null }
    switch ($Ast.GetType().Name) {
        'StringConstantExpressionAst' { return $Ast.Value }
        'VariableExpressionAst' { return Resolve-GrpcurlVariable $Ast }
        'ExpandableStringExpressionAst' { return Resolve-GrpcurlExpandableString $Ast }
        default { return $null }
    }
}

function Invoke-GrpcurlList {
    param(
        [string[]]$ConnectionArgs,
        [string]$Service
    )

    $argv = [System.Collections.Generic.List[string]]::new()
    $argv.AddRange([string[]]$ConnectionArgs)
    $argv.Add('list')
    if ($Service) { $argv.Add($Service) }

    $cacheKey = "$($argv -join '|')"
    $cached = $script:ListCache[$cacheKey]
    if ($cached -and ([DateTime]::UtcNow - $cached.Time).TotalSeconds -lt 300) {
        return $cached.Items
    }

    $result = @()
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new('grpcurl')
        foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false

        $proc = [System.Diagnostics.Process]::new()
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $proc.StandardError.ReadToEndAsync() | Out-Null

        if (-not $proc.WaitForExit(2000)) {
            try { $proc.Kill() } catch {}
            return @()
        }

        if ($proc.ExitCode -eq 0) {
            $result = $stdout.Result -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }
    } catch {
        return @()
    }

    $script:ListCache[$cacheKey] = @{ Time = [DateTime]::UtcNow; Items = $result }
    return $result
}

# Matches a full 'rpc Name ( [stream] .Type ) returns ( [stream] .Type )' header line from
# `describe <service>` output. Scalar types (string, int32, ...) have no leading dot and
# never match; unrelated leading-dot tokens on other lines (e.g. option annotations like
# .google.api.http) are excluded because the whole line must match. The header ends with
# ';' for an option-less rpc, or '{' when an option block follows (very common -- most
# REST-mapped services annotate every method with google.api.http) -- both must match.
$script:GrpcurlRpcTypePattern = '^rpc\s+\S+\s*\(\s*(?:stream\s+)?(\.\S+?)\s*\)\s*returns\s*\(\s*(?:stream\s+)?(\.\S+?)\s*\)\s*(?:;|\{)\s*$'

# Matches a message field line referencing another message/enum type, e.g.
# '  .pkg.Type field_name = 3;' or '  repeated .pkg.Type field_name = 5;'. A type is
# often only reachable this way -- as a field of another message -- never as any
# RPC's direct request/response type, so this is a second, distinct discovery source
# from GrpcurlRpcTypePattern, not a variant of it.
$script:GrpcurlFieldTypePattern = '^\s*(?:repeated\s+)?\.(\S+)\s+[A-Za-z_]\w*\s*=\s*\d+;\s*$'

# Runs `describe <name>` for every name in $Names not already freshly cached,
# concurrently, sharing a single ~2s poll budget across all of them, and writes each
# result into $script:ListCache under its own 'describe|<name>' key. Describing N
# names is inherently N process spawns (grpcurl has no "describe everything" mode) --
# run them concurrently instead of one at a time, or wall-clock time is O(N).
function Invoke-GrpcurlDescribeBatch {
    param(
        [string[]]$ConnectionArgs,
        [string[]]$Names
    )

    $pending = [System.Collections.Generic.List[object]]::new()

    foreach ($name in $Names) {
        $argv = @($ConnectionArgs) + @('describe', $name)
        $cacheKey = "$($argv -join '|')"
        $cached = $script:ListCache[$cacheKey]
        if ($cached -and ([DateTime]::UtcNow - $cached.Time).TotalSeconds -lt 300) {
            continue
        }

        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new('grpcurl')
            foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.UseShellExecute = $false

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            [void]$proc.Start()
            $pending.Add([pscustomobject]@{
                CacheKey = $cacheKey
                Process  = $proc
                Stdout   = $proc.StandardOutput.ReadToEndAsync()
                Stderr   = $proc.StandardError.ReadToEndAsync()
            })
        } catch {
            $script:ListCache[$cacheKey] = @{ Time = [DateTime]::UtcNow; Items = @() }
        }
    }

    # Shared deadline, not one timeout per process -- since they all started together,
    # total wall time is bounded by ~2s regardless of how many names are pending.
    $deadline = [DateTime]::UtcNow.AddMilliseconds(2000)
    foreach ($p in $pending) {
        $remaining = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $items = @()
        try {
            if ($p.Process.WaitForExit($remaining)) {
                if ($p.Process.ExitCode -eq 0) {
                    $items = $p.Stdout.Result -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
                }
            } else {
                try { $p.Process.Kill() } catch {}
            }
        } catch {}
        $script:ListCache[$p.CacheKey] = @{ Time = [DateTime]::UtcNow; Items = $items }
    }
}

# Discovers standalone message/enum types reachable from the known services: first
# each service's own RPC request/response types, then -- since a type is often only
# reachable as a field of another message, never as any RPC's direct request/response
# (e.g. a shared type referenced only from within a nested submessage) -- each newly
# discovered type's own field types, repeated until a round finds nothing new.
function Get-GrpcurlReferencedTypes {
    param(
        [string[]]$ConnectionArgs,
        [string[]]$Services
    )

    Invoke-GrpcurlDescribeBatch -ConnectionArgs $ConnectionArgs -Names $Services

    $types = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $frontier = [System.Collections.Generic.List[string]]::new()
    foreach ($svc in $Services) {
        $argv = @($ConnectionArgs) + @('describe', $svc)
        $cacheKey = "$($argv -join '|')"
        foreach ($line in $script:ListCache[$cacheKey].Items) {
            if ($line -match $script:GrpcurlRpcTypePattern) {
                foreach ($t in @($Matches[1].TrimStart('.'), $Matches[2].TrimStart('.'))) {
                    if ($types.Add($t)) { $frontier.Add($t) }
                }
            }
        }
    }

    # ponytail: extra rounds share a single ~2s budget (deadline, not per-round), plus
    # a 4-round hard cap -- giving each round its own full 2s made worst case scale as
    # rounds x 2s (up to ~12s and felt "so slow" in practice). A slow/hanging network
    # call still costs its round the full budget, but that can now only happen once,
    # not once per round. Results are cached for 300s, so a repeat Tab press, or a
    # deeper describe reusing already-crawled types, stays fast regardless.
    $extraRoundsDeadline = [DateTime]::UtcNow.AddMilliseconds(2000)
    for ($round = 0; $round -lt 4 -and $frontier.Count -gt 0 -and [DateTime]::UtcNow -lt $extraRoundsDeadline; $round++) {
        $current = $frontier
        $frontier = [System.Collections.Generic.List[string]]::new()
        Invoke-GrpcurlDescribeBatch -ConnectionArgs $ConnectionArgs -Names $current
        foreach ($svc in $current) {
            $argv = @($ConnectionArgs) + @('describe', $svc)
            $cacheKey = "$($argv -join '|')"
            foreach ($line in $script:ListCache[$cacheKey].Items) {
                if ($line -match $script:GrpcurlFieldTypePattern) {
                    if ($types.Add($Matches[1])) { $frontier.Add($Matches[1]) }
                }
            }
        }
    }

    return @($types)
}

function Get-GrpcurlCompletion {
    [CmdletBinding()]
    param(
        [string]$WordToComplete,
        [System.Management.Automation.Language.CommandAst]$CommandAst,
        [int]$CursorPosition
    )

    $elements = $CommandAst.CommandElements
    $address = $null
    $connectionArgs = [System.Collections.Generic.List[string]]::new()
    $addressSeen = $false
    $verb = $null
    $currentIndex = -1

    for ($i = 1; $i -lt $elements.Count; $i++) {
        $el = $elements[$i]
        if ($el.Extent.StartOffset -le $CursorPosition -and $CursorPosition -le $el.Extent.EndOffset) {
            $currentIndex = $i
            continue
        }

        $paramAst = $el -as [System.Management.Automation.Language.CommandParameterAst]
        if ($paramAst) {
            $flagName = "-$($paramAst.ParameterName)"
            $takesValue = $script:GrpcurlFlags[$flagName]
            if ($takesValue -and ($i + 1) -lt $elements.Count) {
                $valueEl = $elements[$i + 1]
                if (-not ($valueEl.Extent.StartOffset -le $CursorPosition -and $CursorPosition -le $valueEl.Extent.EndOffset)) {
                    $value = Resolve-GrpcurlToken $valueEl
                    if ($null -ne $value) {
                        $connectionArgs.Add($flagName)
                        $connectionArgs.Add([string]$value)
                    }
                    $i++
                }
            } elseif (-not $takesValue) {
                $connectionArgs.Add($flagName)
            }
            continue
        }

        if (-not $addressSeen) {
            $value = Resolve-GrpcurlToken $el
            if ($null -ne $value) {
                $address = [string]$value
                $addressSeen = $true
            }
        } elseif ($null -eq $verb) {
            $stringAst = $el -as [System.Management.Automation.Language.StringConstantExpressionAst]
            if ($stringAst) { $verb = $stringAst.Value }
        }
    }

    $current = if ($currentIndex -ge 0) { $WordToComplete } else { $WordToComplete }

    if ($current.StartsWith('-')) {
        return $script:GrpcurlFlags.Keys |
            Where-Object { $_.StartsWith($current) } |
            Sort-Object |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterName', $_)
            }
    }

    if (-not $addressSeen) {
        # The current bare word is the address itself -- nothing to complete.
        return @()
    }

    $connectionArgs.Add($address)

    # 'list'/'describe' only make sense in the verb slot, i.e. when nothing after
    # the address has been typed yet -- not once a verb (or symbol) already has.
    $verbCompletions = @(if ($null -eq $verb -and -not $current.Contains('/')) {
        'list', 'describe' |
            Where-Object { $_.StartsWith($current, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    })

    if ($current.Contains('/')) {
        $splitIndex = $current.LastIndexOf('/')
        $service = $current.Substring(0, $splitIndex)
        $methodPrefix = $current.Substring($splitIndex + 1)

        # grpcurl's `list <service>` prints fully-qualified "service.Method" names; strip the service prefix.
        $prefix = "$service."
        $methods = Invoke-GrpcurlList -ConnectionArgs $connectionArgs -Service $service |
            ForEach-Object { if ($_.StartsWith($prefix)) { $_.Substring($prefix.Length) } else { $_ } }
        return $methods |
            Where-Object { $_.StartsWith($methodPrefix) } |
            Sort-Object |
            ForEach-Object {
                $full = "$service/$_"
                [System.Management.Automation.CompletionResult]::new($full, $full, 'ParameterValue', $full)
            }
    }

    $services = Invoke-GrpcurlList -ConnectionArgs $connectionArgs -Service $null

    # If the typed text already names a known service (bare, or service + '.'),
    # grpcurl also accepts 'service.method' as a symbol -- switch into method
    # completion using dot form, without requiring a literal '/'.
    $matchedService = $services |
        Where-Object { $current -ieq $_ -or $current.StartsWith("$_.", [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object Length -Descending |
        Select-Object -First 1

    if ($matchedService) {
        $methodPrefix = $current.Substring($matchedService.Length).TrimStart('.')
        $prefix = "$matchedService."
        $methods = Invoke-GrpcurlList -ConnectionArgs $connectionArgs -Service $matchedService |
            ForEach-Object { if ($_.StartsWith($prefix)) { $_.Substring($prefix.Length) } else { $_ } }
        return $verbCompletions + @($methods |
            Where-Object { $_.StartsWith($methodPrefix, [StringComparison]::OrdinalIgnoreCase) } |
            Sort-Object |
            ForEach-Object {
                $full = "$matchedService.$_"
                [System.Management.Automation.CompletionResult]::new($full, $full, 'ParameterValue', $full)
            })
    }

    # Under 'describe', standalone message/enum types are valid completion targets too --
    # discover them from each known service's own RPC signatures, then follow their
    # field types recursively (see Get-GrpcurlReferencedTypes).
    $narrowCandidates = $services
    if ($verb -ieq 'describe') {
        $discoveredTypes = Get-GrpcurlReferencedTypes -ConnectionArgs $connectionArgs -Services $services
        # @() each operand individually before '+' -- a single-service/-type result
        # collapses to a bare string on the pipeline, and string + array concatenates
        # as text instead of combining elements.
        $narrowCandidates = @(@($services) + @($discoveredTypes) | Select-Object -Unique)
    }

    # Otherwise, narrow the package/service hierarchy one dot-segment at a time,
    # e.g. 'pr' -> 'contoso.', 'contoso.e' -> 'contoso.myservice'.
    $segments = [ordered]@{}
    foreach ($svc in $narrowCandidates) {
        if ($svc.Length -le $current.Length) { continue }
        if (-not $svc.StartsWith($current, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $dotIndex = $svc.IndexOf('.', $current.Length)
        $segment = if ($dotIndex -ge 0) { $svc.Substring(0, $dotIndex + 1) } else { $svc }
        $segments[$segment] = $true
    }

    # Trailing '.' on partial segments already signals PSReadLine not to append a
    # space -- ParameterValue is enough; no need for ProviderContainer (that type
    # forces a path-separator character onto the text, hence the stray '\').
    return $verbCompletions + @($segments.Keys |
        Sort-Object |
        ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        })
}

Register-ArgumentCompleter -Native -CommandName grpcurl -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    Get-GrpcurlCompletion -WordToComplete $wordToComplete -CommandAst $commandAst -CursorPosition $cursorPosition
}

Export-ModuleMember -Function Get-GrpcurlCompletion
