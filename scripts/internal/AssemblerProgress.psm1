Set-StrictMode -Version Latest

function Get-AssemblerProgressTimestamp {
    (Get-Date).ToUniversalTime().ToString('o')
}

function Write-AssemblerProgressEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet(
            'LoadPlan',
            'ImportBundleArchive',
            'ValidatePlan',
            'LoadBundle',
            'ValidateBundle',
            'LoadTemplate',
            'ResolveMappings',
            'ValidateSdtTargets',
            'RenderDocument',
            'WriteReports',
            'Complete',
            'Failed',
            'Cancelled'
        )][string]$Stage,
        [Parameter(Mandatory = $false)][ValidateSet('Info','Warn','Error')][string]$Level = 'Info',
        [Parameter(Mandatory = $false)][ValidateSet('Pending','Running','Complete','Failed')][string]$Status = 'Running',
        [Parameter(Mandatory = $false)][ValidateRange(0, 100)][int]$Percent = 0,
        [Parameter(Mandatory = $false)][string]$Message = '',
        [Parameter(Mandatory = $false)][string]$CurrentItem = ''
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    $event = [ordered]@{
        timestampUtc = Get-AssemblerProgressTimestamp
        stage = $Stage
        level = $Level
        status = $Status
        percent = $Percent
        message = $Message
        currentItem = $CurrentItem
    }

    $line = $event | ConvertTo-Json -Depth 4 -Compress
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
    return $event
}

function Read-AssemblerProgressEvents {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $events = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json -AsHashtable))
        }
        catch {
            $events.Add([ordered]@{
                timestampUtc = Get-AssemblerProgressTimestamp
                stage = 'Failed'
                level = 'Warn'
                status = 'Failed'
                percent = 0
                message = "Invalid progress JSONL line: $($_.Exception.Message)"
                currentItem = ''
            })
        }
    }

    return @($events)
}

Export-ModuleMember -Function @(
    'Write-AssemblerProgressEvent',
    'Read-AssemblerProgressEvents'
)
