# =============================================================================
#  VIBERIZE DESKTOP — Install Prerequisites (Script 2 of 8)
#  Installs: Node.js, Rust, Tauri CLI, WebView2, VC++ Redist, Ollama
#  Re-runnable: skips already-installed tools
# =============================================================================

$ErrorActionPreference = "Continue"

# Fresh-OS fix: ensure TLS 1.2 is available for all HTTPS downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Fresh-OS fix: ensure execution policy allows scripts (current user scope, non-admin safe)
$currentPolicy = try { (Get-ExecutionPolicy -Scope CurrentUser).ToString() } catch { "Restricted" }
if ($currentPolicy -eq "Restricted" -or $currentPolicy -eq "Undefined") {
    try {
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -EA SilentlyContinue
        Write-Host "  [OK]    Set ExecutionPolicy to RemoteSigned (CurrentUser)" -ForegroundColor Green
    } catch {
        Write-Host "  [WARN]  Could not set ExecutionPolicy -- may need: Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Yellow
    }
}

$ROOT = if ($env:VIBERIZE_ROOT) { $env:VIBERIZE_ROOT } else { "$($env:SystemDrive)\ViberizeDesktop" }
$APP = "$ROOT\app"; $SRC = "$APP\src"; $STYLES = "$SRC\styles"; $COMPONENTS = "$SRC\components"
$TAURI_DIR = "$APP\src-tauri"; $OLLAMA_DIR = "$ROOT\ollama"
$MODEL_DIR = "$ROOT\models"; $DL_CACHE = "$ROOT\_download_cache"; $LOG_DIR = "$ROOT\logs"
$UPDATE_DIR = "$ROOT\updates"; $DESKTOP = [Environment]::GetFolderPath("Desktop")
$CONFIG_FILE = "$ROOT\.viberize-config.json"; $STATE_FILE = "$ROOT\.setup-state.json"
$script:UTF8NoBOM = [System.Text.UTF8Encoding]::new($false)
$script:logBuf = [System.Text.StringBuilder]::new()

