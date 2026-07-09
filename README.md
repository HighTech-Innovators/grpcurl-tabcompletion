# grpcurl-autocomplete

Tab-completion for [`grpcurl`](https://github.com/fullstorydev/grpcurl) services and
methods, using the target server's own gRPC reflection (via `grpcurl ... list`).

Supports PowerShell variables and `$env:` values used in the command line, and
narrows package-qualified service/method names one dot-segment at a time:

```powershell
$myserver = 'localhost:50051'
grpcurl -plaintext $myserver <Tab>                     # narrows one package segment at a time: 'co' -> 'contoso.'
grpcurl -plaintext $myserver contoso.myservice<Tab>     # once a full service name matches, lists its methods
grpcurl -plaintext $myserver contoso.myservice.Say<Tab> # narrows methods in dot form (service.Method), same as
grpcurl -plaintext $myserver contoso.myservice/Say<Tab> # ... slash form (service/Method) -- grpcurl accepts both
grpcurl -H "Authorization: $env:myToken" -plaintext $myserver <Tab>
```

Both a PowerShell and a bash version are included, with feature parity between them.

## PowerShell setup

Requires PowerShell 7+ and `grpcurl` on `PATH`.

Add to your `$PROFILE`:

```powershell
Import-Module "/path/to/grpcurl-autocomplete/grpcurl-autocomplete.psd1"
```

### PowerShell tests

```powershell
pwsh ./tests/Test-GrpcurlCompletion.ps1
```

## Bash setup

Requires bash 4+ (associative arrays) and `grpcurl` on `PATH`.

Add to your `.bashrc`:

```bash
source "/path/to/grpcurl-autocomplete/grpcurl-autocomplete.bash"
```

Bash has one variable namespace, so `$VAR` in the command line covers both plain
variables and exported environment variables -- there's no separate `$env:VAR` form
to write, unlike PowerShell.

### Bash tests

```bash
bash tests/test-grpcurl-completion.bash
```
