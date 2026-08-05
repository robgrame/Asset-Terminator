#Requires -Version 7.6

# Cutover safety check, extracted so it can be unit tested independently of
# deploy.ps1 (which requires a live Azure CLI session end-to-end).
#
# Dot-source this file to get Test-ServiceBusBacklog without running deploy.ps1.
#
# Fail-closed by design: every az invocation below is checked for a non-zero
# exit code, and every JSON payload is validated (non-empty, parseable, and
# carrying numeric active/deadLetter counts) before it is trusted. A CLI
# failure, an empty/garbled response, or a missing count field all THROW -
# none of them is ever silently reinterpreted as "zero messages", which would
# let an unsafe namespace deletion proceed on bad information.

function Invoke-AzCliListOrThrow {
    <#
    .SYNOPSIS
        Runs an 'az ... --output tsv' list command and returns its non-blank
        lines.
    .DESCRIPTION
        Fails closed: a non-zero exit code throws immediately instead of being
        treated as "nothing to list". Suppressing stderr (2>$null) only hides
        the console noise Azure CLI sometimes writes on success; it never
        hides a failure, because $LASTEXITCODE is still checked afterwards.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Description
    )

    $stdout = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed while listing $Description (exit code $LASTEXITCODE): az $($Arguments -join ' ')"
    }

    return @($stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Get-AzCliBacklogCounts {
    <#
    .SYNOPSIS
        Runs an 'az ... --output json' show command that reports
        {active,deadLetter} message counts and returns the parsed object.
    .DESCRIPTION
        Fails closed at every step: a non-zero exit code, empty/whitespace-only
        stdout, invalid JSON, a null result, or a missing/non-numeric
        active/deadLetter field all throw rather than being treated as a
        zero/empty backlog.
    #>
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $Description
    )

    $stdout = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed while querying $Description (exit code $LASTEXITCODE): az $($Arguments -join ' ')"
    }

    $json = (@($stdout) -join [Environment]::NewLine)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Azure CLI returned no output while querying ${Description}: cannot safely determine the backlog."
    }

    try {
        $counts = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Azure CLI returned invalid JSON while querying ${Description}: $($_.Exception.Message)"
    }

    if ($null -eq $counts) {
        throw "Azure CLI returned a null result while querying ${Description}: cannot safely determine the backlog."
    }

    foreach ($field in @('active', 'deadLetter')) {
        $rawValue = $counts.$field
        $parsed = 0
        if ($null -eq $rawValue -or -not [int]::TryParse([string]$rawValue, [ref] $parsed)) {
            throw "Azure CLI returned a missing/non-numeric '$field' count while querying ${Description}: '$rawValue'."
        }
    }

    return $counts
}

function Test-ServiceBusBacklog {
    <#
    .SYNOPSIS
        Returns a list of human-readable backlog descriptions for every queue,
        and every topic/subscription, in a Service Bus namespace that still has
        undelivered messages (active) or unprocessed poison messages
        (dead-letter). An empty list means the namespace is safe to delete.
    .DESCRIPTION
        Deleting a Service Bus namespace during the cutover to the direct
        Automation-dispatch architecture is irreversible: any message still
        sitting in a queue or a dead-letter subscription represents a disposal
        request that was never actioned. This check must run, and the caller
        must abort the whole cutover, before any legacy resource is deleted.

        Every underlying 'az' call is fail-closed (see Invoke-AzCliListOrThrow
        / Get-AzCliBacklogCounts): a CLI failure or an unreadable result always
        throws and aborts the cutover, and is never misread as "no backlog".
    #>
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $NamespaceName
    )

    $backlogEntries = [System.Collections.Generic.List[string]]::new()

    $queueNames = Invoke-AzCliListOrThrow -Description "queues in namespace '$NamespaceName'" -Arguments @(
        'servicebus', 'queue', 'list',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--namespace-name', $NamespaceName,
        '--query', '[].name',
        '--output', 'tsv'
    )

    foreach ($queueName in $queueNames) {
        $counts = Get-AzCliBacklogCounts -Description "queue '$queueName'" -Arguments @(
            'servicebus', 'queue', 'show',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--namespace-name', $NamespaceName,
            '--name', $queueName,
            '--query', '{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}',
            '--output', 'json'
        )
        if ([int]$counts.active -gt 0 -or [int]$counts.deadLetter -gt 0) {
            $backlogEntries.Add("queue '$queueName': active=$($counts.active), deadLetter=$($counts.deadLetter)")
        }
    }

    $topicNames = Invoke-AzCliListOrThrow -Description "topics in namespace '$NamespaceName'" -Arguments @(
        'servicebus', 'topic', 'list',
        '--subscription', $SubscriptionId,
        '--resource-group', $ResourceGroupName,
        '--namespace-name', $NamespaceName,
        '--query', '[].name',
        '--output', 'tsv'
    )

    foreach ($topicName in $topicNames) {
        $subscriptionNames = Invoke-AzCliListOrThrow -Description "subscriptions of topic '$topicName'" -Arguments @(
            'servicebus', 'topic', 'subscription', 'list',
            '--subscription', $SubscriptionId,
            '--resource-group', $ResourceGroupName,
            '--namespace-name', $NamespaceName,
            '--topic-name', $topicName,
            '--query', '[].name',
            '--output', 'tsv'
        )

        foreach ($subscriptionName in $subscriptionNames) {
            $counts = Get-AzCliBacklogCounts -Description "topic '$topicName' / subscription '$subscriptionName'" -Arguments @(
                'servicebus', 'topic', 'subscription', 'show',
                '--subscription', $SubscriptionId,
                '--resource-group', $ResourceGroupName,
                '--namespace-name', $NamespaceName,
                '--topic-name', $topicName,
                '--name', $subscriptionName,
                '--query', '{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}',
                '--output', 'json'
            )
            if ([int]$counts.active -gt 0 -or [int]$counts.deadLetter -gt 0) {
                $backlogEntries.Add("topic '$topicName' / subscription '$subscriptionName': active=$($counts.active), deadLetter=$($counts.deadLetter)")
            }
        }
    }

    return @($backlogEntries)
}
