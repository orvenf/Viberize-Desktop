# =============================================================================
#  VIBERIZE DESKTOP — Install Dependencies (Script 4 of 8)
#  Runs npm install (offline-first) and cargo fetch
# =============================================================================

$ErrorActionPreference = "Continue"

# Fresh-OS fix: ensure TLS 1.2 is available for all HTTPS downloads
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

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
function Test-FontInstalled { return (Test-Path "$APP\node_modules\@fontsource\inter" -EA SilentlyContinue) -or (Test-Path "$APP\node_modules\@fontsource-variable\inter" -EA SilentlyContinue) }


Show-Banner "INSTALL DEPENDENCIES" 4

# Fresh-OS fix: refresh PATH from registry so tools installed by Script 2 are visible
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")
foreach ($toolDir in @("$env:ProgramFiles\nodejs","${env:ProgramFiles(x86)}\nodejs","$env:USERPROFILE\.cargo\bin")) {
    if ((Test-Path $toolDir -EA SilentlyContinue) -and ($env:Path -notlike "*$toolDir*")) {
        $env:Path = "$toolDir;$env:Path"
    }
}

# ── Resolve tool paths (from Common helpers) ────────────────────────────────
$npmExe   = Get-NpmExe
$cargoExe = Get-CargoExe

Write-HEAD "PHASE 0 -- PREFLIGHT"
# =============================================================================

if (-not (Test-Path $APP -EA SilentlyContinue))               { Die "App dir missing: $APP -- run Script 3" }
if (-not (Test-Path "$APP\package.json" -EA SilentlyContinue)) { Die "package.json missing -- run Script 3" }
if (-not $npmExe)   { Die "npm not found -- Node.js not installed (run Script 2)" }
if (-not $cargoExe) { Write-WARN "cargo not found -- Rust dependencies will be fetched during build" }

Write-OK "App:   $APP"
Write-OK "npm:   $npmExe"
Write-OK "cargo: $cargoExe"


Write-HEAD "PHASE 0.3 -- NPM INSTALL (offline-first, network fallback)"
# =============================================================================

