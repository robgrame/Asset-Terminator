#Requires -Version 7.6

# Azure Automation runbook dispatch.
#
# Dispatch is always done through ARM:
#   PUT .../automationAccounts/{aa}/jobs/{jobName} with a managed-identity token.
# The client chooses jobName, so replaying the same request never starts a
# duplicate job, and the job status/output can be polled
# deterministically. Webhooks are deliberately not supported: their token lives
# in the URL, they cannot be made idempotent and they return no job status.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module "$PSScriptRoot/AT.Common.psm1"

$script:ArmApiVersion = '2023-11-01'

function Get-AutomationAccountResourceId {
    $explicit = Get-AppSetting -Name 'AUTOMATION_ACCOUNT_RESOURCE_ID'
    if (-not [string]::IsNullOrWhiteSpace($explicit)) { return $explicit.TrimEnd('/') }

    $subscription = Get-AppSetting -Name 'AUTOMATION_SUBSCRIPTION_ID' -Required
    $resourceGroup = Get-AppSetting -Name 'AUTOMATION_RESOURCE_GROUP' -Required
    $account = Get-AppSetting -Name 'AUTOMATION_ACCOUNT_NAME' -Required

    return "/subscriptions/$subscription/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$account"
}

function Get-ArmHeaders {
    $token = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
    return @{ 'Authorization' = "Bearer $token" }
}

function Get-RunbookMap {
    $json = Get-AppSetting -Name 'RUNBOOK_MAP' -Required
    return ($json | ConvertFrom-Json)
}

function Resolve-RunbookBinding {
    <#
    .SYNOPSIS
        Resolves the runbook name and the runbook parameters for a message,
        binding '$.a.b' expressions in RUNBOOK_MAP against the message body.
    #>
    param(
        [Parameter(Mandatory)] [string] $Platform,
        [Parameter(Mandatory)] $Message
    )

    $map = Get-RunbookMap
    if (-not ($map.PSObject.Properties.Name -contains $Platform)) {
        throw "No runbook configured for platform '$Platform' in RUNBOOK_MAP."
    }

    $entry = $map.$Platform
    $parameters = @{}

    if ($entry.PSObject.Properties.Name -contains 'parameters' -and $entry.parameters) {
        foreach ($property in $entry.parameters.PSObject.Properties) {
            $spec = [string]$property.Value
            # A spec starting with '$.' is a JSON path into the message; anything
            # else is a literal, so constants (KmeRegion, WipeWaitSeconds, ...)
            # can be pinned in configuration without a code change.
            $value = if ($spec.StartsWith('$.')) {
                Resolve-JsonPath -InputObject $Message -Path $spec
            }
            else { $spec }

            if ($null -eq $value -or "$value" -eq '') { continue }
            # Automation runbook parameters are always passed as strings.
            $parameters[$property.Name] = if ($value -is [bool]) { $value.ToString().ToLowerInvariant() } else { "$value" }
        }
    }

    $timeout = 30
    if ($entry.PSObject.Properties.Name -contains 'timeoutMinutes' -and $entry.timeoutMinutes) {
        $timeout = [int]$entry.timeoutMinutes
    }

    return [pscustomobject]@{
        Runbook        = [string]$entry.runbook
        Parameters     = $parameters
        TimeoutMinutes = $timeout
        RunOn          = if ($entry.PSObject.Properties.Name -contains 'runOn') { [string]$entry.runOn } else { '' }
    }
}

