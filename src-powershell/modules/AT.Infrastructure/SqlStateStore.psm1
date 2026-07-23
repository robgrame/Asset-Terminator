# SqlStateStore.psm1  (nested in AT.Infrastructure)
# Transactional current-state store on Azure SQL (passwordless / Entra token).
# Parity with AssetTerminator.Infrastructure.Data.SqlStateStore.
#
# Uses Microsoft.Data.SqlClient (shipped with the SqlServer module declared in the
# Functions app requirements.psd1) with an access token from Managed Identity —
# no passwords. Schema: infra/sql/schema.sql.
#
# Configuration (app settings):
#   SQL_SERVER   : logical server FQDN (e.g. myserver.database.windows.net)
#   SQL_DATABASE : database name

Set-StrictMode -Version Latest

$script:SqlResource   = 'https://database.windows.net/'
$script:TerminalStates = @('Completed', 'Failed', 'TimedOut', 'GuardrailsFailed')

function Test-IsTerminalState {
    <#
        .SYNOPSIS
            True when a request state is terminal (parity with GetActiveAsync filter).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $State)
    return $State -in $script:TerminalStates
}

function New-SqlConnection {
    [CmdletBinding()]
    param()
    $server = $env:SQL_SERVER; $database = $env:SQL_DATABASE
    if (-not $server -or -not $database) { throw 'SQL_SERVER / SQL_DATABASE app settings are not configured.' }

    $conn = [Microsoft.Data.SqlClient.SqlConnection]::new("Server=tcp:$server,1433;Database=$database;Encrypt=True;")
    $conn.AccessToken = Get-IdentityToken -Resource $script:SqlResource
    $conn.Open()
    return $conn
}

function Invoke-SqlNonQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Sql, [hashtable] $Parameters = @{}, $Connection)
    $own = $false
    if (-not $Connection) { $Connection = New-SqlConnection; $own = $true }
    try {
        $cmd = $Connection.CreateCommand(); $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]; if ($null -eq $v) { $v = [DBNull]::Value }
            [void]$cmd.Parameters.AddWithValue("@$k", $v)
        }
        return $cmd.ExecuteNonQuery()
    }
    finally { if ($own) { $Connection.Dispose() } }
}

function Invoke-SqlQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Sql, [hashtable] $Parameters = @{}, $Connection)
    $own = $false
    if (-not $Connection) { $Connection = New-SqlConnection; $own = $true }
    try {
        $cmd = $Connection.CreateCommand(); $cmd.CommandText = $Sql
        foreach ($k in $Parameters.Keys) {
            $v = $Parameters[$k]; if ($null -eq $v) { $v = [DBNull]::Value }
            [void]$cmd.Parameters.AddWithValue("@$k", $v)
        }
        $reader = $cmd.ExecuteReader()
        $rows = [System.Collections.Generic.List[object]]::new()
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $name = $reader.GetName($i)
                $row[$name] = if ($reader.IsDBNull($i)) { $null } else { $reader.GetValue($i) }
            }
            $rows.Add([pscustomobject]$row)
        }
        $reader.Close()
        return $rows
    }
    finally { if ($own) { $Connection.Dispose() } }
}

function Get-DecommissionRequest {
    <# Parity with GetAsync: returns the request row + its actions, or $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId, $Connection)
    $rows = Invoke-SqlQuery -Connection $Connection -Sql 'SELECT * FROM dbo.DecommissionRequests WHERE RequestId=@RequestId' -Parameters @{ RequestId = $RequestId }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    $record = $rows[0]
    $actions = Invoke-SqlQuery -Connection $Connection -Sql 'SELECT * FROM dbo.DecommissionActions WHERE RequestId=@RequestId' -Parameters @{ RequestId = $RequestId }
    $record | Add-Member -NotePropertyName 'actions' -NotePropertyValue @($actions) -Force
    return $record
}

