<#
Installs the newest Glasses Solver build on your iPhone with iloader, no clicking.

  powershell -ExecutionPolicy Bypass -File tools\install.ps1

1. Downloads the newest .ipa from GitHub Actions. Artifacts expire after 3 days, so if the last one is gone it
   starts a fresh build and waits (about 7 minutes).
2. Opens iloader (2.3.10, %LOCALAPPDATA%\iloader) and waits until your Apple ID is logged in and the iPhone is
   connected by USB. Log in yourself if asked; tick Save Credentials so next time needs nothing.
3. Clicks Import IPA, fills the file dialog through Win32 messages (keystrokes don't reach a dialog another
   program opened), confirms it, and waits for "Operation completed".

Works for any app built the same way: pass -Repo, -Artifact and -Ipa.
#>
param(
  [string]$Repo = "WiseOnion/glasses-solver",
  [string]$Workflow = "Build unsigned IPA",
  [string]$Artifact = "GlassesSolver-unsigned-ipa",
  [string]$Ipa = "GlassesSolver-unsigned.ipa",
  [string]$OutDir = "$env:USERPROFILE\Downloads\GlassesSolver-ipa"
)
# No $ErrorActionPreference = "Stop": Windows PowerShell 5.1 turns harmless stderr from gh into fatal errors.
# Failures are checked by exit code below instead.

# --- 1. Newest build -------------------------------------------------------------------------------------------
New-Item -ItemType Directory -Force $OutDir | Out-Null
$target = Join-Path $OutDir $Ipa
$tmp = Join-Path $env:TEMP ("ipa-" + [guid]::NewGuid())
$run = gh run list -R $Repo --workflow $Workflow --branch main --status success --limit 1 --json databaseId -q ".[0].databaseId"
if (-not $run) { throw "No successful '$Workflow' run on main in $Repo. Is gh logged in (gh auth status)?" }
Write-Host "Downloading the build from run $run..."
gh run download $run -R $Repo -n $Artifact -D $tmp 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "That build has expired. Starting a new one (about 7 minutes)..."
  gh workflow run $Workflow -R $Repo --ref main
  Start-Sleep 15
  $run = gh run list -R $Repo --workflow $Workflow --branch main --limit 1 --json databaseId -q ".[0].databaseId"
  gh run watch $run -R $Repo --exit-status --interval 20 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "The build failed: gh run view $run -R $Repo --log-failed" }
  gh run download $run -R $Repo -n $Artifact -D $tmp
  if ($LASTEXITCODE -ne 0) { throw "Couldn't download the new build." }
}
Move-Item -Force (Join-Path $tmp $Ipa) $target
Remove-Item -Recurse -Force $tmp
Write-Host "Saved $target"

# --- 2. iloader, logged in, phone connected -------------------------------------------------------------------
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, string l);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
$A = [System.Windows.Automation.AutomationElement]
function Cond($prop, $value) { New-Object System.Windows.Automation.PropertyCondition($prop, $value) }

Get-Process sideloadly* -ErrorAction SilentlyContinue | Stop-Process -Force   # both want the USB link
$proc = Get-Process iloader -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $proc) {
  Start-Process "$env:LOCALAPPDATA\iloader\iloader.exe"
  for ($i = 0; $i -lt 30 -and -not $proc; $i++) {
    Start-Sleep 1
    $proc = Get-Process iloader -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
  }
}
if (-not $proc) { throw "iloader didn't open. Is it installed at $env:LOCALAPPDATA\iloader?" }
$root = $A::FromHandle($proc.MainWindowHandle)
function Texts { ($root.FindAll("Descendants", [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object { $_.Current.Name }) -join "|" }

# Keep 2.3.10: it's the version that signs in past Apple's Oct 2026 sideloading block.
$no = $root.FindFirst("Descendants", (Cond $A::NameProperty "No"))
if ($no -and (Texts) -match "new version is available") { $no.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }

$asked = $false
for ($i = 0; $i -lt 180; $i++) {
  $t = Texts
  if ($t -match "LOGGED IN AS" -and $t -match "Active: ") { break }
  if (-not $asked) { Write-Host "Waiting: log in to your Apple ID in iloader and connect the iPhone by USB (unlock it, tap Trust)."; $asked = $true }
  Start-Sleep 1
}
if ((Texts) -notmatch "LOGGED IN AS") { throw "Not logged in to iloader after 3 minutes." }

# --- 3. Import IPA ----------------------------------------------------------------------------------------------
# Clear the last install's result, so it isn't read as this one's.
$dismiss = $root.FindFirst("Descendants", (Cond $A::NameProperty "Dismiss"))
if ($dismiss) { $dismiss.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); Start-Sleep 1 }
$before = ([regex]::Matches((Texts), "Operation completed")).Count
$root.FindFirst("Descendants", (Cond $A::NameProperty "Import IPA")).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
$dlg = $null
for ($i = 0; $i -lt 40 -and -not $dlg; $i++) {
  Start-Sleep -Milliseconds 250
  $dlg = $A::RootElement.FindFirst("Descendants", (New-Object System.Windows.Automation.AndCondition((Cond $A::ClassNameProperty "#32770"), (Cond $A::ProcessIdProperty $proc.Id))))
}
if (-not $dlg) { throw "The file dialog didn't open." }
$edit = $dlg.FindAll("Descendants", [System.Windows.Automation.Condition]::TrueCondition) |
  Where-Object { $_.Current.AutomationId -eq "1148" -and $_.Current.ClassName -eq "Edit" } | Select-Object -First 1
[Win]::SendMessage([IntPtr]$edit.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $target) | Out-Null   # WM_SETTEXT
[Win]::PostMessage([IntPtr]$dlg.Current.NativeWindowHandle, 0x0111, [IntPtr]1, [IntPtr]::Zero) | Out-Null  # WM_COMMAND IDOK = Open
Write-Host "Installing..."

for ($i = 0; $i -lt 300; $i++) {
  Start-Sleep 1
  $t = Texts
  if (([regex]::Matches($t, "Operation completed")).Count -gt $before) {
    Write-Host "Installed. On the iPhone, if it won't open: Settings > General > VPN & Device Management > your Apple ID > Trust."
    exit 0
  }
  if ($t -match "Operation failed") {
    $why = ($t -split "\|") | Where-Object { $_ -match "error|fail|HTTP|not found" } | Select-Object -First 3
    throw "iloader: $($why -join ' / ')"
  }
}
throw "No result from iloader after 5 minutes. Check its window."