function Start-AutomationRunbookJob {
    <#
    .SYNOPSIS
        Starts a runbook job with a caller-supplied job name (idempotent).
    .OUTPUTS
        PSCustomObject with JobName, JobId and Status.
    #>
    param(
        [Parameter(Mandatory)] [string] $JobName,
        [Parameter(Mandatory)] [string] $Runbook,
        [hashtable] $Parameters,
        [string] $RunOn = ''
    )

    $uri = '{0}/jobs/{1}?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    $properties = @{
        runbook = @{ name = $Runbook }
        runOn   = $RunOn
    }
    if ($Parameters -and $Parameters.Count -gt 0) { $properties['parameters'] = $Parameters }

    $body = @{ properties = $properties } | ConvertTo-Json -Depth 8

    $response = Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method PUT `
        -Headers (Get-ArmHeaders) -ContentType 'application/json' -Body $body

    return [pscustomobject]@{
        JobName = $JobName
        JobId   = $response.properties.jobId
        Status  = $response.properties.status
    }
}

function Get-AutomationRunbookJob {
    param([Parameter(Mandatory)] [string] $JobName)

    $uri = '{0}/jobs/{1}?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    try {
        $response = Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method GET -Headers (Get-ArmHeaders)
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw
    }

    return [pscustomobject]@{
        JobName       = $JobName
        JobId         = $response.properties.jobId
        Status        = $response.properties.status
        StatusDetails = $response.properties.statusDetails
        StartTime     = $response.properties.startTime
        EndTime       = $response.properties.endTime
        Exception     = $response.properties.exception
    }
}

function Get-AutomationRunbookJobOutput {
    param([Parameter(Mandatory)] [string] $JobName)

    $uri = '{0}/jobs/{1}/output?api-version={2}' -f (Get-AutomationAccountResourceId), $JobName, $script:ArmApiVersion

    try {
        return Invoke-RestMethod -Uri "https://management.azure.com$uri" -Method GET -Headers (Get-ArmHeaders)
    }
    catch {
        return $null
    }
}

# Terminal Automation job states.
function Test-AutomationJobTerminal {
    param([string] $Status)
    return $Status -in @('Completed', 'Failed', 'Stopped', 'Suspended')
}

function Test-TransientArmStatusCode {
    <#
    .SYNOPSIS
        True for the status codes where ARM's outcome is genuinely ambiguous:
        a timeout or 5xx can mean "the request never reached the service" or
        "it succeeded but the response was lost"; 429 means the request may or
        may not have been throttled before or after taking effect.
    #>
    param([Nullable[int]] $StatusCode)

    if ($null -eq $StatusCode) { return $true } # no response at all: network/timeout
    return $StatusCode -eq 429 -or $StatusCode -ge 500
}

function Get-ArmErrorStatusCode {
    param($ErrorRecord)
    return Get-HttpErrorStatusCode -ErrorRecord $ErrorRecord
}

function Invoke-IdempotentRunbookDispatch {
    <#
    .SYNOPSIS
        Starts a runbook job through ARM with a deterministic job name, without
        ever risking a duplicate job when the PUT's outcome is ambiguous.
    .DESCRIPTION
        ARM PUT .../jobs/{jobName} is idempotent *if it reaches the service*,
        but a client-side timeout, a 429 or a 5xx leaves the true outcome
        unknown: the job may have started anyway. The dispatcher must never
        guess in that situation, because guessing wrong either starts a
        duplicate wipe or reports failure for a job that is actually running.

        Sequence:
          1. GET the job first. If it already exists, the PUT is unnecessary
             (a previous attempt succeeded, or is genuinely known now).
          2. Otherwise PUT. A clean success or a clean permanent failure (4xx
             other than 429) is unambiguous.
          3. On a transient failure (timeout / 429 / 5xx) GET the job again:
             - found  -> the PUT actually took effect: Confirmed/Started.
             - 404    -> confirmed absent: safe for the *next* attempt to PUT
               again; this attempt reports Outcome='ConfirmedAbsent' (not a
               permanent failure) so the caller can retry with backoff.
             - the confirming GET itself fails -> Outcome='Unknown': the
               caller must not retry the PUT this attempt (that could create a
               duplicate job) and must not treat this as a terminal failure or
               release any lease; it simply tries again later.
    .OUTPUTS
        PSCustomObject: Outcome ('Started'|'ConfirmedAbsent'|'Unknown'|'PermanentFailure'),
        Job (the job object when known), ErrorMessage.
    #>
    param(
        [Parameter(Mandatory)] [string] $JobName,
        [Parameter(Mandatory)] [string] $Runbook,
        [hashtable] $Parameters,
        [string] $RunOn = ''
    )

    # Step 1: a job with this deterministic name may already exist from a prior
    # attempt whose PUT response never reached us.
    try {
        $existing = Get-AutomationRunbookJob -JobName $JobName
        if ($existing) {
            return [pscustomobject]@{ Outcome = 'Started'; Job = $existing; ErrorMessage = '' }
        }
    }
    catch {
        # The pre-check itself is best-effort: fall through to the PUT. If the
        # PUT also fails ambiguously, the post-check below still applies.
        Write-Warning "Pre-dispatch job lookup failed for '$JobName': $($_.Exception.Message)"
    }

    try {
        $job = Start-AutomationRunbookJob -JobName $JobName -Runbook $Runbook -Parameters $Parameters -RunOn $RunOn
        return [pscustomobject]@{ Outcome = 'Started'; Job = $job; ErrorMessage = '' }
    }
    catch {
        $statusCode = Get-ArmErrorStatusCode -ErrorRecord $_
        if (-not (Test-TransientArmStatusCode -StatusCode $statusCode)) {
            # A clean permanent failure (bad runbook name, RBAC denied, malformed
            # parameters, ...): retrying the same PUT would only fail again.
            return [pscustomobject]@{ Outcome = 'PermanentFailure'; Job = $null; ErrorMessage = $_.Exception.Message }
        }

        $putError = $_.Exception.Message
        try {
            $confirmed = Get-AutomationRunbookJob -JobName $JobName
        }
        catch {
            # The confirming GET is itself unreliable right now: the outcome of
            # the PUT genuinely cannot be determined this attempt.
            return [pscustomobject]@{
                Outcome      = 'Unknown'
                Job          = $null
                ErrorMessage = "PUT failed ambiguously ($putError) and the confirming GET also failed: $($_.Exception.Message)"
            }
        }

        if ($confirmed) {
            return [pscustomobject]@{ Outcome = 'Started'; Job = $confirmed; ErrorMessage = '' }
        }

        # GET confirms the job does not exist: it is safe to PUT again next time.
        return [pscustomobject]@{
            Outcome      = 'ConfirmedAbsent'
            Job          = $null
            ErrorMessage = "PUT failed ambiguously (status $statusCode): $putError. A follow-up GET confirmed the job was not created; safe to retry."
        }
    }
}

function ConvertFrom-RunbookOutput {
    <#
    .SYNOPSIS
        Extracts the structured result a runbook emits as a '##RESULT## {json}'
        line. Falls back to $null when the runbook produced no marker line yet,
        or when the marker line is not valid JSON.
    #>
    param([string] $Output)

    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }

    $line = ($Output -split "`n") |
        Where-Object { $_ -match '##RESULT##' } |
        Select-Object -Last 1

    if (-not $line) { return $null }

    $json = $line.Substring($line.IndexOf('##RESULT##') + 10).Trim()
    try { return $json | ConvertFrom-Json } catch { return $null }
}