$nmExists = Test-Path "$APP\node_modules" -EA SilentlyContinue
if ((Test-FontInstalled) -and $nmExists) {
    Write-SKIP "@fontsource/inter present -- skipping npm install"
} else {
    Write-WARN "$(if ($nmExists) { '@fontsource/inter missing' } else { 'node_modules missing' }) -- running npm install"

    $done = $false
    Push-Location $APP

    # Layer 1: pure offline (cache only, zero network)
    if (-not $done) {
        Write-ACT "npm install --offline (layer 1: cache)..."
        $r = Run-Direct -Exe $npmExe -ArgList @("install","--offline","--no-audit","--no-fund") `
            -WorkDir $APP -TimeoutSec 120 -Label "npm --offline"
        if ($r.ExitCode -eq 0 -and (Test-FontInstalled)) { Write-OK "Layer 1 succeeded"; $done = $true }
        else { Write-WARN "Layer 1 failed (no cache or incomplete)" }
    }

    # Layer 2: prefer cache, allow network
    if (-not $done) {
        Write-ACT "npm install --prefer-offline (layer 2: cache + network)..."
        $r = Run-Direct -Exe $npmExe -ArgList @("install","--prefer-offline","--no-audit","--no-fund") `
            -WorkDir $APP -TimeoutSec 180 -Label "npm --prefer-offline"
        if ($r.ExitCode -eq 0 -and (Test-FontInstalled)) { Write-OK "Layer 2 succeeded"; $done = $true }
        else {
            ($r.Stdout + $r.Stderr) | Where-Object { $_ -match "error" } | Select-Object -First 5 |
                ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
            Write-WARN "Layer 2 failed (network may be blocked)"
        }
    }

    # Layer 3: individual font package install
    if (-not $done -and $nmExists) {
        Write-ACT "npm install @fontsource/inter (layer 3: individual)..."
        $r = Run-Direct -Exe $npmExe `
            -ArgList @("install","--save-dev","@fontsource/inter","--prefer-offline","--no-audit","--no-fund") `
            -WorkDir $APP -TimeoutSec 120 -Label "npm @fontsource/inter"
        if ($r.ExitCode -eq 0 -and (Test-FontInstalled)) { Write-OK "Layer 3 succeeded"; $done = $true }
        else { Write-WARN "Layer 3 failed" }
    }

    Pop-Location

    # Layer 4: offline CSS fallback -- guaranteed to work with zero network
    if (-not (Test-FontInstalled)) {
        Write-WARN "Font package unavailable (no network) -- activating offline CSS fallback"

        # Remove @fontsource import from main.tsx (Vite won't fail on missing module)
        if (Test-Path "$APP\src\main.tsx" -EA SilentlyContinue) {
            $mx = [System.IO.File]::ReadAllText("$APP\src\main.tsx")
            $mx = $mx -replace '(?m)^import\s+"@fontsource[^"]*";\s*[\r\n]?', ''
            $mx = $mx -replace "(?m)^import\s+'@fontsource[^']*';\s*[\r\n]?", ''
            [System.IO.File]::WriteAllText("$APP\src\main.tsx", $mx, $script:UTF8NoBOM)
            Write-OK "Removed @fontsource import from main.tsx"
        }

        # Inject @font-face into tokens.css using local() (zero download required)
        if (Test-Path "$APP\src\styles\tokens.css" -EA SilentlyContinue) {
            $tc = [System.IO.File]::ReadAllText("$APP\src\styles\tokens.css")
            if ($tc -notmatch "@font-face") {
                $fb = @'
/* Offline Inter fallback v7: system fonts (Segoe UI Variable = Inter on Windows 11) */
@font-face {
  font-family: "InterVariable";
  src: local("Inter"), local("Segoe UI Variable"), local("Segoe UI"), local("system-ui");
  font-weight: 100 900; font-style: normal;
}
@font-face {
  font-family: "Inter";
  src: local("Inter"), local("Segoe UI Variable"), local("Segoe UI"), local("system-ui");
  font-weight: 100 900; font-style: normal;
}

'@
                [System.IO.File]::WriteAllText("$APP\src\styles\tokens.css", $fb + $tc, $script:UTF8NoBOM)
                Write-OK "System-font @font-face injected into tokens.css"
            }
        }
        Write-OK "Offline font fallback active -- build will proceed"
    }
}


# =============================================================================
Write-HEAD "PHASE 0.5 -- PRE-BUILD CONFIG REPAIR"
# =============================================================================

# v8: Strip BOM from config files (v7 wrote with BOM -> Vite PostCSS crash)
Strip-BOM "$APP\postcss.config.cjs"
Strip-BOM "$APP\tailwind.config.cjs"
Strip-BOM "$APP\vite.config.ts"
Strip-BOM "$APP\tsconfig.json"

# v8 DEFINITIVE FIX: Write postcss.config.cjs (explicit CommonJS extension).
#
# ROOT CAUSE CHAIN (Node 24 + Vite 5.4):
# - postcss-load-config (bundled in Vite) uses lilconfig to search for config
# - lilconfig searches: .postcssrc, postcss.config.js, postcss.config.cjs, package.json
# - If postcss.config.js exists: Node 24 lilconfig uses import() -> fails on CJS -> jsonLoader -> JSON.parse crash
# - If postcss.config.js is DELETED: lilconfig falls through to package.json -> jsonLoader -> JSON.parse crash
# - If css.postcss is inlined in vite.config.ts: Vite 5.4 STILL runs postcss-load-config search
# 
# FIX: Write postcss.config.cjs
# - .cjs is loaded via require() by lilconfig (NEVER jsonLoader)
# - require() ALWAYS treats .cjs as CommonJS regardless of Node version
# - lilconfig finds .cjs BEFORE falling through to package.json
# - Search stops. No jsonLoader. No crash.

