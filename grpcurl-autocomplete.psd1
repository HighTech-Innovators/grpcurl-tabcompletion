@{
    RootModule        = 'grpcurl-autocomplete.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b8f3f9a4-9d2a-4c2e-9c1a-5e6f3a2b7d10'
    Author            = 'Bart de Boer'
    Description       = 'Tab-completion for grpcurl services and methods via gRPC server reflection.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @('Get-GrpcurlCompletion')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