function Get-RunbookOutputEvidenceState {
    <#
    .SYNOPSIS
        Classifies why a terminal, 'Completed' Automation job produced no
        parsed result, so JobMonitor can distinguish a transient evidence gap
        (worth a retry) from a runbook that will never emit one.
    .DESCRIPTION
        A completed job with no output at all is most often the Automation
        output store lagging behind the job status: retry a bounded number of
        times ('EvidencePending'). A completed job whose output *is* present
        but has no '##RESULT##' line, or an invalid one, means the runbook
        itself never produced the contract it promises: that is not something
        a retry will fix ('EvidenceMissing'), but it is still recorded as
        retryable-once in case the output store is only briefly behind the job
        status transition.
    .OUTPUTS
        'HasResult' | 'EvidencePending' | 'EvidenceMissing'
    #>
    param(
        [string] $Output,
        $ParsedResult
    )

    if ($null -ne $ParsedResult) { return 'HasResult' }
    if ([string]::IsNullOrWhiteSpace($Output)) { return 'EvidencePending' }
    return 'EvidenceMissing'
}

Export-ModuleMember -Function Resolve-RunbookBinding, Start-AutomationRunbookJob, Get-AutomationRunbookJob, `
    Get-AutomationRunbookJobOutput, Test-AutomationJobTerminal, Test-TransientArmStatusCode, `
    Get-ArmErrorStatusCode, Invoke-IdempotentRunbookDispatch, `
    ConvertFrom-RunbookOutput, Get-RunbookOutputEvidenceState, Get-AutomationAccountResourceId