# Remove stale .js variant (would be found first and crash)
if (Test-Path "$APP\postcss.config.js" -EA SilentlyContinue) {
    Remove-Item "$APP\postcss.config.js" -Force -EA SilentlyContinue
    Write-OK "Removed stale postcss.config.js"
}
# Remove .mjs variant
if (Test-Path "$APP\postcss.config.mjs" -EA SilentlyContinue) {
    Remove-Item "$APP\postcss.config.mjs" -Force -EA SilentlyContinue
}

# Write definitive .cjs config
Force-Write "$APP\postcss.config.cjs" @'
module.exports = {
  plugins: {
    tailwindcss:  {},
    autoprefixer: {},
  },
};
'@ -Label "postcss.config.cjs" | Out-Null

$pc = try { Get-Content "$APP\postcss.config.cjs" -Raw } catch { "" }
if ($pc -notmatch "module\.exports") { Die "postcss.config.cjs write failed" }
Write-OK "postcss.config.cjs: valid CJS (Node 24 safe)"

# v8 CRITICAL: Ensure vite.config.ts has inline PostCSS via createRequire.
# This bypasses postcss-load-config/cosmiconfig entirely.
# Without this, Vite 5.4.21 + Node 24 falls through to jsonLoader -> crash.
$viteConfigContent = @'
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const tailwindcss = require("tailwindcss");
const autoprefixer = require("autoprefixer");

export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  envPrefix: ["VITE_","TAURI_"],
  css: {
    postcss: {
      plugins: [tailwindcss, autoprefixer],
    },
  },
  build: {
    target: process.env.TAURI_PLATFORM === "windows" ? "chrome105" : "safari13",
    minify: !process.env.TAURI_DEBUG ? "esbuild" : false,
    sourcemap: !!process.env.TAURI_DEBUG,
  },
});
'@
Force-Write "$APP\vite.config.ts" $viteConfigContent -Label "vite.config.ts (inline PostCSS)" | Out-Null
Write-OK "vite.config.ts: PostCSS inlined via createRequire (bypasses cosmiconfig)"

# RC-1: tailwind config must be explicit CJS (.cjs extension).
# Node 24 + Vite 5.4 can misroute .js through ESM import() path.
# .cjs is ALWAYS treated as CommonJS regardless of Node version.
foreach ($stale in @("$APP\tailwind.config.ts","$APP\tailwind.config.js")) {
    if (Test-Path $stale -EA SilentlyContinue) {
        Remove-Item $stale -Force -EA SilentlyContinue
        Write-OK "Removed stale $(Split-Path $stale -Leaf)"
    }
}
Force-Write "$APP\tailwind.config.cjs" @'
/** @type {import("tailwindcss").Config} */
module.exports = {
  content: ["./index.html","./src/**/*.{ts,tsx,js,jsx}"],
  theme: {
    extend: {
      fontFamily: {
        sans:  ["InterVariable","Inter","Segoe UI Variable","Segoe UI","system-ui","sans-serif"],
        inter: ["InterVariable","Inter","Segoe UI Variable","Segoe UI","sans-serif"],
      },
      colors: {
        vbg:           "var(--v-bg)",
        vsurface:      "var(--v-surface)",
        "vsurface-alt":"var(--v-surface-alt)",
        vstroke:       "var(--v-stroke)",
        vtext:         "var(--v-text)",
        "vtext-sec":   "var(--v-text-sec)",
        "vtext-muted": "var(--v-text-muted)",
        vdanger:       "var(--v-danger)",
        vsuccess:      "var(--v-success)",
      },
      borderRadius: { chip:"999px", btn:"16px", card:"18px", input:"16px" },
    },
  },
  plugins: [],
};
'@ -Label "tailwind.config.js (CJS)" | Out-Null

$tw = try { Get-Content "$APP\tailwind.config.cjs" -Raw } catch { "" }
if ($tw -notmatch "module\.exports") { Die "tailwind.config.cjs repair failed" }
Write-OK "tailwind.config.cjs: valid CJS"

# RC-3: Remove broken outfit.css (url() outside Vite root)
if (Test-Path "$APP\src\fonts\outfit.css" -EA SilentlyContinue) {
    $oc = try { Get-Content "$APP\src\fonts\outfit.css" -Raw } catch { "" }
    if ($oc -match "\.\./\.\./\.\./assets") {
        Remove-Item "$APP\src\fonts\outfit.css" -Force -EA SilentlyContinue
        Write-OK "Removed outfit.css (url() outside Vite root)"
    }
}

