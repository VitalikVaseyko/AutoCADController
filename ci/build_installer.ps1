<#
build_installer.ps1

Автоматично збирає інсталятор за Inno Setup script (ci\AutoCadControllerInstaller.iss),
опціонально автоматично завантажує nssm з вебу, копіює його у repo, компілює інсталятор,
та за бажанням підписує результат (.pfx або base64 from env).

Додано опцію автоматичного завантаження nssm:
  -AutoDownloadNssm    : switch - завантажити nssm з вебу, розпакувати і помістити у ci\nssm\win64\nssm.exe
  -NssmVersion         : версія nssm для побудови URL (default: 2.24)
  -NssmDownloadUrl     : явний URL для завантаження zip (перевизначає NssmVersion)
  -NssmSha256          : (optional) очікуваний SHA256 хеш zip-файлу для перевірки

Інші параметри та приклади використання — див. вгорі скрипта / help.

#>

param(
  [string]$InnoCompilerPath = "",
  [string]$InnoScriptPath = "$(Split-Path -Parent $MyInvocation.MyCommand.Definition)\AutoCadControllerInstaller.iss",
  [string]$OutputDir = "$(Resolve-Path .)\dist",
  [switch]$Force,
  [switch]$AutoDownloadNssm,
  [string]$NssmVersion = "2.24",
  [string]$NssmDownloadUrl = "",
  [string]$NssmSha256 = "",
  [switch]$Sign,
  [string]$PfxPath = "",
  [pscredential]$PfxCredential = $null,
  [string]$PfxBase64EnvVar = "",
  [string]$PfxPasswordEnvVar = "",
  [string]$SigntoolPath = "",
  [string]$TimestampUrl = "http://timestamp.digicert.com",
  [switch]$Verbose
)

function Write-Log { param($m) $t = (Get-Date).ToString("s"); Write-Host "[$t] $m" }

# Helpers (same as previous script, omitted comments for brevity)
function Resolve-InnoCompiler {
  param($hint)
  if ($hint -and (Test-Path $hint)) { return (Resolve-Path $hint).ProviderPath }
  $candidates = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "ISCC.exe"
  )
  foreach ($c in $candidates) {
    try { $p = Get-Command $c -ErrorAction SilentlyContinue; if ($p) { return $p.Path } elseif (Test-Path $c) { return (Resolve-Path $c).ProviderPath } } catch {}
  }
  return $null
}

function Resolve-Signtool {
  param($hint)
  if ($hint -and (Test-Path $hint)) { return (Resolve-Path $hint).ProviderPath }
  $candidates = @(
    "signtool.exe",
    "C:\Program Files (x86)\Windows Kits\10\App Certification Kit\signtool.exe",
    "C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe"
  )
  foreach ($c in $candidates) {
    try { $p = Get-Command $c -ErrorAction SilentlyContinue; if ($p) { return $p.Path } elseif (Test-Path $c) { return (Resolve-Path $c).ProviderPath } } catch {}
  }
  $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
  if (Test-Path $vswhere) {
    try {
      $vsPath = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath 2>$null
      if ($vsPath) {
        $candidate2 = Join-Path $vsPath "VC\Tools\MSVC"
        if (Test-Path $candidate2) {
          $st = Get-ChildItem -Path $candidate2 -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($st) { return $st.FullName }
        }
      }
    } catch {}
  }
  return $null
}

function Run-Process($exe, $args, $workdir = $null) {
  Write-Log "Running: $exe $args"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = $args
  if ($workdir) { $psi.WorkingDirectory = $workdir }
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $proc.Start() | Out-Null
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  if ($Verbose) { if ($stdout) { Write-Host $stdout }; if ($stderr) { Write-Host $stderr } }
  return @{ ExitCode = $proc.ExitCode; StdOut = $stdout; StdErr = $stderr }
}

function Decode-PfxFromEnv($envVarName, $outPath) {
  $b64 = [Environment]::GetEnvironmentVariable($envVarName)
  if (-not $b64) { throw "Environment variable '$envVarName' not found or empty." }
  try { [IO.File]::WriteAllBytes($outPath, [Convert]::FromBase64String($b64)) } catch { throw "Failed to decode base64 PFX: $_" }
}

# nssm download helper
function Download-And-Extract-Nssm {
  param(
    [string]$DownloadUrl,
    [string]$DestExePath,
    [string]$ExpectedSha256 = ""
  )

  $tmpDir = Join-Path $env:TEMP ("nssm_download_{0}" -f ([System.Guid]::NewGuid().ToString()))
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  try {
    $zipPath = Join-Path $tmpDir "nssm.zip"
    Write-Log "Downloading nssm from $DownloadUrl ..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
    Write-Log "Downloaded to $zipPath"

    if ($ExpectedSha256 -and $ExpectedSha256.Trim() -ne "") {
      Write-Log "Verifying SHA256..."
      $hash = Get-FileHash -Algorithm SHA256 -Path $zipPath
      if ($hash.Hash.ToLower() -ne $ExpectedSha256.ToLower()) {
        throw "SHA256 mismatch for downloaded nssm. Expected: $ExpectedSha256, got: $($hash.Hash)"
      }
      Write-Log "SHA256 verification passed."
    }

    Write-Log "Extracting archive..."
    Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpDir -Force

    # Try to find win64\nssm.exe or bin\win64\nssm.exe
    $candidate = Get-ChildItem -Path $tmpDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName.ToLower().Contains("win64") } | Select-Object -First 1
    if (-not $candidate) {
      # fallback to any nssm.exe
      $candidate = Get-ChildItem -Path $tmpDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $candidate) { throw "nssm.exe not found inside downloaded archive." }

    Write-Log "Found nssm.exe at $($candidate.FullName). Copying to $DestExePath"
    $destDir = Split-Path -Parent $DestExePath
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -Path $candidate.FullName -Destination $DestExePath -Force

    Write-Log "nssm extracted and copied."
  } finally {
    try { Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue } catch {}
  }
}