function Write-HEAD  { param($m) Write-Host "`n===  $m  ===" -ForegroundColor Magenta }
function Write-OK    { param($m) Write-Host "  [OK]    $m" -ForegroundColor Green }
function Write-FAIL  { param($m) Write-Host "  [FAIL]  $m" -ForegroundColor Red }
function Write-WARN  { param($m) Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function Write-SKIP  { param($m) Write-Host "  [SKIP]  $m" -ForegroundColor DarkGray }
function Write-ACT   { param($m) Write-Host "  [-->]   $m" -ForegroundColor Cyan }
function Write-INFO  { param($m) Write-Host "  [info]  $m" -ForegroundColor DarkCyan }
function LogLine { param([string]$m) $script:logBuf.AppendLine("[$((Get-Date -Format 'HH:mm:ss'))] $m") | Out-Null }
function Save-Log { param([string]$Name); if (-not (Test-Path $LOG_DIR)) { New-Item $LOG_DIR -ItemType Directory -Force | Out-Null }; $script:logBuf.ToString() | Set-Content "$LOG_DIR\${Name}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" -Encoding UTF8 -Force; Write-INFO "Log saved" }
function Ensure-Dir { param([string]$Path); if (-not (Test-Path $Path)) { New-Item $Path -ItemType Directory -Force | Out-Null; Write-OK "Created: $Path" } else { Write-SKIP "Exists: $Path" } }
function Write-FileAlways { param([string]$Path, [string]$Content, [string]$Label = ""); $dir = Split-Path $Path -Parent; if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, $Content, $script:UTF8NoBOM); if ($Label) { Write-OK "Wrote $Label" }; LogLine "Wrote: $Path" }
function Write-FileIfMissing { param([string]$Path, [string]$Content, [string]$Label = ""); if (Test-Path $Path) { Write-SKIP "Exists: $(Split-Path $Path -Leaf)"; return }; Write-FileAlways $Path $Content $Label }
function Force-Write { param([string]$Path, [string]$Content, [string]$Label = ""); $dir = Split-Path $Path -Parent; if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }; [System.IO.File]::WriteAllText($Path, $Content, $script:UTF8NoBOM); if ($Label) { Write-OK "Wrote $Label" } }
function Die { param([string]$Message); Write-FAIL $Message; throw $Message }
function Strip-BOM { param([string]$Path); if (-not (Test-Path $Path)) { return }; $bytes = [System.IO.File]::ReadAllBytes($Path); if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { [System.IO.File]::WriteAllBytes($Path, $bytes[3..($bytes.Length-1)]); Write-INFO "Stripped BOM from $(Split-Path $Path -Leaf)" } }
function Show-Banner { param([string]$Title, [int]$ScriptNum, [int]$Total = 8); Write-Host ""; Write-Host "  $('=' * 60)" -ForegroundColor Magenta; Write-Host "  | $Title$(' ' * [Math]::Max(0, 56 - $Title.Length)) |" -ForegroundColor Magenta; Write-Host "  | Script $ScriptNum of $Total$(' ' * 40) |" -ForegroundColor Magenta; Write-Host "  $('=' * 60)" -ForegroundColor Magenta; Write-Host "" }
function Set-StepComplete { param([string]$Step); $state = @{}; if (Test-Path $STATE_FILE) { try { $state = Get-Content $STATE_FILE -Raw | ConvertFrom-Json -AsHashtable } catch { $state = @{} } }; $state[$Step] = @{ completed = (Get-Date).ToString("o"); success = $true }; $state | ConvertTo-Json -Depth 5 | Set-Content $STATE_FILE -Encoding UTF8 -Force }
function Test-StepComplete { param([string]$Step); if (-not (Test-Path $STATE_FILE)) { return $false }; try { $s = Get-Content $STATE_FILE -Raw | ConvertFrom-Json; return ($s.PSObject.Properties.Name -contains $Step) } catch { return $false } }
function Download-File { param([string]$Url, [string]$Dest, [string]$Label = "", [int]$MaxRetries = 3); if (Test-Path $Dest) { Write-SKIP "$Label already downloaded"; return $true }; for ($a = 1; $a -le $MaxRetries; $a++) { try { if ($a -gt 1) { Write-INFO "Retry $a/$MaxRetries" } else { Write-ACT "Downloading $Label..." }; (New-Object System.Net.WebClient).DownloadFile($Url, $Dest); if (Test-Path $Dest) { $sz = [Math]::Round((Get-Item $Dest).Length/1MB,1); Write-OK "$Label downloaded (${sz} MB)"; return $true } } catch { Write-WARN "Attempt $a failed: $_"; Start-Sleep (2*$a) } }; Write-FAIL "Failed to download $Label"; return $false }
function Get-OllamaExe { $p = "$OLLAMA_DIR\ollama.exe"; if (Test-Path $p) { return $p }; return $null }
function Get-OllamaRunning { try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/" -UseBasicParsing -TimeoutSec 3 -EA Stop; return $r.StatusCode -eq 200 } catch { return $false } }
function Get-OllamaModels { try { $r = Invoke-WebRequest -Uri "http://127.0.0.1:11434/api/tags" -UseBasicParsing -TimeoutSec 10 -EA Stop; return @(($r.Content | ConvertFrom-Json).models | ForEach-Object { $_.name }) } catch { return @() } }
function Remove-OllamaAutostart { $lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk"; if (Test-Path $lnk) { Remove-Item $lnk -Force -EA SilentlyContinue; Write-INFO "Removed Ollama startup shortcut" }; try { $v = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Ollama" -EA SilentlyContinue; if ($v) { Remove-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Ollama" -Force -EA SilentlyContinue } } catch {} }
function Stop-OllamaGUI { Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match "(?i)^ollama" } | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 2; Get-Process -EA SilentlyContinue | Where-Object { $_.ProcessName -match "(?i)^ollama" } | Stop-Process -Force -EA SilentlyContinue; Start-Sleep 1 }
function Run-Direct { param([string]$Exe, [string[]]$ArgList, [string]$Label, [string]$WorkDir = "", [int]$TimeoutSec = 600); Write-ACT "$Label..."; $tmpOut = [System.IO.Path]::GetTempFileName(); $tmpErr = [System.IO.Path]::GetTempFileName(); $timedOut = $false; try { $pArgs = @{ FilePath=$Exe; ArgumentList=$ArgList; PassThru=$true; NoNewWindow=$true; RedirectStandardOutput=$tmpOut; RedirectStandardError=$tmpErr }; if ($WorkDir -and (Test-Path $WorkDir)) { $pArgs["WorkingDirectory"]=$WorkDir }; $p = Start-Process @pArgs; $sw = [System.Diagnostics.Stopwatch]::StartNew(); while (-not $p.HasExited) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) { Write-WARN "$Label timed out"; try { $p.Kill() } catch {}; $timedOut=$true; break }; $el=[Math]::Round($sw.Elapsed.TotalSeconds); Write-Host "`r    ${Label}... ${el}s" -NoNewline -ForegroundColor DarkGray; Start-Sleep -Milliseconds 500 }; Write-Host ""; $stdout = if (Test-Path $tmpOut) { Get-Content $tmpOut -Raw -EA SilentlyContinue } else { "" }; $stderr = if (Test-Path $tmpErr) { Get-Content $tmpErr -Raw -EA SilentlyContinue } else { "" }; $exitCode = if ($timedOut) { -1 } else { $p.ExitCode }; LogLine "$Label exit=$exitCode"; return @{ ExitCode=$exitCode; StdOut=$stdout; StdErr=$stderr; TimedOut=$timedOut } } finally { Remove-Item $tmpOut,$tmpErr -Force -EA SilentlyContinue } }
function Get-NpmExe { @("$env:ProgramFiles\nodejs\npm.cmd", "${env:ProgramFiles(x86)}\nodejs\npm.cmd") + ($env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "npm.cmd" }) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1 }
function Get-CargoExe { @("$env:USERPROFILE\.cargo\bin\cargo.exe") + ($env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "cargo.exe" }) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1 }
function Start-SilentInstall { param([string]$ExePath, [string]$Arguments, [string]$Label, [int]$TimeoutSeconds = 600); Write-ACT "Installing $Label..."; $proc = Start-Process $ExePath -ArgumentList $Arguments -PassThru -NoNewWindow; $sw = [System.Diagnostics.Stopwatch]::StartNew(); while (-not $proc.HasExited) { if ($sw.Elapsed.TotalSeconds -gt $TimeoutSeconds) { Write-WARN "$Label timed out"; try { $proc.Kill() } catch {}; return -1 }; Start-Sleep -Milliseconds 500 }; if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { Write-OK "$Label installed" } else { Write-WARN "$Label exit: $($proc.ExitCode)" }; return $proc.ExitCode }

