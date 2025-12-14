<#
create_zip.ps1

Створює ZIP архів з поточного репозиторію (без .git).
Опціонально автозавантажує nssm (за відсутності) і кладе його в ci\nssm\win64\nssm.exe перед упаковкою.

Usage examples:
  # просте створення архіву
  powershell -ExecutionPolicy Bypass -File .\ci\create_zip.ps1

  # вказати інше ім'я архіву
  powershell -ExecutionPolicy Bypass -File .\ci\create_zip.ps1 -ZipName "AutoCADController.zip"

  # явно вказати автозавантаження nssm (за замовчуванням - включено)
  powershell -ExecutionPolicy Bypass -File .\ci\create_zip.ps1 -IncludeNssm:$true

Параметри:
  -ZipName         : ім'я вихідного zip-файлу (default: AutoCADController.zip)
  -IncludeNssm     : switch (default: $true) - якщо true і nssm.exe відсутній — скачати з nssm.cc
  -NssmVersion     : версія nssm для скачування (default: 2.24)
  -NssmDownloadUrl : явний URL для скачування zip nssm (перевизначає NssmVersion)
  -Verbose         : додатковий лог

Примітки:
- Запускайте з кореня репозиторію.
- Потрібен інтернет для автозавантаження nssm.
- Скрипт виключає папку .git та файл архіву з упаковки.
#>

param(
  [string]$ZipName = "AutoCADController.zip",
  [switch]$IncludeNssm = $true,
  [string]$NssmVersion = "2.24",
  [string]$NssmDownloadUrl = "",
  [switch]$Verbose
)

function Log { param($m) if ($Verbose) { Write-Host $m } }

try {
  $repoRoot = (Get-Location).ProviderPath
  Log "Repo root: $repoRoot"

  # Ensure ci folder exists
  $ciDir = Join-Path $repoRoot "ci"
  if (-not (Test-Path $ciDir)) { New-Item -ItemType Directory -Path $ciDir | Out-Null }

  # Ensure nssm if requested
  $nssmTarget = Join-Path $ciDir "nssm\win64\nssm.exe"
  if ($IncludeNssm) {
    if (Test-Path $nssmTarget) {
      Log "nssm already present at $nssmTarget"
    } else {
      Log "nssm not found at $nssmTarget. Will download..."
      if (-not $NssmDownloadUrl -or $NssmDownloadUrl.Trim() -eq "") {
        $NssmDownloadUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
      }
      Log "Downloading nssm from $NssmDownloadUrl ..."
      $tmp = Join-Path $env:TEMP ("nssm_download_{0}.zip" -f ([guid]::NewGuid().ToString()))
      Invoke-WebRequest -Uri $NssmDownloadUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 300
      Log "Downloaded to $tmp"

      # extract and find win64\nssm.exe
      $extractDir = Join-Path $env:TEMP ("nssm_extract_{0}" -f ([guid]::NewGuid().ToString()))
      New-Item -ItemType Directory -Path $extractDir | Out-Null
      Expand-Archive -LiteralPath $tmp -DestinationPath $extractDir -Force

      $candidate = Get-ChildItem -Path $extractDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName.ToLower().Contains("win64") } | Select-Object -First 1
      if (-not $candidate) {
        $candidate = Get-ChildItem -Path $extractDir -Filter nssm.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
      }
      if (-not $candidate) {
        Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        throw "nssm.exe not found inside downloaded archive."
      }

      # copy to target
      $destDir = Split-Path -Parent $nssmTarget
      if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      Copy-Item -Path $candidate.FullName -Destination $nssmTarget -Force
      Log "Copied nssm.exe to $nssmTarget"

      # cleanup
      Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
      Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
  } else {
    Log "IncludeNssm not requested; skipping nssm download."
  }

  # Prepare staging dir
  $timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
  $staging = Join-Path $env:TEMP ("AutoCadController_staging_$timestamp")
  if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $staging | Out-Null
  Log "Created staging: $staging"

  # Gather files excluding .git and target zip if exists
  Log "Collecting files..."
  $allFiles = Get-ChildItem -Path $repoRoot -Recurse -File -Force |
              Where-Object {
                ($_.FullName -notmatch [regex]::Escape((Join-Path $repoRoot ".git"))) -and
                ($_.FullName -notmatch [regex]::Escape((Join-Path $repoRoot $ZipName)))
              }

  foreach ($f in $allFiles) {
    # compute relative path
    $rel = $f.FullName.Substring($repoRoot.Length).TrimStart('\','/')
    $destFull = Join-Path $staging $rel
    $destDir = Split-Path -Parent $destFull
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $destFull -Force
  }

  Log "All files copied to staging."

  # Create zip in repo root (overwrite if exists)
  $zipPath = Join-Path $repoRoot $ZipName
  if (Test-Path $zipPath) { Remove-Item -Force $zipPath -ErrorAction SilentlyContinue }
  Log "Creating zip: $zipPath ..."
  Compress-Archive -Path (Join-Path $staging "*") -DestinationPath $zipPath -Force

  Log "Zip created successfully: $zipPath"

  # cleanup staging
  Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
  Log "Staging removed."

  Write-Host "`nDONE: $zipPath"
}
catch {
  Write-Error "ERROR: $_"
  if (Test-Path $staging) { Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue }
  exit 1
}
