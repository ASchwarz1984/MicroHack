param([switch]$FunctionsOnly)

function Test-LabReadyMarker {
    $path = 'C:\MHBox\lab-ready.json'
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    $marker = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $expected = @('MHBox-SQL', 'MHBox-Win2K22', 'MHBox-Ubuntu-01', 'MHBox-AzMigSrv')
    if ($marker.schemaVersion -ne 1 -or $marker.hostName -ine $env:COMPUTERNAME -or
        $marker.windowsHttpStatus -ne 200 -or $marker.linuxHttpStatus -ne 200 -or
        @($marker.nestedVmNames).Count -ne 4 -or (Compare-Object $expected @($marker.nestedVmNames))) {
        throw "Readiness marker '$path' is invalid for this host. No provisioning will be attempted."
    }
    return $true
}

function Import-LabPSResourceGet {
    $module = Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet | Where-Object {
        $_.Version -eq [version]'1.3.1' -and -not $_.PrivateData.PSData.Prerelease
    } | Select-Object -First 1
    if (-not $module) { throw 'Required module Microsoft.PowerShell.PSResourceGet 1.3.1 (stable) is not installed.' }
    # Name-based version resolution can load the bundled DLL before checking its version.
    Import-Module -Name $module.Path -Global -ErrorAction Stop
}

function Install-LabPSResource {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )
    $parts = $Version -split '-', 2
    $prerelease = if ($parts.Count -eq 2) { $parts[1] } else { '' }
    $matchingModule = {
        Get-Module -ListAvailable -Name $Name | Where-Object {
            $_.Version -eq [version]$parts[0] -and
                [string]$_.PrivateData.PSData.Prerelease -ceq $prerelease
        }
    }
    if (-not (& $matchingModule)) {
        Install-PSResource -Name $Name -Version $Version -Prerelease:($parts.Count -eq 2) `
            -Scope AllUsers -Quiet -AcceptLicense -TrustRepository -ErrorAction Stop
        if (-not (& $matchingModule)) { throw "Required module $Name $Version was not installed." }
    }
}

function Invoke-LabVMConfiguration {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $wingetPath = (Get-Command winget -CommandType Application -ErrorAction Stop).Source
    # The pinned, packaged WinGet CLI writes its diagnostics in this per-user directory.
    $diagnosticDirectory = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir'
    $runId = [guid]::NewGuid().ToString('N')
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $previousLogs = @(
            if (Test-Path -LiteralPath $diagnosticDirectory) {
                Get-ChildItem -LiteralPath $diagnosticDirectory -Filter '*.log' -File -ErrorAction Stop |
                    Select-Object -ExpandProperty FullName
            }
        )
        Write-Host "Configuring '$FilePath' with WinGet (attempt $attempt/3; verbose logs: $diagnosticDirectory)."
        $process = Start-Process -FilePath $wingetPath -ArgumentList @(
            'configure', '--file', "`"$FilePath`"", '--accept-configuration-agreements',
            '--disable-interactivity', '--verbose-logs'
        ) -NoNewWindow -Wait -PassThru -ErrorAction Stop
        if ($process.ExitCode -eq 0) { return }

        $failure = "WinGet configuration '$FilePath' failed with exit code $($process.ExitCode)."
        $logs = @()
        try {
            if (Test-Path -LiteralPath $diagnosticDirectory) {
                $logs = @(Get-ChildItem -LiteralPath $diagnosticDirectory -Filter '*.log' -File -ErrorAction Stop |
                    Where-Object { $_.FullName -notin $previousLogs } |
                    ForEach-Object {
                        $content = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop
                        if ($content -match "Process:\s*winget\.exe\[$($process.Id)\]") {
                            [pscustomobject]@{ Path = $_.FullName; Content = $content }
                        }
                    })
            }
            if ($logs.Count -eq 1) {
                $savedLog = Join-Path $env:MHBoxLogsDir "WinGet-$runId-attempt-$attempt.log"
                Copy-Item -LiteralPath $logs[0].Path -Destination $savedLog -ErrorAction Stop
                Write-Host "WinGet diagnostic log saved to '$savedLog'."
            }
        }
        catch {
            throw "$failure Could not preserve diagnostic logs: $($_.Exception.Message)"
        }

        # E_FAIL alone is not safe to retry: require this process's exact pre-execution factory failure.
        $startupFailure = $logs.Count -eq 1 -and $process.ExitCode -eq -2147467259 -and
            $logs[0].Content -match 'ConfigurationSetProcessorFactoryRemoting\.cpp\(110\).*80004005' -and
            $logs[0].Content -notmatch '(?im)\[(?:CONFIG|CONF)\].*\b(?:unit|Applying|ApplySet|ApplyConfigurationSet|state|progress)\b'
        if (-not $startupFailure -or $attempt -eq 3) {
            throw "$failure No further automatic retry; inspect the verbose WinGet diagnostics."
        }
        $delay = 30 * $attempt
        Write-Warning "$failure Configuration worker initialization failed before unit execution; retrying in $delay seconds."
        Start-Sleep -Seconds $delay
    }
}

if ($FunctionsOnly) { return }