function New-DecommissionRequestRow {
    <#
        .SYNOPSIS
            Idempotent insert of the initial request + actions. Parity with
            GetOrCreateAsync.
        .OUTPUTS
            @{ Record = <row>; Created = <bool> }. Created=$false on duplicate.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Record)

    $conn = New-SqlConnection
    try {
        $existing = Get-DecommissionRequest -RequestId $Record.requestId -Connection $conn
        if ($existing) { return [pscustomobject]@{ Record = $existing; Created = $false } }

        $tx = $conn.BeginTransaction()
        try {
            $insert = @'
INSERT INTO dbo.DecommissionRequests
 (RequestId, CorrelationId, AssetId, DeviceName, SerialNumber, PrimaryUserUpn, DeviceType, AssetCategory,
  DispositionType, TicketNumber, Requestor, DryRun, State, SlaState, CreatedAtUtc, LastUpdatedAtUtc, DueAtUtc, RequestJson)
 VALUES
 (@RequestId, @CorrelationId, @AssetId, @DeviceName, @SerialNumber, @PrimaryUserUpn, @DeviceType, @AssetCategory,
  @DispositionType, @TicketNumber, @Requestor, @DryRun, @State, @SlaState, @CreatedAtUtc, @LastUpdatedAtUtc, @DueAtUtc, @RequestJson);
'@
            $cmd = $conn.CreateCommand(); $cmd.Transaction = $tx; $cmd.CommandText = $insert
            $p = @{
                RequestId = $Record.requestId; CorrelationId = $Record.correlationId; AssetId = $Record.assetId
                DeviceName = $Record.deviceName; SerialNumber = $Record.serialNumber; PrimaryUserUpn = $Record.primaryUserUpn
                DeviceType = $Record.deviceType; AssetCategory = $Record.assetCategory; DispositionType = $Record.dispositionType
                TicketNumber = $Record.ticketNumber; Requestor = $Record.requestor; DryRun = [bool]$Record.dryRun
                State = $Record.state; SlaState = ($Record.PSObject.Properties['slaState'] ? $Record.slaState : $null)
                CreatedAtUtc = $Record.createdAtUtc; LastUpdatedAtUtc = $Record.lastUpdatedAtUtc
                DueAtUtc = $Record.dueAtUtc; RequestJson = ($Record.PSObject.Properties['requestJson'] ? $Record.requestJson : $null)
            }
            foreach ($k in $p.Keys) { $v = $p[$k]; if ($null -eq $v) { $v = [DBNull]::Value }; [void]$cmd.Parameters.AddWithValue("@$k", $v) }
            [void]$cmd.ExecuteNonQuery()

            foreach ($a in @($Record.actions)) {
                $ac = $conn.CreateCommand(); $ac.Transaction = $tx
                $ac.CommandText = 'INSERT INTO dbo.DecommissionActions (RequestId, Target, [Action], Status) VALUES (@RequestId, @Target, @Action, @Status);'
                [void]$ac.Parameters.AddWithValue('@RequestId', $Record.requestId)
                [void]$ac.Parameters.AddWithValue('@Target', $a.target)
                [void]$ac.Parameters.AddWithValue('@Action', $a.action)
                [void]$ac.Parameters.AddWithValue('@Status', $a.status)
                [void]$ac.ExecuteNonQuery()
            }
            $tx.Commit()
            return [pscustomobject]@{ Record = $Record; Created = $true }
        }
        catch {
            $tx.Rollback()
            # Lost a race: return the winner (parity with DbUpdateException handling).
            $winner = Get-DecommissionRequest -RequestId $Record.requestId -Connection $conn
            if ($winner) { return [pscustomobject]@{ Record = $winner; Created = $false } }
            throw
        }
    }
    finally { $conn.Dispose() }
}