# Start main
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $scriptRoot

try {
  Write-Log "Installer build started."

  # Resolve Inno script path
  $InnoScriptPath = if ($InnoScriptPath) { (Resolve-Path $InnoScriptPath).ProviderPath } else { Join-Path $scriptRoot "ci\AutoCadControllerInstaller.iss" }
  if (-not (Test-Path $InnoScriptPath)) { throw "Inno script not found: $InnoScriptPath" }
  Write-Log "Using Inno script: $InnoScriptPath"

  # Auto-download nssm if requested
  if ($AutoDownloadNssm) {
    Write-Log "AutoDownloadNssm enabled."

    # Default download URL if not provided
    if (-not $NssmDownloadUrl -or $NssmDownloadUrl.Trim() -eq "") {
      # Official generic release archive pattern; change if needed
      $NssmDownloadUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
      Write-Log "Using default nssm URL: $NssmDownloadUrl"
    } else {
      Write-Log "Using provided NssmDownloadUrl: $NssmDownloadUrl"
    }

    $destNssmExe = Join-Path $scriptRoot "ci\nssm\win64\nssm.exe"
    Download-And-Extract-Nssm -DownloadUrl $NssmDownloadUrl -DestExePath $destNssmExe -ExpectedSha256 $NssmSha256
  } else {
    Write-Log "AutoDownloadNssm not requested. Skipping."
  }

  # Resolve Inno Compiler
  $Inno = Resolve-InnoCompiler $InnoCompilerPath
  if (-not $Inno) { throw "ISCC.exe (Inno Setup Compiler) not found. Provide -InnoCompilerPath or install Inno Setup." }
  Write-Log "Found Inno compiler: $Inno"

  # Prepare output dir
  if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
  $OutputDir = (Resolve-Path $OutputDir).ProviderPath
  Write-Log "OutputDir: $OutputDir"

  # Compile installer
  $isccArgs = '"' + $InnoScriptPath + '"'
  $res = Run-Process $Inno $isccArgs $scriptRoot
  if ($res.ExitCode -ne 0) { throw "Inno compiler failed: $($res.ExitCode)`n$($res.StdErr)" }
  Write-Log "Inno compilation finished."

  # Locate produced exe
  $produced = Join-Path $scriptRoot "AutoCadController_Installer.exe"
  if (-not (Test-Path $produced)) {
    $found = Get-ChildItem -Path $scriptRoot -Filter "AutoCadController_Installer*.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $produced = $found.FullName } else { throw "Installer .exe not found after Inno compilation." }
  }
  $destExe = Join-Path $OutputDir (Split-Path $produced -Leaf)
  if ((Test-Path $destExe) -and (-not $Force)) { throw "Destination $destExe exists. Use -Force to overwrite." }
  Copy-Item -Path $produced -Destination $destExe -Force
  Write-Log "Installer copied to $destExe"

  # Signing (reuse prior logic)
  if ($Sign) {
    Write-Log "Signing requested."

    # prepare pfx file path
    $tempPfx = $null
    if ($PfxPath -and (Test-Path $PfxPath)) {
      $tempPfx = (Resolve-Path $PfxPath).ProviderPath
      Write-Log "Using PFX at $tempPfx"
    } elseif ($PfxBase64EnvVar) {
      $tempPfx = Join-Path $env:TEMP ("autocad_pfx_{0}.pfx" -f ([System.Guid]::NewGuid().ToString()))
      Decode-PfxFromEnv $PfxBase64EnvVar $tempPfx
      Write-Log "Decoded PFX from env var $PfxBase64EnvVar to $tempPfx"
    } else {
      throw "Signing requested but no PFX provided (-PfxPath or -PfxBase64EnvVar)."
    }

    # password
    $pfxPassPlain = $null
    if ($PfxCredential) {
      $pfxPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxCredential.Password))
    } elseif ($PfxPasswordEnvVar) {
      $pfxPassPlain = [Environment]::GetEnvironmentVariable($PfxPasswordEnvVar)
    } else {
      $secure = Read-Host -AsSecureString "Enter PFX password (leave empty if none)"
      if ($secure) { $pfxPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)) } else { $pfxPassPlain = "" }
    }

    $signtool = Resolve-Signtool $SigntoolPath
    if (-not $signtool) { throw "signtool.exe not found. Provide -SigntoolPath or install Windows SDK." }
    Write-Log "Using signtool: $signtool"

    $signArgs = "/fd SHA256 /f `"$tempPfx`" "
    if ($pfxPassPlain -and $pfxPassPlain.Trim() -ne "") { $signArgs += "/p `"$pfxPassPlain`" " }
    $signArgs += "/tr `"$TimestampUrl`" /td SHA256 /v `"$destExe`""
    $signRes = Run-Process $signtool $signArgs
    if ($signRes.ExitCode -ne 0) { throw "signtool failed: $($signRes.ExitCode)`n$($signRes.StdErr)" }
    Write-Log "Signing completed."

    if ($PfxBase64EnvVar -and (Test-Path $tempPfx)) { Remove-Item -Force $tempPfx -ErrorAction SilentlyContinue; Write-Log "Removed temporary PFX." }
  }

  Write-Log "Build finished. Artifact: $destExe"
  exit 0
}
catch {
  Write-Log "ERROR: $_"
  exit 1
}