# Sync main.tsx font import to what's actually installed
if (Test-Path "$APP\src\main.tsx" -EA SilentlyContinue) {
    $mx = [System.IO.File]::ReadAllText("$APP\src\main.tsx")
    if (Test-FontInstalled) {
        $pkg = if (Test-Path "$APP\node_modules\@fontsource\inter" -EA SilentlyContinue) {
            "@fontsource/inter"
        } else { "@fontsource/inter" }
        if ($mx -notmatch "@fontsource") {
            $mx = "import `"$pkg`";`n" + $mx
            [System.IO.File]::WriteAllText("$APP\src\main.tsx", $mx, $script:UTF8NoBOM)
            Write-OK "Added $pkg import to main.tsx"
        } else { Write-OK "main.tsx: font import present" }
    } else {
        if ($mx -match "@fontsource") {
            $mx = $mx -replace '(?m)^import\s+"@fontsource[^"]*";\s*[\r\n]?', ''
            $mx = $mx -replace "(?m)^import\s+'@fontsource[^']*';\s*[\r\n]?", ''
            [System.IO.File]::WriteAllText("$APP\src\main.tsx", $mx, $script:UTF8NoBOM)
            Write-OK "main.tsx: @fontsource import removed (CSS fallback active)"
        } else { Write-OK "main.tsx: no @fontsource import (CSS fallback active)" }
    }
}

# Remove any broken outfit @import from tokens.css
if (Test-Path "$APP\src\styles\tokens.css" -EA SilentlyContinue) {
    $tc = [System.IO.File]::ReadAllText("$APP\src\styles\tokens.css")
    if ($tc -match "@import.*outfit") {
        $tc = $tc -replace "(?m)@import.*outfit.*[\r\n]?", ""
        [System.IO.File]::WriteAllText("$APP\src\styles\tokens.css", $tc, $script:UTF8NoBOM)
        Write-OK "tokens.css: removed outfit @import"
    } else { Write-OK "tokens.css: no broken font @import" }
}


# v8: Ensure build.rs exists (required for Tauri 2.x -- sets OUT_DIR for generate_context!)
if (-not (Test-Path "$TAURI_DIR\build.rs" -EA SilentlyContinue)) {
    Force-Write "$TAURI_DIR\build.rs" @'
fn main() {
    tauri_build::build()
}
'@ -Label "build.rs (Tauri 2.x)" | Out-Null
    Write-OK "Created build.rs (was missing -- required for Tauri 2.x)"
} else {
    Write-OK "build.rs: present"
}

# v8: Ensure Cargo.toml has [build-dependencies] tauri-build
$cargoToml = try { Get-Content "$TAURI_DIR\Cargo.toml" -Raw } catch { "" }
if ($cargoToml -and $cargoToml -notmatch "tauri-build") {
    # Append build-dependencies section
    $cargoToml = $cargoToml.TrimEnd() + "`n`n[build-dependencies]`ntauri-build = { version = `"2`", features = [] }`n"
    $UTF8NoBOM = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText("$TAURI_DIR\Cargo.toml", $cargoToml, $UTF8NoBOM)
    Write-OK "Added [build-dependencies] tauri-build to Cargo.toml"
} elseif ($cargoToml -match "tauri-build") {
    Write-OK "Cargo.toml: tauri-build present"
}


# v8: Ensure Tauri icons exist (required for Windows .exe resource embedding)
# Script 3 generates these from logo.png if available. This is a safety net
# that regenerates from logo.png if icons are missing, or falls back to placeholder.
$iconsDir = "$TAURI_DIR\icons"
if (-not (Test-Path $iconsDir -EA SilentlyContinue)) {
    New-Item -ItemType Directory $iconsDir -Force | Out-Null
}

