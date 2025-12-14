<#
post_install.ps1

Параметри:
  -AutoInstallPython   : switch - автоматично скачати та встановити Python (версію з -PythonVersion)
  -PythonVersion <ver> : string - наприклад "3.11.4"
  -InstallDeps         : switch - виконати pip install -r requirements.txt
  -InstallService      : switch - створити Windows Service через nssm
  -RunNow              : switch - запустити сервер одразу
  -ServiceName <name>  : string - ім'я сервісу
  -NssmPath <path>     : string - шлях до nssm.exe
  -AcadSdkPath <path>  : string - (опціонально) шлях для ACAD_SDK_PATH
  -MsBuildPath <path>  : string - (опціонально) шлях для MSBUILD_PATH

Примітки:
- Скрипт запускається інсталятором з правами admin (інсталятор Inno мав PrivilegesRequired=admin).
- Якщо Python не знайдено, скрипт повідомить користувача і завершиться.
- nssm.exe має бути доступним (включений в інсталятор або вже встановлений).
- Логи пишуться у {app}\install_log.txt
#>

param(
  [switch]$AutoInstallPython,
  [string]$PythonVersion = "3.11.4",
  [switch]$InstallDeps,
  [switch]$InstallService,
  [switch]$RunNow,
  [string]$ServiceName = "AutoCadControllerServer",
  [string]$NssmPath = "",
  [string]$AcadSdkPath = "",
  [string]$MsBuildPath = ""
)

function Write-Log {
  param([string]$msg)
  $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
  $global:LogBuffer += "$timestamp`t$msg`n"
  Write-Output $msg
}

function Flush-Log {
  param([string]$path)
  $global:LogBuffer | Out-File -FilePath $path -Encoding UTF8 -Append
}