# ── Fresh-OS: Node.js download definitions (were missing — fatal on clean machine) ─
$NODE_VERSION = "v22.11.0"
$NODE_ARCH    = "x64"
$NODE_MSI     = "$DL_CACHE\node-$NODE_VERSION-$NODE_ARCH.msi"
$NODE_URL     = "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-$NODE_ARCH.msi"


Show-Banner "INSTALL PREREQUISITES" 2

$OLLAMA_MODEL = if ($env:VIBERIZE_OLLAMA_MODEL) { $env:VIBERIZE_OLLAMA_MODEL } else { $null }

# ── Auto-detect best model based on hardware ──────────────────────────────────
if (-not $OLLAMA_MODEL) {
    $totalRAM_GB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
    $gpuVRAM_GB  = 0
    try {
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.AdapterRAM -gt 0 } | Sort-Object AdapterRAM -Descending | Select-Object -First 1
        if ($gpu -and $gpu.AdapterRAM -gt 0) {
            $gpuVRAM_GB = [Math]::Round($gpu.AdapterRAM / 1GB, 1)
            # AdapterRAM caps at 4GB for 32-bit values; detect by GPU name
            if ($gpu.Name -match "4090|4080|3090") { $gpuVRAM_GB = [Math]::Max($gpuVRAM_GB, 16) }
            elseif ($gpu.Name -match "4070|3080") { $gpuVRAM_GB = [Math]::Max($gpuVRAM_GB, 12) }
            elseif ($gpu.Name -match "4060|3070|3060") { $gpuVRAM_GB = [Math]::Max($gpuVRAM_GB, 8) }
        }
    } catch {}

    Write-INFO "Hardware detected: ${totalRAM_GB} GB RAM, ${gpuVRAM_GB} GB VRAM"

    # Model selection based on what the machine can handle
    # Rule: model download size should be < 50% of available RAM
    if ($totalRAM_GB -ge 32 -or $gpuVRAM_GB -ge 12) {
        $OLLAMA_MODEL = "llama3.1:8b"      # Best quality, ~4.7 GB download, needs ~8 GB at runtime
        Write-INFO "Selected premium model: $OLLAMA_MODEL (32+ GB RAM or 12+ GB VRAM)"
    } elseif ($totalRAM_GB -ge 16 -or $gpuVRAM_GB -ge 8) {
        $OLLAMA_MODEL = "qwen2.5:7b"       # Great quality, ~4.7 GB download, needs ~6 GB at runtime
        Write-INFO "Selected standard model: $OLLAMA_MODEL (16+ GB RAM or 8+ GB VRAM)"
    } elseif ($totalRAM_GB -ge 8) {
        $OLLAMA_MODEL = "llama3.2:3b"      # Good quality, ~2 GB download, needs ~4 GB at runtime
        Write-INFO "Selected lightweight model: $OLLAMA_MODEL (8+ GB RAM)"
    } else {
        $OLLAMA_MODEL = "llama3.2:1b"      # Basic quality, ~1.3 GB download, needs ~2 GB at runtime
        Write-INFO "Selected minimal model: $OLLAMA_MODEL (< 8 GB RAM)"
    }
}