$needsIcons = -not (Test-Path "$iconsDir\icon.ico" -EA SilentlyContinue)
if (-not $needsIcons) {
    # Check if icons are still the tiny 1x1 fallback (< 1KB means placeholder)
    $icoSize = (Get-Item "$iconsDir\icon.ico" -EA SilentlyContinue).Length
    if ($icoSize -lt 1024) {
        $logoSrc = "$ROOT\assets\logo.png"
        if (Test-Path $logoSrc -EA SilentlyContinue) {
            Write-INFO "icon.ico is placeholder but logo.png available — regenerating"
            $needsIcons = $true
        }
    }
}

if ($needsIcons) {
    $logoSrc = "$ROOT\assets\logo.png"
    $hasLogo = Test-Path $logoSrc -EA SilentlyContinue

    try {
        Add-Type -AssemblyName System.Drawing -EA SilentlyContinue

        # Load source
        $script:srcImg = $null
        if ($hasLogo) {
            try {
                $lb = [System.IO.File]::ReadAllBytes($logoSrc)
                $lm = New-Object System.IO.MemoryStream(,$lb)
                $script:srcImg = [System.Drawing.Image]::FromStream($lm)
                Write-ACT "Generating icons from logo.png..."
            } catch { Write-WARN "Could not load logo.png — using placeholder" }
        }

        foreach ($sz in @(32, 128, 256)) {
            $bmp = New-Object System.Drawing.Bitmap($sz, $sz)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            if ($script:srcImg) {
                $g.Clear([System.Drawing.Color]::Transparent)
                $g.DrawImage($script:srcImg, 0, 0, $sz, $sz)
            } else {
                $g.Clear([System.Drawing.Color]::FromArgb(7, 7, 7))
                $fs = [Math]::Floor($sz * 0.55)
                $ft = New-Object System.Drawing.Font("Segoe UI", $fs, [System.Drawing.FontStyle]::Bold)
                $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(242, 242, 242))
                $sff = New-Object System.Drawing.StringFormat
                $sff.Alignment = [System.Drawing.StringAlignment]::Center
                $sff.LineAlignment = [System.Drawing.StringAlignment]::Center
                $g.DrawString("V", $ft, $br, (New-Object System.Drawing.RectangleF(0,0,$sz,$sz)), $sff)
                $ft.Dispose(); $br.Dispose(); $sff.Dispose()
            }
            $g.Dispose()

            # Save PNGs
            if ($sz -eq 32)  { $bmp.Save("$iconsDir\32x32.png", [System.Drawing.Imaging.ImageFormat]::Png) }
            if ($sz -eq 128) { $bmp.Save("$iconsDir\128x128.png", [System.Drawing.Imaging.ImageFormat]::Png) }
            if ($sz -eq 256) {
                $bmp.Save("$iconsDir\128x128@2x.png", [System.Drawing.Imaging.ImageFormat]::Png)
                # Build ICO from 256px
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $pngBytes = $ms.ToArray(); $ms.Dispose()
                $icoMs = New-Object System.IO.MemoryStream
                $bw = New-Object System.IO.BinaryWriter($icoMs)
                $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
                $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
                $bw.Write([UInt16]1); $bw.Write([UInt16]32)
                $bw.Write([UInt32]$pngBytes.Length); $bw.Write([UInt32]22)
                $bw.Write($pngBytes); $bw.Flush()
                [System.IO.File]::WriteAllBytes("$iconsDir\icon.ico", $icoMs.ToArray())
                $bw.Dispose(); $icoMs.Dispose()
            }
            $bmp.Dispose()
        }
        if ($script:srcImg) { $script:srcImg.Dispose() }
        Write-OK "Icons generated$(if ($hasLogo) { ' from logo.png' } else { ' (placeholder)' })"
    } catch {
        Write-WARN "Icon generation failed: $_ — minimal fallback"
        $minIco = [byte[]]@(0,0,1,0,1,0,1,1,0,0,1,0,32,0,40,0,0,0,22,0,0,0,
            40,0,0,0,1,0,0,0,2,0,0,0,1,0,32,0,0,0,0,0,4,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
            7,7,7,255,0,0,0,0)
        [System.IO.File]::WriteAllBytes("$iconsDir\icon.ico", $minIco)
    }
} else {
    Write-OK "Icons: already generated"
}