try {
  $global:LogBuffer = @()
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
  $appDir = $scriptDir
  $serverDir = Join-Path $appDir "server"
  $logPath = Join-Path $appDir "install_log.txt"

  Write-Log "Post-install started."
  Write-Log "AppDir: $appDir"
  Write-Log "ServerDir: $serverDir"

  # Helper: check internet connectivity quickly
  try {
    $null = Invoke-WebRequest -Uri "https://www.python.org" -UseBasicParsing -Method Head -TimeoutSec 10
    Write-Log "Internet connectivity: OK"
  } catch {
    Write-Log "Internet connectivity: FAILED ($_)"
  }

  # 1) Optionally auto-install Python
  $pythonCmd = $null
  $pyCmd = Get-Command python -ErrorAction SilentlyContinue
  if ($pyCmd) { $pythonCmd = $pyCmd.Path }
  else {
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) { $pythonCmd = $pyLauncher.Path }
  }

  if ($AutoInstallPython) {
    if ($pythonCmd) {
      Write-Log "Python already present at $pythonCmd - skipping auto-install."
    } else {
      Write-Log "Downloading Python $PythonVersion ..."
      $fileName = "python-$PythonVersion-amd64.exe"
      $downloadUrl = "https://www.python.org/ftp/python/$PythonVersion/$fileName"
      $tempInstaller = Join-Path $env:TEMP $fileName

      Write-Log "Download URL: $downloadUrl"
      try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempInstaller -UseBasicParsing -TimeoutSec 300
        Write-Log "Downloaded to $tempInstaller"
      } catch {
        Write-Log "Failed to download Python installer: $_"
        throw "Failed to download Python installer from $downloadUrl"
      }

      # Silent install args - Install for all users, add to PATH, include pip
      $installArgs = '/quiet InstallAllUsers=1 PrependPath=1 Include_pip=1'
      Write-Log "Running Python installer: $tempInstaller $installArgs"
      $proc = Start-Process -FilePath $tempInstaller -ArgumentList $installArgs -Wait -PassThru -NoNewWindow
      Write-Log "Python installer exit code: $($proc.ExitCode)"
      if ($proc.ExitCode -ne 0) {
        Write-Log "Python installer failed with exit code $($proc.ExitCode)"
        throw "Python installer failed"
      }

      # Refresh environment: try to locate python after install
      Start-Sleep -Seconds 2
      $pyCmd = Get-Command python -ErrorAction SilentlyContinue
      if ($pyCmd) { $pythonCmd = $pyCmd.Path; Write-Log "Python located at $pythonCmd" }
      else {
        # try using py launcher
        $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
        if ($pyLauncher) { $pythonCmd = $pyLauncher.Path; Write-Log "Python launcher located at $pythonCmd" }
      }

      if (-not $pythonCmd) {
        Write-Log "Python installation finished but python executable not found in PATH. Manual PATH update may be required."
        throw "Python installation completed but python not found in PATH"
      }
    }
  } else {
    if ($pythonCmd) { Write-Log "Python found: $pythonCmd" } else { Write-Log "Python not found and auto-install not selected." }
  }

  # 2) After ensuring python, install pip deps
  if ($InstallDeps) {
    if (-not $pythonCmd) {
      Write-Log "Cannot install dependencies: python not found."
      throw "Python not available for pip install"
    }
    $reqFile = Join-Path $serverDir "requirements.txt"
    if (-not (Test-Path $reqFile)) {
      Write-Log "requirements.txt not found at $reqFile"
    } else {
      Write-Log "Upgrading pip..."
      & $pythonCmd -m pip install --upgrade pip 2>&1 | ForEach-Object { Write-Log $_ }
      Write-Log "Installing requirements from $reqFile ..."
      & $pythonCmd -m pip install -r $reqFile 2>&1 | ForEach-Object { Write-Log $_ }
      Write-Log "Pip install finished."
    }
  }

  # 3) Set environment variables if provided
  if ($AcadSdkPath -and $AcadSdkPath.Trim() -ne "") {
    try {
      [System.Environment]::SetEnvironmentVariable("ACAD_SDK_PATH", $AcadSdkPath, "Machine")
      Write-Log "Set ACAD_SDK_PATH = $AcadSdkPath (Machine)"
    } catch {
      Write-Log "Failed to set ACAD_SDK_PATH: $_"
    }
  }
  if ($MsBuildPath -and $MsBuildPath.Trim() -ne "") {
    try {
      [System.Environment]::SetEnvironmentVariable("MSBUILD_PATH", $MsBuildPath, "Machine")
      Write-Log "Set MSBUILD_PATH = $MsBuildPath (Machine)"
    } catch {
      Write-Log "Failed to set MSBUILD_PATH: $_"
    }
  }

  # 4) Install service via nssm if requested
  if ($InstallService) {
    Write-Log "Installing service via nssm..."
    $nssmExe = $null
    if ($NssmPath -and (Test-Path $NssmPath)) { $nssmExe = $NssmPath }
    else {
      $cand = Join-Path $appDir "nssm\nssm.exe"
      if (Test-Path $cand) { $nssmExe = $cand }
    }

    if (-not $nssmExe) {
      Write-Log "nssm.exe not found. Please include nssm.exe in the installer or install nssm on the system."
      throw "nssm.exe not found"
    }
    Write-Log "Using nssm: $nssmExe"

    if (-not $pythonCmd) {
      $pyCmdTry = Get-Command python -ErrorAction SilentlyContinue
      if ($pyCmdTry) { $pythonCmd = $pyCmdTry.Path; Write-Log "Located python at $pythonCmd" }
    }

    if (-not $pythonCmd) {
      Write-Log "Cannot create service: python not found"
      throw "python not found for service creation"
    }

    $arguments = "-m uvicorn main:app --host 127.0.0.1 --port 5000"
    Write-Log "Running nssm to install service: $ServiceName"
    $proc = Start-Process -FilePath $nssmExe -ArgumentList "install", $ServiceName, $pythonCmd, $arguments -NoNewWindow -Wait -PassThru
    Write-Log "nssm install exit code: $($proc.ExitCode)"

    # Set working directory for service
    Start-Process -FilePath $nssmExe -ArgumentList "set", $ServiceName, "AppDirectory", $serverDir -NoNewWindow -Wait -ErrorAction SilentlyContinue
    # Redirect stdout/stderr to files (optional)
    $outLog = Join-Path $appDir "server_out.log"
    $errLog = Join-Path $appDir "server_err.log"
    Start-Process -FilePath $nssmExe -ArgumentList "set", $ServiceName, "AppStdout", $outLog -NoNewWindow -Wait -ErrorAction SilentlyContinue
    Start-Process -FilePath $nssmExe -ArgumentList "set", $ServiceName, "AppStderr", $errLog -NoNewWindow -Wait -ErrorAction SilentlyContinue

    # Start service
    Write-Log "Starting service $ServiceName"
    Start-Process -FilePath $nssmExe -ArgumentList "start", $ServiceName -NoNewWindow -Wait -ErrorAction SilentlyContinue
    Write-Log "nssm start attempted."
  }

  # 5) Run server now if requested
  if ($RunNow) {
    if (-not $pythonCmd) {
      Write-Log "Cannot run server now: python not found"
      throw "python not found"
    }
    Write-Log "Starting server (uvicorn) now as background process..."
    $startInfo = @{
      FilePath = $pythonCmd;
      ArgumentList = "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", "5000";
      WorkingDirectory = $serverDir;
      WindowStyle = "Hidden";
    }
    try {
      $proc = Start-Process @startInfo -PassThru
      Write-Log "Started server process Id: $($proc.Id)"
    } catch {
      Write-Log "Failed to start server process: $_"
    }
  }

  Write-Log "Post-install finished successfully."
  Flush-Log $logPath
  exit 0
}
catch {
  Write-Log "ERROR: $_"
  Flush-Log $logPath
  exit 1
}