function Set-RequestState {
    <# Updates a request's state + timestamps. Parity with UpdateAsync. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $State,
        [string] $SlaState
    )
    Invoke-SqlNonQuery -Sql 'UPDATE dbo.DecommissionRequests SET State=@State, SlaState=COALESCE(@SlaState, SlaState), LastUpdatedAtUtc=SYSUTCDATETIME() WHERE RequestId=@RequestId' `
        -Parameters @{ RequestId = $RequestId; State = $State; SlaState = $SlaState }
}

function Set-ActionStatus {
    <# Updates a single sub-action's status/outcome. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Target,
        [Parameter(Mandatory)][string] $Status,
        [string] $FinalOutcome
    )
    Invoke-SqlNonQuery -Sql 'UPDATE dbo.DecommissionActions SET Status=@Status, FinalOutcome=COALESCE(@FinalOutcome, FinalOutcome), Attempts=Attempts+1, LastUpdatedUtc=SYSUTCDATETIME() WHERE RequestId=@RequestId AND Target=@Target' `
        -Parameters @{ RequestId = $RequestId; Target = $Target; Status = $Status; FinalOutcome = $FinalOutcome }
}

function Get-ActiveRequests {
    <# Non-terminal requests for the polling engine. Parity with GetActiveAsync. #>
    [CmdletBinding()]
    param([int] $Max = 100)
    $placeholders = ($script:TerminalStates | ForEach-Object { "'$_'" }) -join ','
    Invoke-SqlQuery -Sql "SELECT TOP ($Max) * FROM dbo.DecommissionRequests WHERE State NOT IN ($placeholders) ORDER BY LastUpdatedAtUtc ASC"
}

function Add-GuardrailOverride {
    <# Records an approved guardrail override. Parity with AddOverrideAsync. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $ApproverUpn,
        [Parameter(Mandatory)][string] $Reason,
        [string[]] $GuardrailIds = @()
    )
    Invoke-SqlNonQuery -Sql 'INSERT INTO dbo.GuardrailOverrides (RequestId, ApproverUpn, Reason, GuardrailIds, GrantedAtUtc) VALUES (@RequestId, @ApproverUpn, @Reason, @GuardrailIds, SYSUTCDATETIME());' `
        -Parameters @{ RequestId = $RequestId; ApproverUpn = $ApproverUpn; Reason = $Reason; GuardrailIds = ($GuardrailIds | ConvertTo-Json -Compress) }
}

function Get-GuardrailOverride {
    <# Returns approved overrides for a request. Parity with GetOverridesAsync. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId)
    Invoke-SqlQuery -Sql 'SELECT * FROM dbo.GuardrailOverrides WHERE RequestId=@RequestId' -Parameters @{ RequestId = $RequestId }
}

function Set-DeviceContextJson {
    <# Persists the enriched device-context JSON on the request row. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RequestId, [string] $DeviceContextJson)
    Invoke-SqlNonQuery -Sql 'UPDATE dbo.DecommissionRequests SET DeviceContextJson=@Json, LastUpdatedAtUtc=SYSUTCDATETIME() WHERE RequestId=@RequestId' `
        -Parameters @{ RequestId = $RequestId; Json = $DeviceContextJson }
}

function Set-ActionNextPoll {
    <# Sets (or clears, when $null) a sub-action's next-poll time for retry backoff. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RequestId,
        [Parameter(Mandatory)][string] $Target,
        [datetime] $NextPollUtc
    )
    $val = if ($PSBoundParameters.ContainsKey('NextPollUtc') -and $NextPollUtc) { $NextPollUtc.ToUniversalTime() } else { $null }
    Invoke-SqlNonQuery -Sql 'UPDATE dbo.DecommissionActions SET NextPollUtc=@NextPollUtc, LastUpdatedUtc=SYSUTCDATETIME() WHERE RequestId=@RequestId AND Target=@Target' `
        -Parameters @{ RequestId = $RequestId; Target = $Target; NextPollUtc = $val }
}

Export-ModuleMember -Function Test-IsTerminalState, New-SqlConnection, Invoke-SqlNonQuery, Invoke-SqlQuery, `
    Get-DecommissionRequest, New-DecommissionRequestRow, Set-RequestState, Set-ActionStatus, `
    Get-ActiveRequests, Add-GuardrailOverride, Get-GuardrailOverride, Set-DeviceContextJson, Set-ActionNextPoll
