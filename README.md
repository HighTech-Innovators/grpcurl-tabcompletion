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

## Setup

Requires PowerShell 7+ and `grpcurl` on `PATH`.

Add to your `$PROFILE`:

```powershell
Import-Module "S:\oss\grpcurl-autocomplete\grpcurl-autocomplete.psd1"
```

## Tests

```powershell
pwsh ./tests/Test-GrpcurlCompletion.ps1
```