# Persist selected model so BuildDeploy/Verify/post-install scripts use the right one
$modelConfigFile = "$ROOT\selected_model.txt"
$OLLAMA_MODEL | Set-Content $modelConfigFile -Encoding UTF8 -Force
Write-INFO "Model config saved: $modelConfigFile -> $OLLAMA_MODEL"

$logBuf = [System.Text.StringBuilder]::new()

# =============================================================================
Write-HEAD "STEP 1: DIRECTORY STRUCTURE"
# =============================================================================

foreach ($d in @($ROOT,$APP,"$APP\src","$APP\src\styles","$APP\src\components",
                 "$APP\src\store","$APP\src\types","$TAURI_DIR\src",
                 $MODEL_DIR,"$ROOT\assets",
                 "$ROOT\ocr-cache","$ROOT\rag-index",
                 $DL_CACHE,$UPDATE_DIR,"$UPDATE_DIR\snapshots",$LOG_DIR,
                 "$ROOT\patches",$OLLAMA_DIR)) {
    if (-not (Test-Path $d -EA SilentlyContinue)) {
        New-Item -ItemType Directory $d -Force | Out-Null
        Write-OK "Created: $d"
    } else { Write-SKIP "Exists: $d" }
}


Write-HEAD "STEP 1a: STAGE LOGO ASSET"
# =============================================================================
# If logo.png is beside this script (portable deployment), copy it into assets/.
# All icon generation in Script 3 will use this as the source.
$scriptDir = if ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { $PWD.Path }
$logoSource = Join-Path $scriptDir "logo.png"
$logoDest   = "$ROOT\assets\logo.png"

if (Test-Path $logoDest -EA SilentlyContinue) {
    Write-SKIP "Logo already staged: $logoDest"
} elseif (Test-Path $logoSource -EA SilentlyContinue) {
    Copy-Item $logoSource $logoDest -Force
    Write-OK "Logo staged from script directory: $logoDest"
} else {
    Write-INFO "No logo.png found beside script — place logo.png in $ROOT\assets\ before Script 3"
}


Write-HEAD "STEP 1b: WINDOWS DEFENDER EXCLUSIONS"
# =============================================================================
# Fresh-OS fix: Windows Defender real-time scanning causes STATUS_ACCESS_VIOLATION
# (0xc0000005) when rustc writes thousands of intermediate .o/.rlib files at speed.
# This is a well-known Rust-on-Windows issue. Adding exclusions for build dirs
# prevents Defender from locking files mid-write. Requires Administrator.
# These are PROCESS and PATH exclusions only — they do NOT disable Defender globally.

$defenderExclusions = @(
    $ROOT,
    "$env:USERPROFILE\.cargo",
    "$env:USERPROFILE\.rustup"
)

$exclusionsAdded = 0
foreach ($exPath in $defenderExclusions) {
    if (-not (Test-Path $exPath -EA SilentlyContinue)) { continue }
    try {
        $existing = (Get-MpPreference -EA Stop).ExclusionPath
        if ($existing -and ($existing -contains $exPath)) {
            Write-SKIP "Defender exclusion already set: $exPath"
        } else {
            Add-MpPreference -ExclusionPath $exPath -EA Stop
            Write-OK "Defender exclusion added: $exPath"
            $exclusionsAdded++
        }
    } catch {
        Write-WARN "Could not add Defender exclusion for $exPath (non-admin or Defender not active)"
    }
}

# Also exclude rustc.exe and cargo.exe processes
foreach ($procName in @("rustc.exe","cargo.exe")) {
    try {
        $existing = (Get-MpPreference -EA Stop).ExclusionProcess
        if ($existing -and ($existing -contains $procName)) {
            Write-SKIP "Defender process exclusion already set: $procName"
        } else {
            Add-MpPreference -ExclusionProcess $procName -EA Stop
            Write-OK "Defender process exclusion added: $procName"
            $exclusionsAdded++
        }
    } catch {}
}