& {
$ErrorActionPreference = 'Stop'
$provisioningStarted = $false
$provisioningLock = $null

trap {
    $failure = $_
    Write-Error -ErrorRecord $failure -ErrorAction Continue
    if (-not $provisioningStarted) { exit 1 }
    try {
        Connect-AzAccount -Identity -Tenant $env:tenantId -Subscription $env:subscriptionId -ErrorAction Stop | Out-Null
        $groupId = "/subscriptions/$env:subscriptionId/resourceGroups/$env:resourceGroup"
        foreach ($target in @($groupId, "$groupId/providers/Microsoft.Compute/virtualMachines/$env:hostVmName")) {
            try {
                Update-AzTag -ResourceId $target -Operation Merge -Tag @{ DeploymentProgress = 'Deployment Failed' } -ErrorAction Stop | Out-Null
            }
            catch { Write-Warning "Could not report failure on '$target': $($_.Exception.Message)" }
        }
    }
    catch { Write-Warning "Could not authenticate to report WinGet failure: $($_.Exception.Message)" }
    exit 1
}

try {
New-Item -Path 'C:\MHBox' -ItemType Directory -Force | Out-Null
$provisioningLock = [IO.File]::Open('C:\MHBox\provisioning.lock', 'OpenOrCreate', 'ReadWrite', 'None')
if (Test-LabReadyMarker) {
    Write-Host 'The baseline is already complete; skipping host configuration.'
    return
}
$provisioningStarted = $true

$Env:MHBoxDir = 'C:\MHBox'
$Env:MHBoxLogsDir = "$Env:MHBoxDir\Logs"

$tenantId = $env:tenantId
$subscriptionId = $env:subscriptionId
$resourceGroup = $env:resourceGroup

$logFilePath = Join-Path -Path $Env:MHBoxLogsDir -ChildPath ('WinGet-provisioning-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.log')

Start-Transcript -Path $logFilePath -Force

$DeploymentProgressString = "Installing WinGet packages..."

Import-LabPSResourceGet
Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId

if ([string]::IsNullOrWhiteSpace($env:hostVmName)) { throw 'The hostVmName machine environment variable is required.' }
$groupId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
foreach ($target in @($groupId, "$groupId/providers/Microsoft.Compute/virtualMachines/$env:hostVmName")) {
    Update-AzTag -ResourceId $target -Operation Merge -Tag @{ DeploymentProgress = $DeploymentProgressString } | Out-Null
}

# The CLI and modules must share the elevated COM transport introduced in 1.29.380.
$winGetVersion = '1.29.380'
if (@(Get-Module -Name Microsoft.WinGet.Client | Where-Object Version -NE ([version]$winGetVersion)).Count -gt 0) {
    throw "Run WinGet.ps1 in a fresh PowerShell 7 process; another WinGet client version is already loaded."
}
Install-LabPSResource -Name Microsoft.WinGet.Client -Version $winGetVersion
Install-LabPSResource -Name Microsoft.WinGet.DSC -Version $winGetVersion
Import-Module -Name Microsoft.WinGet.Client -RequiredVersion $winGetVersion -Force

# Install DSC resources required for MHBox
Install-LabPSResource -Name HyperVDsc -Version '4.0.0-preview0006'
Install-LabPSResource -Name NetworkingDsc -Version '9.1.0'

# Repeat repair for WinAppSDK registration; fresh installs require the v-prefixed GitHub release tag.
$winGetReleaseTag = "v$winGetVersion"
foreach ($repairPass in 1..2) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Repair-WinGetPackageManager -AllUsers -Force -Version $winGetReleaseTag -Verbose -ErrorAction Stop
            break
        }
        catch {
            $statusCode = ''
            for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
                $statusCode = [string]$exception.StatusCode
                if (-not $statusCode) { $statusCode = [string]$exception.Response.StatusCode }
                if ($statusCode) { break }
            }
            # Some module errors preserve only HttpClient's status message.
            if (-not $statusCode -and $_.Exception.Message -match 'Response status code does not indicate success:\s*(\d{3})\b') {
                $statusCode = $Matches[1]
            }
            $transient = $statusCode -match '^(408|429|500|502|503|504|RequestTimeout|TooManyRequests|InternalServerError|BadGateway|ServiceUnavailable|GatewayTimeout)$'
            if (-not $transient -or $attempt -eq 3) { throw }
            $retryDelay = 30 * $attempt
            Write-Warning "WinGet repair pass $repairPass, attempt $attempt/3 failed with HTTP $statusCode. Retrying in $retryDelay seconds."
            Start-Sleep -Seconds $retryDelay
        }
    }
}
$actualWinGetVersion = (winget --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $actualWinGetVersion -ne $winGetReleaseTag) {
    throw "Expected WinGet $winGetReleaseTag; found '$actualWinGetVersion' (exit code $LASTEXITCODE)."
}
Get-WinGetPackage | Out-Null

# Apply WinGet Configuration files
Invoke-LabVMConfiguration -FilePath 'C:\MHBox\DSC\common.dsc.yml'
Invoke-LabVMConfiguration -FilePath 'C:\MHBox\DSC\itpro.dsc.yml'

# Start remaining logon scripts
# Release the cross-stage lock before launching the guest task; retain the trigger if launch fails.
$provisioningLock.Dispose()
$provisioningLock = $null
Start-ScheduledTask -TaskName 'MHServersLogonScript' -ErrorAction Stop
$provisioningStarted = $false
try { Unregister-ScheduledTask -TaskName 'WinGetLogonScript' -Confirm:$false -ErrorAction Stop }
catch { Write-Warning "Guest provisioning started, but removing the old logon trigger failed: $($_.Exception.Message)" }
Stop-Transcript
}
finally {
    if ($null -ne $provisioningLock) { $provisioningLock.Dispose() }
}
}