# v8: Ensure Tauri 2.x capabilities exist (required for dialog/fs/shell plugins)
$capsDir = "$TAURI_DIR\capabilities"
if (-not (Test-Path $capsDir -EA SilentlyContinue)) {
    New-Item -ItemType Directory $capsDir -Force | Out-Null
}
if (-not (Test-Path "$capsDir\default.json" -EA SilentlyContinue)) {
    $capsJson = @'
{
  "identifier": "default",
  "description": "Default capabilities for Viberize Desktop",
  "windows": ["main"],
  "permissions": [
    "core:default",
    "dialog:default",
    "dialog:allow-open",
    "dialog:allow-save",
    "dialog:allow-message",
    "dialog:allow-ask",
    "fs:default",
    "fs:allow-read",
    "fs:allow-write",
    "fs:allow-exists",
    "fs:allow-mkdir",
    "shell:default",
    "shell:allow-open"
  ]
}
'@
    Force-Write "$capsDir\default.json" $capsJson -Label "capabilities/default.json" | Out-Null
    Write-OK "Created Tauri capabilities (dialog/fs/shell permissions)"
} else {
    Write-OK "Tauri capabilities: present"
}


Write-OK "Phase 0.5 complete -- all configs repaired"


# =============================================================================
Write-HEAD "PHASE 0.6 -- STAGE DEPENDENCY INSTALLERS"
# =============================================================================

$RESOURCES_DIR = "$TAURI_DIR\resources"
if (-not (Test-Path $RESOURCES_DIR -EA SilentlyContinue)) {
    New-Item -ItemType Directory $RESOURCES_DIR -Force | Out-Null
}

function Stage-Dependency {
    param([string]$Url, [string]$Dest, [string]$Label)
    if (Test-Path $Dest -EA SilentlyContinue) {
        Write-OK "$Label already staged"
        return $true
    }
    Write-ACT "Downloading $Label..."
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $Dest)
        $wc.Dispose()
        if (Test-Path $Dest -EA SilentlyContinue) {
            $sizeMB = [Math]::Round((Get-Item $Dest).Length / 1MB, 1)
            Write-OK "$Label staged (${sizeMB} MB)"
            return $true
        }
    } catch { Write-WARN "Download failed for ${Label}: $_ -- installer will skip this dependency" }
    return $false
}

# Ollama installer (~85 MB)
Stage-Dependency -Url "https://ollama.com/download/OllamaSetup.exe" `
    -Dest "$RESOURCES_DIR\OllamaSetup.exe" -Label "Ollama installer"

# VC++ Redistributable 2022 x64 (~25 MB)
Stage-Dependency -Url "https://aka.ms/vs/17/release/vc_redist.x64.exe" `
    -Dest "$RESOURCES_DIR\vc_redist.x64.exe" -Label "VC++ Redist 2022"

$stagedCount = @(Get-ChildItem "$RESOURCES_DIR\*.exe" -EA SilentlyContinue).Count
Write-OK "Resources staged: $stagedCount installers in resources/"

# =============================================================================

# ── Cargo fetch (download Rust dependencies) ────────────────────────────────
Write-HEAD "CARGO FETCH"
$cargoExe = "$env:USERPROFILE\.cargo\bin\cargo.exe"
if (Test-Path $cargoExe -EA SilentlyContinue) {
    Push-Location "$APP\src-tauri"
    try {
        Write-ACT "Fetching Rust dependencies..."
        & $cargoExe fetch 2>&1 | ForEach-Object { if ($_ -match "Downloading|Fetching") { Write-INFO "$_" } }
        Write-OK "Cargo dependencies fetched"
    } catch { Write-WARN "cargo fetch failed: $_" }
    Pop-Location
} else { Write-WARN "cargo not found — Rust dependencies will download during build" }

Set-StepComplete "install-dependencies"
Save-Log "Install-Dependencies"
Write-OK "Dependencies installed. Run Build-Frontend.ps1 next."