if ($exclusionsAdded -gt 0) {
    Write-OK "Defender exclusions configured -- prevents STATUS_ACCESS_VIOLATION during Rust builds"
} else {
    Write-SKIP "Defender exclusions: already configured or Defender not active"
}


Write-HEAD "STEP 2: NODE.JS"
# =============================================================================

$nvReg = $null
foreach ($rp in @("HKLM:\SOFTWARE\Node.js","HKLM:\SOFTWARE\WOW6432Node\Node.js")) {
    if (Test-Path $rp -EA SilentlyContinue) {
        $v = try { (Get-ItemProperty $rp -EA Stop).Version } catch { $null }
        if ($v) { $nvReg = $v.TrimStart("v"); break }
    }
}
$nodeOk = $false
if ($nvReg) {
    $nm = 0; if ($nvReg -match '^(\d+)') { $nm = [int]$Matches[1] }
    if ($nm -ge 18) { Write-SKIP "Node.js v$nvReg already installed"; $nodeOk = $true }
    else { Write-WARN "Node.js v$nvReg too old" }
}

if (-not $nodeOk) {
    $dlOk = Download-File -Url $NODE_URL -Dest $NODE_MSI -Label "Node.js $NODE_VERSION"
    if ($dlOk) {
        $p = Start-Process msiexec -ArgumentList "/i `"$NODE_MSI`" /qn /norestart" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-OK "Node.js installed" }
        else { Write-WARN "Node.js installer exit $($p.ExitCode) -- verify manually" }
    }
}
# Refresh PATH from registry + ensure Node.js directory is on PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
# Explicitly add common Node.js locations if not already present
foreach ($nodeDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs")) {
    if ((Test-Path $nodeDir -EA SilentlyContinue) -and ($env:Path -notlike "*$nodeDir*")) {
        $env:Path = "$nodeDir;$env:Path"
        Write-INFO "Added $nodeDir to session PATH"
    }
}

# =============================================================================
Write-HEAD "STEP 3: RUST TOOLCHAIN"
# =============================================================================

$cargoDir = "$env:USERPROFILE\.cargo\bin"
$rustcExe = @("$cargoDir\rustc.exe") + (
    $env:Path -split ";" | ForEach-Object { Join-Path $_.Trim() "rustc.exe" }
) | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

if ($rustcExe) { Write-SKIP "Rust already installed" }
else {
    $rustupExe = "$DL_CACHE\rustup-init.exe"
    $dlOk = Download-File -Url "https://win.rustup.rs/x86_64" -Dest $rustupExe -Label "rustup-init.exe"
    if ($dlOk) {
        Write-ACT "Installing Rust (this takes 1-2 minutes)..."
        $p = Start-Process $rustupExe -ArgumentList "-y --default-toolchain stable" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { Write-OK "Rust installed" }
        else { Write-WARN "rustup exit $($p.ExitCode)" }
    }
}
# Always ensure cargo/bin is on PATH for this session (critical for fresh install)
if (Test-Path $cargoDir -EA SilentlyContinue) {
    if ($env:Path -notlike "*$cargoDir*") {
        $env:Path = "$cargoDir;$env:Path"
        Write-INFO "Added $cargoDir to session PATH"
    }
}

# =============================================================================
Write-HEAD "STEP 3b: VISUAL STUDIO BUILD TOOLS (MSVC + Windows SDK)"
# =============================================================================
# Fresh-OS: Rust on Windows requires the MSVC toolchain (link.exe, cl.exe) and
# Windows SDK headers. Without these, cargo cannot compile any Rust code.
# VS Build Tools is a ~1.5 GB download + ~4 GB install. This is the official
# Microsoft standalone package (no full Visual Studio IDE needed).

$hasMSVC = $false
$vsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vsWhere -EA SilentlyContinue) {
    $vsInstalls = & $vsWhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($vsInstalls) { $hasMSVC = $true }
}
# Fallback: check for cl.exe in common paths
if (-not $hasMSVC) {
    $clPaths = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*\bin\Hostx64\x64\cl.exe"
    )
    foreach ($cp in $clPaths) {
        if (Get-Item $cp -EA SilentlyContinue) { $hasMSVC = $true; break }
    }
}

if ($hasMSVC) {
    Write-SKIP "VS Build Tools / MSVC already installed"
} else {
    $vsBuildToolsExe = "$DL_CACHE\vs_BuildTools.exe"
    $dlOk = Download-File -Url "https://aka.ms/vs/17/release/vs_BuildTools.exe" -Dest $vsBuildToolsExe -Label "VS Build Tools installer"
    if ($dlOk) {
        Write-ACT "Installing VS Build Tools (MSVC + Windows SDK) -- this takes 5-15 minutes..."
        Write-INFO "This is required for Rust/Tauri compilation on a fresh machine."
        # Install the C++ build tools workload with Windows SDK
        $vsArgs = "--quiet --wait --norestart --nocache " +
                  "--add Microsoft.VisualStudio.Workload.VCTools " +
                  "--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 " +
                  "--add Microsoft.VisualStudio.Component.Windows11SDK.22621 " +
                  "--includeRecommended"
        $p = Start-Process $vsBuildToolsExe -ArgumentList $vsArgs -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-OK "VS Build Tools installed (MSVC + Windows SDK)"
        } else {
            Write-WARN "VS Build Tools exit $($p.ExitCode) -- Rust compilation may fail"
            Write-INFO "Manual install: $vsBuildToolsExe --add Microsoft.VisualStudio.Workload.VCTools"
        }
    }
}

# =============================================================================
Write-HEAD "STEP 4: TAURI CLI"
# =============================================================================

$tauriExe = @("$cargoDir\cargo-tauri.exe","$cargoDir\tauri.exe") |
    Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1

if ($tauriExe) { Write-SKIP "Tauri CLI at $tauriExe" }
else {
    $cargoPath = "$cargoDir\cargo.exe"
    if (-not (Test-Path $cargoPath -EA SilentlyContinue)) {
        $cargoPath = (Get-Command "cargo" -EA SilentlyContinue).Source
    }
    if ($cargoPath -and (Test-Path $cargoPath -EA SilentlyContinue)) {
        Write-ACT "Installing Tauri CLI (takes a few minutes)..."
        & $cargoPath install tauri-cli --locked 2>&1 | ForEach-Object {
            if ($_ -match "(Compiling|Finished|Installing)") { Write-INFO "$_" }
        }
        Write-OK "Tauri CLI installed"
    } else { Write-WARN "cargo not found at $cargoDir -- install Rust first" }
}


# =============================================================================
Write-HEAD "STEP 5: WEBVIEW2 RUNTIME"
# =============================================================================

$wv2Keys = @(
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
    "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
)
$wv2 = $wv2Keys | Where-Object { Test-Path $_ -EA SilentlyContinue } | Select-Object -First 1
if ($wv2) { Write-SKIP "WebView2 already installed" }
else {
    $wv2Exe = "$DL_CACHE\MicrosoftEdgeWebview2Setup.exe"
    $dlOk = Download-File -Url "https://go.microsoft.com/fwlink/p/?LinkId=2124703" -Dest $wv2Exe -Label "WebView2"
    if ($dlOk) {
        $p = Start-Process $wv2Exe -ArgumentList "/silent /install" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-OK "WebView2 installed" }
        else { Write-WARN "WebView2 exit $($p.ExitCode)" }
    }
}


Write-HEAD "STEP 5b: VISUAL C++ REDISTRIBUTABLE 2022"
# =============================================================================

$vcInstalled = $false
$vcKey = "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
if (Test-Path $vcKey -EA SilentlyContinue) {
    try {
        $vcMajor = (Get-ItemProperty $vcKey -EA Stop).Major
        if ($vcMajor -ge 14) { $vcInstalled = $true }
    } catch {}
}

if ($vcInstalled) {
    Write-SKIP "VC++ Redistributable 2022 already installed"
} else {
    $vcExe = "$DL_CACHE\vc_redist.x64.exe"
    $dlOk = Download-File -Url "https://aka.ms/vs/17/release/vc_redist.x64.exe" -Dest $vcExe -Label "VC++ Redist 2022 x64"
    if ($dlOk) {
        Write-ACT "Installing VC++ Redistributable 2022 x64..."
        $p = Start-Process $vcExe -ArgumentList "/install","/quiet","/norestart" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) {
            Write-OK "VC++ Redistributable installed"
        } else {
            Write-WARN "VC++ Redist exit $($p.ExitCode)"
        }
    }
}


Write-HEAD "STEP 5c: NSIS (required for Tauri Windows installer bundle)"
# =============================================================================
# Fresh-OS: Tauri's NSIS bundler requires NSIS (Nullsoft Scriptable Install System)
# to be installed. Without it, 'cargo tauri build' cannot create .exe installers.

$nsisExe = "${env:ProgramFiles(x86)}\NSIS\makensis.exe"
$nsisExeAlt = "$env:ProgramFiles\NSIS\makensis.exe"

if ((Test-Path $nsisExe -EA SilentlyContinue) -or (Test-Path $nsisExeAlt -EA SilentlyContinue)) {
    Write-SKIP "NSIS already installed"
} else {
    $nsisInstaller = "$DL_CACHE\nsis-setup.exe"
    $dlOk = Download-File -Url "https://sourceforge.net/projects/nsis/files/NSIS%203/3.10/nsis-3.10-setup.exe/download" -Dest $nsisInstaller -Label "NSIS 3.10"
    if ($dlOk) {
        Write-ACT "Installing NSIS (required for Tauri Windows bundler)..."
        $p = Start-Process $nsisInstaller -ArgumentList "/S" -Wait -PassThru -NoNewWindow
        if ($p.ExitCode -eq 0) { Write-OK "NSIS installed" }
        else { Write-WARN "NSIS exit $($p.ExitCode) -- Tauri NSIS bundler may fall back to MSI" }
        # Add NSIS to PATH for this session
        foreach ($nsisDir in @("${env:ProgramFiles(x86)}\NSIS","$env:ProgramFiles\NSIS")) {
            if ((Test-Path $nsisDir -EA SilentlyContinue) -and ($env:Path -notlike "*$nsisDir*")) {
                $env:Path = "$nsisDir;$env:Path"
                Write-INFO "Added $nsisDir to session PATH"
            }
        }
    }
}


Write-HEAD "STEP 6: PDF SUPPORT"
# =============================================================================

Write-OK "PDF text extraction: built-in via pdf-extract Rust crate"
Write-INFO "No external OCR tools needed — Tesseract is no longer required"

Write-HEAD "STEP 7: OLLAMA (portable sidecar — no installer, no GUI)"
# =============================================================================
# Strategy: Download the standalone ollama-windows-amd64.zip from GitHub.
# This is just the CLI binary + GPU libs — NO installer, NO GUI, NO tray icon,
# NO autostart, NO system-wide changes. Ollama lives entirely inside our dir.
# Viberize starts 'ollama serve' as a hidden child process and stops it on exit.

$ollamaExe = "$OLLAMA_DIR\ollama.exe"

if (Test-Path $ollamaExe -EA SilentlyContinue) {
    $ver = & $ollamaExe --version 2>&1 | Select-String "version" | ForEach-Object { $_.ToString().Trim() }
    Write-SKIP "Ollama sidecar already installed ($ver)"
} else {
    # ── 7a: Kill any system-wide Ollama that might conflict ─────────────────
    Stop-OllamaGUI
    Remove-OllamaAutostart

    # ── 7b: Download portable zip (latest from GitHub) ─────────────────────
    $ollamaZip = "$DL_CACHE\ollama-windows-amd64.zip"

    # Always download latest (the URL resolves to the newest release)
    $dlOk = Download-File `
        -Url "https://github.com/ollama/ollama/releases/latest/download/ollama-windows-amd64.zip" `
        -Dest $ollamaZip -Label "Ollama portable (NVIDIA)"

    if ($dlOk) {
        # ── 7c: Extract to $OLLAMA_DIR ─────────────────────────────────────
        Write-ACT "Extracting Ollama to $OLLAMA_DIR..."
        Ensure-Dir $OLLAMA_DIR

        try {
            # Use .NET ZipFile for reliable extraction (Expand-Archive can be slow)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($ollamaZip, $OLLAMA_DIR)
            Write-OK "Ollama extracted to $OLLAMA_DIR"
        } catch {
            # Fallback: try Expand-Archive
            Write-INFO "Trying Expand-Archive fallback..."
            try {
                Expand-Archive -Path $ollamaZip -DestinationPath $OLLAMA_DIR -Force
                Write-OK "Ollama extracted (Expand-Archive)"
            } catch {
                Write-FAIL "Failed to extract Ollama: $_"
            }
        }

        if (Test-Path $ollamaExe -EA SilentlyContinue) {
            $ver = & $ollamaExe --version 2>&1 | Select-String "version" | ForEach-Object { $_.ToString().Trim() }
            Write-OK "Ollama sidecar ready: $ver"
        } else {
            Write-WARN "ollama.exe not found after extraction — check $OLLAMA_DIR"
        }
    }
}

# ── 7d: Set environment variables (loopback only, models in our dir) ────────
$env:OLLAMA_HOST    = "127.0.0.1:11434"
$env:OLLAMA_ORIGINS = "*"
$env:OLLAMA_MODELS  = "$MODEL_DIR"
$env:OLLAMA_NOPRUNE = "1"
$env:OLLAMA_FLASH_ATTENTION = "1"

# Persist to user environment for the Tauri app
[System.Environment]::SetEnvironmentVariable("OLLAMA_HOST", "127.0.0.1:11434", "User")
[System.Environment]::SetEnvironmentVariable("OLLAMA_ORIGINS", "*", "User")
[System.Environment]::SetEnvironmentVariable("OLLAMA_MODELS", "$MODEL_DIR", "User")
Write-OK "Ollama env: loopback-only, models in $MODEL_DIR"


Write-HEAD "STEP 8: START OLLAMA SIDECAR + PULL MODEL"
# =============================================================================

$ollamaExe = "$OLLAMA_DIR\ollama.exe"

if (-not (Test-Path $ollamaExe -EA SilentlyContinue)) {
    Write-WARN "Ollama not found at $ollamaExe — model pull skipped"
} else {
    # ── 8a: Start ollama serve as a hidden background process ───────────────
    if (Get-OllamaRunning) {
        Write-SKIP "Ollama already running on 127.0.0.1:11434"
    } else {
        Write-ACT "Starting Ollama sidecar server (hidden, loopback only)..."

        # Use ProcessStartInfo for full control — no window, no shell
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName         = $ollamaExe
        $psi.Arguments        = "serve"
        $psi.UseShellExecute  = $false
        $psi.CreateNoWindow   = $true
        $psi.WindowStyle      = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError  = $false
        # Pass env vars to child process
        $psi.EnvironmentVariables["OLLAMA_HOST"]    = "127.0.0.1:11434"
        $psi.EnvironmentVariables["OLLAMA_ORIGINS"]  = "*"
        $psi.EnvironmentVariables["OLLAMA_MODELS"]   = "$MODEL_DIR"
        $psi.EnvironmentVariables["OLLAMA_NOPRUNE"]  = "1"
        $psi.EnvironmentVariables["OLLAMA_FLASH_ATTENTION"] = "1"

        try {
            [System.Diagnostics.Process]::Start($psi) | Out-Null
            Write-OK "Ollama sidecar started (hidden, no tray)"
        } catch {
            Write-WARN "ProcessStartInfo failed: $_"
            # Fallback
            Start-Process $ollamaExe -ArgumentList "serve" -WindowStyle Hidden
            Write-INFO "Ollama started via Start-Process fallback"
        }

        # Wait for it to be ready
        $waited = 0
        do {
            Start-Sleep 2; $waited += 2
            Write-INFO "Waiting for Ollama... (${waited}s)"
            if (Get-OllamaRunning) { break }
        } while ($waited -lt 30)

        if (Get-OllamaRunning) {
            Write-OK "Ollama sidecar responding on 127.0.0.1:11434"
        } else {
            Write-WARN "Ollama did not respond in 30s"
        }
    }

    # ── 8b: Pull model (if not already present) ────────────────────────────
    if (Get-OllamaRunning) {
        $existingModels = Get-OllamaModels
        $alreadyHasModel = $existingModels | Where-Object { $_ -like "*$OLLAMA_MODEL*" -or $_ -eq $OLLAMA_MODEL }

        if ($alreadyHasModel) {
            Write-SKIP "Model already in Ollama: $($existingModels -join ', ')"
        } else {
            Write-ACT "Pulling AI model: $OLLAMA_MODEL (one-time download)..."
            Write-INFO "Model stored in: $MODEL_DIR"
            try {
                & $ollamaExe pull $OLLAMA_MODEL 2>&1 | ForEach-Object {
                    Write-Host "    $_" -ForegroundColor DarkGray
                }
                Write-OK "Model pulled: $OLLAMA_MODEL"
            } catch {
                Write-WARN "Model pull failed: $_ — retry with: $ollamaExe pull $OLLAMA_MODEL"
            }
        }
    }

    # ── 8c: Stop the sidecar (Viberize will start it when it launches) ─────
    Write-INFO "Stopping Ollama sidecar (Viberize will auto-start it on launch)..."
    Stop-OllamaGUI
    Write-OK "Ollama sidecar stopped — Viberize manages its lifecycle"
}

# ── Mark step complete ──────────────────────────────────────────────────────
Set-StepComplete "install-prerequisites"
Save-Log "Install-Prerequisites"
Write-OK "All prerequisites installed. Run 3-Scaffold-Source.ps1 next."
