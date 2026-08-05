#Requires -Version 7.6

# Cutover safety check, extracted so it can be unit tested independently of
# deploy.ps1 (which requires a live Azure CLI session end-to-end).
#
# Dot-source this file to get Test-ServiceBusBacklog without running deploy.ps1.

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
    #>
    param(
        [Parameter(Mandatory)] [string] $SubscriptionId,
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $NamespaceName
    )

    $backlogEntries = [System.Collections.Generic.List[string]]::new()

    $queueNames = @(
        az servicebus queue list `
            --subscription $SubscriptionId --resource-group $ResourceGroupName --namespace-name $NamespaceName `
            --query '[].name' --output tsv 2>$null
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($queueName in $queueNames) {
        $counts = az servicebus queue show `
            --subscription $SubscriptionId --resource-group $ResourceGroupName --namespace-name $NamespaceName --name $queueName `
            --query '{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}' --output json 2>$null |
            ConvertFrom-Json
        if ($counts -and ([int]$counts.active -gt 0 -or [int]$counts.deadLetter -gt 0)) {
            $backlogEntries.Add("queue '$queueName': active=$($counts.active), deadLetter=$($counts.deadLetter)")
        }
    }

    $topicNames = @(
        az servicebus topic list `
            --subscription $SubscriptionId --resource-group $ResourceGroupName --namespace-name $NamespaceName `
            --query '[].name' --output tsv 2>$null
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($topicName in $topicNames) {
        $subscriptionNames = @(
            az servicebus topic subscription list `
                --subscription $SubscriptionId --resource-group $ResourceGroupName --namespace-name $NamespaceName --topic-name $topicName `
                --query '[].name' --output tsv 2>$null
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        foreach ($subscriptionName in $subscriptionNames) {
            $counts = az servicebus topic subscription show `
                --subscription $SubscriptionId --resource-group $ResourceGroupName --namespace-name $NamespaceName `
                --topic-name $topicName --name $subscriptionName `
                --query '{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}' --output json 2>$null |
                ConvertFrom-Json
            if ($counts -and ([int]$counts.active -gt 0 -or [int]$counts.deadLetter -gt 0)) {
                $backlogEntries.Add("topic '$topicName' / subscription '$subscriptionName': active=$($counts.active), deadLetter=$($counts.deadLetter)")
            }
        }
    }

    return @($backlogEntries)
}
