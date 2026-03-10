Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-AssemblerSchemaJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string]$SchemaPath,
        [Parameter(Mandatory = $true)][string]$DocumentLabel
    )

    $result = [ordered]@{
        isValid = $false
        message = $null
    }

    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        $result.message = "Schema file not found: $SchemaPath"
        return $result
    }

    try {
        $isValid = Test-Json -Json $JsonText -SchemaFile $SchemaPath -ErrorAction Stop
        if ($isValid) {
            $result.isValid = $true
            return $result
        }

        $result.message = "JSON schema validation failed for '$DocumentLabel' against '$SchemaPath'."
        return $result
    }
    catch {
        $result.message = "JSON schema validation failed for '$DocumentLabel' against '$SchemaPath': $($_.Exception.Message)"
        return $result
    }
}

function Test-AssemblerSchemaFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DocumentPath,
        [Parameter(Mandatory = $true)][string]$SchemaPath
    )

    if (-not (Test-Path -LiteralPath $DocumentPath -PathType Leaf)) {
        return [ordered]@{ isValid = $false; message = "Required file not found: $DocumentPath" }
    }

    try {
        $jsonText = Get-Content -LiteralPath $DocumentPath -Raw -Encoding UTF8
    }
    catch {
        return [ordered]@{ isValid = $false; message = "Failed to read file '$DocumentPath': $($_.Exception.Message)" }
    }

    return (Test-AssemblerSchemaJson -JsonText $jsonText -SchemaPath $SchemaPath -DocumentLabel $DocumentPath)
}

Export-ModuleMember -Function Test-AssemblerSchemaJson, Test-AssemblerSchemaFile
