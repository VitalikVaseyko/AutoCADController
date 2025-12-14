# Installer script: copy the bundle to ApplicationPlugins (per-user and all-users)
$bundleName = "AutoCadController.bundle"
$source = Join-Path (Get-Location) "plugin\Autoloader\$bundleName"

$destUser = Join-Path $env:APPDATA "Autodesk\ApplicationPlugins\$bundleName"
$destAll = Join-Path $env:ProgramData "Autodesk\ApplicationPlugins\$bundleName"

Write-Output "Source: $source"
Write-Output "Copying to per-user plugins folder: $destUser"
if (-Not (Test-Path $source)) { Write-Error "Source bundle not found. Build plugin first." ; exit 1 }

# Copy per-user
Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $destUser
Copy-Item -Recurse -Force $source $destUser

Write-Output "Also copying to all-users folder: $destAll"
# Requires admin for ProgramData
Try {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $destAll
    Copy-Item -Recurse -Force $source $destAll
} Catch {
    Write-Warning "Could not copy to all-users folder: $_. You can run PowerShell as admin to install for all users."
}

Write-Output "Installation complete. Restart AutoCAD to load plugin. Use command RECONSTRUCT3D.”
