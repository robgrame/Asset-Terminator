#Requires -Version 7.6

# DispatchApple handler - Service Bus trigger on the 'sub-apple' subscription of the
# 'asset-disposal' topic. All platform dispatchers share one handler; the
# platform is asserted here so a mis-filtered message fails loudly.

param($Message, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Modules/AT.Dispatch.psm1" -Force

Invoke-DisposalDispatch -Message $Message -ExpectedPlatform 'Apple'
