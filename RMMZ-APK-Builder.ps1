# =============================================================================
#  RMMZ APK Builder - turns an RPG Maker MZ web export into a sideload-ready
#  Android APK (for itch.io etc.). Not a Play Store pipeline: the APK is
#  signed with a local key kept in the user's Documents\android-keys folder
#  (Android refuses unsigned APKs entirely), and Play would require an AAB
#  plus store setup anyway.
#
#  GUI:      double-click "Launch RMMZ APK Builder.bat"
#  Headless: powershell -ExecutionPolicy Bypass -File RMMZ-APK-Builder.ps1 `
#              -NoGui -GameDir <export folder> [-options...]
#
#  NOTE: keep this file pure ASCII. PowerShell 5.1 reads BOM-less files as
#  ANSI, where a stray em-dash decodes into a smart-quote character that
#  PowerShell treats as a real string delimiter.
# =============================================================================
param(
    [switch]$NoGui,
    [string]$GameDir = "",
    [string]$DevName = "",
    [string]$GameTitle = "",
    [string]$VersionName = "1.0",
    [string]$IconPath = "",
    [string]$BackgroundImage = "",
    [string]$BackgroundColor = "#000000",
    [switch]$NoFrame,
    [string]$FrameColor = "#bababa",
    [int]$FrameOpacity = 50,
    [double]$FrameMargin = 4,
    [double]$VMargin = 5,
    [string]$ButtonColor = "#14507e",
    [int]$ControlsOpacity = 55,
    [int]$ControlsSize = 100,
    [switch]$ExtraButton,
    [string]$ExtraKey = "C",
    [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ToolDir     = $PSScriptRoot
$TemplateDir = Join-Path $ToolDir "templates"
$GuiSettings = Join-Path $ToolDir "gui-settings.json"

# --- working locations, with a guard for non-ASCII user names -------------
# The Java/Android toolchain misbehaves when paths contain non-ASCII
# characters (e.g. a Cyrillic Windows user name), and Windows points %TEMP%
# at an 8.3 short path like C:\Users\7636~1\... for such profiles, which may
# not resolve at all. When the profile or tool path is not plain ASCII,
# everything the build needs lives under an ASCII-only folder in the shared
# Public profile instead.
function Test-AsciiPath([string]$p) {
    return ($null -ne $p) -and ($p -notmatch "[^\x20-\x7E]")
}

$AsciiPaths = (Test-AsciiPath $env:USERPROFILE) -and (Test-AsciiPath $ToolDir)
if ($AsciiPaths) {
    $ProjectsDir = Join-Path $ToolDir "projects"
    $KeysDir     = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "android-keys"
    $SdkDir      = "$env:LOCALAPPDATA\Android\Sdk"
    $JdkRoot     = "$env:USERPROFILE\.jdks"
    $DataRoot    = $null
} else {
    $DataRoot    = Join-Path $env:PUBLIC "RMMZ-APK-Builder"
    $ProjectsDir = Join-Path $DataRoot "projects"
    $KeysDir     = Join-Path $DataRoot "android-keys"
    $SdkDir      = Join-Path $DataRoot "Sdk"
    $JdkRoot     = Join-Path $DataRoot "jdk"
    # Keep Gradle's cache off the non-ASCII profile path too.
    $env:GRADLE_USER_HOME = Join-Path $DataRoot "gradle"
}
# Downloads always go somewhere we control, never %TEMP%.
$DownloadDir = Join-Path $SdkDir "downloads"

if (-not $OutputDir) { $OutputDir = Join-Path $ToolDir "output" }

$script:LogBox = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextFile([string]$path, [string]$content) {
    [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
}

function Write-Log([string]$msg) {
    if ($script:LogBox) {
        $script:LogBox.AppendText($msg + "`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.Text.Length
        $script:LogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        Write-Host $msg
    }
}

# Progress bar / status line (GUI only; no-ops in headless mode). Every call
# pumps the Windows message queue, which is what keeps the window responsive
# during the long one-time downloads instead of showing "Not responding".
function Set-Progress([string]$text = "", [int]$percent = -1) {
    if (-not $script:ProgBar) { return }
    try {
        if ($text) { $script:StatusLabel.Text = $text }
        if ($percent -lt 0) {
            if ($script:ProgBar.Style -ne "Marquee") { $script:ProgBar.Style = "Marquee" }
        } else {
            $script:ProgBar.Style = "Continuous"
            $script:ProgBar.Value = [Math]::Max(0, [Math]::Min(100, $percent))
        }
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

# Streamed download so the byte count (and the UI) keep moving.
function Get-FileWithProgress([string]$url, [string]$dest, [string]$label) {
    $req = [System.Net.WebRequest]::Create($url)
    $req.Timeout = 120000
    $resp = $req.GetResponse()
    $total = [double]$resp.ContentLength
    $in = $resp.GetResponseStream()
    $out = [System.IO.File]::Create($dest)
    $nextLog = 25
    try {
        $buf = New-Object byte[] 262144
        $sum = 0.0
        $lastUi = 0.0
        $n = 0
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $sum += $n
            if (($sum - $lastUi) -ge 1048576) {
                $lastUi = $sum
                if ($total -gt 0) {
                    $pct = [int](100.0 * $sum / $total)
                    Set-Progress -text ("{0} - {1:N0} / {2:N0} MB" -f $label, ($sum / 1MB), ($total / 1MB)) -percent $pct
                    if ((-not $script:ProgBar) -and $pct -ge $nextLog) {
                        Write-Log ("   {0}% ..." -f $pct)
                        $nextLog += 25
                    }
                } else {
                    Set-Progress -text ("{0} - {1:N0} MB" -f $label, ($sum / 1MB))
                }
            }
        }
    } finally {
        $out.Close(); $in.Close(); $resp.Close()
    }
}

# Entry-by-entry extraction, so big archives report progress too.
function Expand-WithProgress([string]$zipPath, [string]$dest, [string]$label) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Force $dest | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $count = $zip.Entries.Count
        $i = 0
        foreach ($e in $zip.Entries) {
            $i++
            $target = Join-Path $dest $e.FullName
            if (-not $e.Name) {
                New-Item -ItemType Directory -Force $target | Out-Null
            } else {
                $dir = Split-Path $target -Parent
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            }
            if ($i % 75 -eq 0 -or $i -eq $count) {
                Set-Progress -text ("{0} - {1:N0} / {2:N0} files" -f $label, $i, $count) -percent ([int](100.0 * $i / $count))
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Run-Cmd([string]$desc, [string]$cwd, [string]$file, [string[]]$argList, [int[]]$okCodes = @(0)) {
    Write-Log "== $desc"
    Set-Progress -text $desc
    Push-Location $cwd
    $oldEap = $ErrorActionPreference
    # Native tools write progress/warnings to stderr; don't let PowerShell
    # promote those lines to terminating errors. Exit codes decide success.
    $ErrorActionPreference = "Continue"
    try {
        & $file @argList 2>&1 | ForEach-Object { Write-Log ("   " + [string]$_) }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        Pop-Location
    }
    if ($okCodes -notcontains $code) { throw "$desc failed (exit code $code)" }
}

function Sanitize-Name([string]$s) {
    return ($s.ToLower() -replace "[^a-z0-9]", "")
}

function Parse-HexColor([string]$hex, [string]$fallback) {
    if ($hex -notmatch "^#?[0-9a-fA-F]{6}$") { $hex = $fallback }
    $h = $hex.TrimStart("#")
    return [System.Drawing.Color]::FromArgb(255,
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function Resolve-GameDir([string]$dir) {
    # MV desktop exports put the game inside a www subfolder - descend into it.
    if ($dir -and -not (Test-Path (Join-Path $dir "index.html")) -and
        (Test-Path (Join-Path $dir "www\index.html"))) {
        return (Join-Path $dir "www")
    }
    return $dir
}

function Get-GameTitle([string]$dir) {
    try {
        $pkg = Get-Content (Join-Path $dir "package.json") -Raw | ConvertFrom-Json
        if ($pkg.window.title) { return [string]$pkg.window.title }
    } catch { }
    try {
        $sys = Get-Content (Join-Path $dir "data\System.json") -Raw | ConvertFrom-Json
        if ($sys.gameTitle) { return [string]$sys.gameTitle }
    } catch { }
    return (Split-Path $dir -Leaf)
}

function Edit-Once([string]$text, [string]$pattern, [string]$replacement) {
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $rx.Replace($text, $replacement, 1)
}

# Which audio extension a game actually ships. MV asks for .m4a on mobile
# regardless, so a web export containing only ogg would be silent; pin what is
# really there. "" means leave the engine's own choice alone.
function Get-AudioExt([string]$dir) {
    $audioDir = Join-Path $dir "audio"
    if (-not (Test-Path $audioDir)) { return "" }
    $ext = @{}
    foreach ($f in (Get-ChildItem $audioDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $ext[$f.Extension.ToLower()] = $true
    }
    if ($ext.ContainsKey(".ogg") -or $ext.ContainsKey(".rpgmvo")) { return ".ogg" }
    if ($ext.ContainsKey(".m4a") -or $ext.ContainsKey(".rpgmvm")) { return ".m4a" }
    return ""
}

function Get-GameAspect([string]$dir) {
    # Width/height ratio of the game's render resolution (System.json).
    try {
        $sys = Get-Content (Join-Path $dir "data\System.json") -Raw | ConvertFrom-Json
        $w = [double]$sys.advanced.screenWidth
        $h = [double]$sys.advanced.screenHeight
        if ($w -gt 0 -and $h -gt 0) { return $w / $h }
    } catch { }
    return 816.0 / 624.0
}

# On phones the MZ engine renders the game at 90% of the screen height by
# default; the generated mobile-controls.js overrides that with the exact
# per-side V-margin the user picks (0 = full height).

function Test-NodeInstalled {
    try { $null = Get-Command node -ErrorAction Stop; return $true } catch { return $false }
}

# ---------------------------------------------------------------- prereqs ---
function Ensure-Node {
    if (-not (Test-NodeInstalled)) {
        throw "Node.js not found. Install it from https://nodejs.org/en/download and run again."
    }
}

function Ensure-Jdk {
    $jdk = Get-ChildItem $JdkRoot -Directory -Filter "jdk-21*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($jdk) { return $jdk.FullName }
    Write-Log "== Downloading Temurin JDK 21 (one-time, ~190 MB)"
    New-Item -ItemType Directory -Force $JdkRoot | Out-Null
    New-Item -ItemType Directory -Force $DownloadDir | Out-Null
    $zip = Join-Path $DownloadDir "jdk21.zip"
    Get-FileWithProgress "https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse" $zip "Downloading Java JDK 21"
    Write-Log "   extracting..."
    Expand-WithProgress $zip $JdkRoot "Extracting Java JDK 21"
    Remove-Item $zip -Force
    $jdk = Get-ChildItem $JdkRoot -Directory -Filter "jdk-21*" | Select-Object -First 1
    if (-not $jdk) { throw "JDK download/extract failed" }
    return $jdk.FullName
}

# sdkmanager prompts for license acceptance on stdin. Piping into it from a
# GUI process (which has no console stdin) leaves it blocked forever at 0% CPU,
# so run it as a child process with a file of "y" answers as stdin, follow its
# log for progress, and give up if it produces nothing for a long stretch.
function Invoke-Sdkmanager([string]$sdkman, [string[]]$sdkArgs, [string]$label, [bool]$ignoreExit = $false) {
    New-Item -ItemType Directory -Force $DownloadDir | Out-Null
    $log = Join-Path $DownloadDir "sdkmanager.log"
    $errLog = Join-Path $DownloadDir "sdkmanager.err"
    $answers = Join-Path $DownloadDir "accept.txt"
    Remove-Item $log, $errLog -Force -ErrorAction SilentlyContinue
    Set-Content -Path $answers -Value ((1..80 | ForEach-Object { "y" }) -join "`r`n") -Encoding ascii

    $p = Start-Process -FilePath $sdkman -ArgumentList $sdkArgs -NoNewWindow -PassThru `
            -RedirectStandardInput $answers -RedirectStandardOutput $log -RedirectStandardError $errLog
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastLen = -1
    $lastChange = 0.0
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 400
        $len = -1
        try { $len = (Get-Item $log -ErrorAction Stop).Length } catch { }
        if ($len -ne $lastLen) { $lastLen = $len; $lastChange = $sw.Elapsed.TotalSeconds }
        $pct = -1
        try {
            $tail = [string](Get-Content $log -Tail 1 -ErrorAction Stop)
            if ($tail -match "(\d{1,3})%(?!.*\d{1,3}%)") { $pct = [int]$matches[1] }
        } catch { }
        if ($pct -ge 0) { Set-Progress -text $label -percent $pct } else { Set-Progress -text $label }
        if (($sw.Elapsed.TotalSeconds - $lastChange) -gt 480) {
            try { $p.Kill() } catch { }
            throw "$label stopped responding (no progress for 8 minutes). Check your internet connection, and if you run antivirus like 360 Total Security, allow this folder or turn it off and retry."
        }
    }
    # Start-Process -PassThru does not always populate ExitCode until the
    # object is waited on, and it can stay $null; treat unknown as success and
    # let the caller's own outcome check decide.
    $code = $null
    try { $p.WaitForExit(); $code = [int]$p.ExitCode } catch { }
    if ((-not $ignoreExit) -and ($null -ne $code) -and ($code -ne 0)) {
        $detail = ""
        try { $detail = ((Get-Content $errLog -Tail 4 -ErrorAction Stop) -join " ").Trim() } catch { }
        throw "$label failed (exit code $code). $detail"
    }
}

function Ensure-Sdk([string]$jdkPath) {
    if (Test-Path "$SdkDir\platforms\android-36") { return }
    Write-Log "== Installing Android SDK (one-time, ~700 MB)"
    $env:JAVA_HOME = $jdkPath
    if (-not (Test-Path "$SdkDir\cmdline-tools\latest\bin\sdkmanager.bat")) {
        New-Item -ItemType Directory -Force $DownloadDir | Out-Null
        $cliZip = Join-Path $DownloadDir "cmdtools.zip"
        Get-FileWithProgress "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip" $cliZip "Downloading Android command-line tools"
        Expand-WithProgress $cliZip "$SdkDir\cmdline-tools\tmp" "Extracting Android command-line tools"
        Move-Item "$SdkDir\cmdline-tools\tmp\cmdline-tools" "$SdkDir\cmdline-tools\latest"
        Remove-Item "$SdkDir\cmdline-tools\tmp" -Recurse -Force
        Remove-Item $cliZip -Force
    }
    $sdkman = "$SdkDir\cmdline-tools\latest\bin\sdkmanager.bat"
    Write-Log "   accepting SDK licenses"
    Invoke-Sdkmanager $sdkman @("--licenses") "Accepting Android SDK licenses" $true
    Write-Log "   downloading SDK packages - this is the slow part (a few minutes)"
    Invoke-Sdkmanager $sdkman @("platform-tools", "platforms;android-36", "build-tools;36.0.0") "Installing Android SDK packages (~700 MB)"
    if (-not (Test-Path "$SdkDir\platforms\android-36")) { throw "Android SDK install failed" }
}

function Ensure-Keystore {
    New-Item -ItemType Directory -Force $KeysDir | Out-Null
    $jks   = Join-Path $KeysDir "upload-keystore.jks"
    $props = Join-Path $KeysDir "key.properties"
    if ((Test-Path $jks) -and (Test-Path $props)) { return }
    if ((Test-Path $jks) -and -not (Test-Path $props)) {
        throw "Keystore exists at $jks but key.properties (its password) is missing. Restore key.properties next to it."
    }
    Write-Log "== Generating signing keystore (one-time; BACK UP $KeysDir)"
    $pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    $dn = Sanitize-Name $DevName
    if (-not $dn) { $dn = "unknown" }
    $keytool = Join-Path (Ensure-Jdk) "bin\keytool.exe"
    & $keytool -genkeypair -v -keystore $jks -alias upload -keyalg RSA -keysize 2048 -validity 10000 `
        -storepass $pw -keypass $pw -dname "CN=$dn, O=$dn" | Out-Null
    $storeFile = $jks -replace "\\", "/"
    Write-TextFile $props "storeFile=$storeFile`nstorePassword=$pw`nkeyAlias=upload`nkeyPassword=$pw"
}

# ------------------------------------------------------------ image assets ---
function Draw-Cover([System.Drawing.Graphics]$g, [System.Drawing.Image]$img, [double]$W, [double]$H) {
    $scale = [Math]::Max($W / $img.Width, $H / $img.Height)
    $dw = $img.Width * $scale
    $dh = $img.Height * $scale
    $g.DrawImage($img, [float](($W - $dw) / 2), [float](($H - $dh) / 2), [float]$dw, [float]$dh)
}

function New-ImageAssets([string]$projDir, [string]$iconPath, [string]$bgImage, [System.Drawing.Color]$bgColor) {
    $assets = Join-Path $projDir "assets"
    New-Item -ItemType Directory -Force $assets | Out-Null
    $icon = [System.Drawing.Image]::FromFile($iconPath)
    $iconBmp = New-Object System.Drawing.Bitmap($icon)
    $corner = $iconBmp.GetPixel(2, 2)
    if ($corner.A -lt 255) { $corner = [System.Drawing.Color]::Black }

    function New-Canvas([int]$w, [int]$h, [System.Drawing.Color]$c) {
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear($c)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        return @($bmp, $g)
    }

    $c = New-Canvas 1024 1024 $corner; $bmp = $c[0]; $g = $c[1]
    Draw-Cover $g $icon 1024 1024; $g.Dispose()
    $bmp.Save("$assets\icon-only.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    $c = New-Canvas 1024 1024 $corner; $bmp = $c[0]; $g = $c[1]
    $g.DrawImage($icon, 176, 176, 672, 672); $g.Dispose()
    $bmp.Save("$assets\icon-foreground.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    $c = New-Canvas 1024 1024 $corner; $bmp = $c[0]; $g = $c[1]
    $g.Dispose(); $bmp.Save("$assets\icon-background.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()

    $c = New-Canvas 2732 2732 $bgColor; $bmp = $c[0]; $g = $c[1]
    if ($bgImage) {
        $bg = [System.Drawing.Image]::FromFile($bgImage)
        Draw-Cover $g $bg 2732 2732
        $bg.Dispose()
    } else {
        $g.DrawImage($icon, 966, 966, 800, 800)
    }
    $g.Dispose()
    $bmp.Save("$assets\splash.png", [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Save("$assets\splash-dark.png", [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $iconBmp.Dispose(); $icon.Dispose()
}

# ------------------------------------------------------------ build pipeline ---
function Build-Apk([hashtable]$cfg) {
    # Input guards (empty strings first - Join-Path/Test-Path choke on them)
    if (-not $cfg.GameDir) { throw "No game export folder given." }
    $cfg.GameDir = Resolve-GameDir $cfg.GameDir
    if (-not (Test-Path (Join-Path $cfg.GameDir "index.html"))) { throw "Game folder has no index.html (not a web export): $($cfg.GameDir)" }
    if (-not $cfg.IconPath) { throw "No icon image given." }
    if (-not (Test-Path $cfg.IconPath -PathType Leaf)) { throw "Icon image not found: $($cfg.IconPath)" }
    if ($cfg.BackgroundImage -and -not (Test-Path $cfg.BackgroundImage -PathType Leaf)) { throw "Background image not found: $($cfg.BackgroundImage)" }
    if (-not $cfg.OutputDir) { $cfg.OutputDir = Join-Path $ToolDir "output" }
    if (-not $cfg.VersionName) { $cfg.VersionName = "1.0" }

    $title    = $cfg.GameTitle
    $devSafe  = Sanitize-Name $cfg.DevName
    $gameSafe = Sanitize-Name $title
    if (-not $devSafe -or -not $gameSafe) { throw "Developer name and game title must contain letters/numbers." }
    $package  = "com.$devSafe.$gameSafe"
    $projDir  = Join-Path $ProjectsDir $gameSafe
    $wwwDir   = Join-Path $projDir "www"
    $androidDir = Join-Path $projDir "android"
    $stateFile = Join-Path $projDir "builder-state.json"

    # If the package changed (e.g. the developer name was edited), the native
    # project must be regenerated - it bakes the package into its gradle,
    # manifest and java files at creation time. versionCode continues from
    # the saved state, so updates still install over old builds.
    if ((Test-Path $androidDir) -and (Test-Path $stateFile)) {
        try {
            $prev = Get-Content $stateFile -Raw | ConvertFrom-Json
            $prevPkg = "com." + (Sanitize-Name $prev.DevName) + "." + (Sanitize-Name $prev.GameTitle)
            if ($prevPkg -ne $package) {
                Write-Log "== Package changed ($prevPkg -> $package): regenerating the Android project"
                Remove-Item $androidDir -Recurse -Force
            }
        } catch { }
    }

    Write-Log "Game:    $title"
    Write-Log "Package: $package"
    Write-Log "Project: $projDir"

    Ensure-Node
    $jdk = Ensure-Jdk
    # gradlew.bat needs a JVM to start at all, and it only looks at JAVA_HOME
    # or PATH - the org.gradle.java.home property we write is used later, for
    # compilation. Machines without any system Java failed here with
    # "JAVA_HOME is not set" (exit 9009), so point both at our own JDK.
    $env:JAVA_HOME = $jdk
    if ($env:PATH -notlike "*$jdk\bin*") {
        $env:PATH = (Join-Path $jdk "bin") + ";" + $env:PATH
    }
    Ensure-Sdk $jdk
    Ensure-Keystore

    # --- scaffold (first build only) ---
    if (-not (Test-Path (Join-Path $projDir "package.json"))) {
        New-Item -ItemType Directory -Force $projDir | Out-Null
        Write-TextFile (Join-Path $projDir "package.json") @"
{
  "name": "$gameSafe-android",
  "version": "1.0.0",
  "private": true,
  "dependencies": {
    "@capacitor/android": "^8.0.0",
    "@capacitor/app": "^8.0.0",
    "@capacitor/cli": "^8.0.0",
    "@capacitor/core": "^8.0.0"
  }
}
"@
    }
    Write-TextFile (Join-Path $projDir "capacitor.config.json") @"
{
  "appId": "$package",
  "appName": "$($title -replace '"', '')",
  "webDir": "www",
  "android": {
    "allowMixedContent": false,
    "backgroundColor": "$($cfg.BackgroundColor)"
  }
}
"@

    if (-not (Test-Path (Join-Path $projDir "node_modules\@capacitor\cli"))) {
        Run-Cmd "npm install (first build only)" $projDir "npm.cmd" @("install", "--no-fund", "--no-audit")
    }

    # --- copy the game fresh, then apply the patch on top ---
    Run-Cmd "Copying game export" $projDir "robocopy" @($cfg.GameDir, $wwwDir, "/MIR", "/XF", "package.json", "/NFL", "/NDL", "/NJH", "/NJS") @(0,1,2,3,4,5,6,7)

    # background image
    $bodyBg = $cfg.BackgroundColor
    if ($cfg.BackgroundImage) {
        $ext = [IO.Path]::GetExtension($cfg.BackgroundImage)
        Copy-Item $cfg.BackgroundImage (Join-Path $wwwDir "background$ext") -Force
        $bodyBg = "$($cfg.BackgroundColor) url(`"background$ext`") center center / cover no-repeat"
    }

    # frame
    $frameCss = ""
    $frameDiv = ""
    if ($cfg.FrameEnabled) {
        $fc = Parse-HexColor $cfg.FrameColor "#bababa"
        $alpha = [Math]::Round($cfg.FrameOpacity / 100.0, 2)
        # canvas width on a phone = aspect * (screen height minus V-margins)
        $aspect = Get-GameAspect $cfg.GameDir
        $widthVh = [Math]::Round($aspect * (100 - 2 * $cfg.VMargin) + 2 * $cfg.FrameMargin, 1)
        $frameCss = @"
            #game-frame {
                position: fixed;
                top: 0;
                left: 50%;
                transform: translateX(-50%);
                height: 100%;
                width: min(${widthVh}vh, 100vw);
                background: rgba($($fc.R), $($fc.G), $($fc.B), $alpha);
                box-shadow: 0 0 5vh rgba(0, 0, 0, 0.4);
                z-index: 0;
                pointer-events: none;
            }
"@
        $frameDiv = '        <div id="game-frame"></div>'
    }

    # Patch the game's own index.html rather than replacing it - MV loads
    # its engine via a list of <script> tags that must be preserved, while
    # MZ loads everything through js/main.js. Both survive this patching.
    $indexPath = Join-Path $wwwDir "index.html"
    $ih = Get-Content $indexPath -Raw
    $viewport = '<meta name="viewport" content="width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">'
    if ($ih -match '(?i)<meta\s+name="viewport"') {
        $ih = Edit-Once $ih '<meta\s+name="viewport"[^>]*>' $viewport
    } else {
        $ih = Edit-Once $ih '<head>' ("<head>`n        " + $viewport)
    }
    $styleBlock = @"
        <style>
            /* Full-height page so the background sizes against the screen
               (the game canvas is absolutely positioned). */
            html, body { width: 100%; height: 100%; margin: 0; }
            body { background: $bodyBg; }
$frameCss
        </style>
"@
    $ih = Edit-Once $ih '</head>' ($styleBlock + "`n    </head>")
    $ih = Edit-Once $ih '<body[^>]*>' ("<body>" + $(if ($frameDiv) { "`n" + $frameDiv } else { "" }))
    $ih = Edit-Once $ih '</body>' ("    <script type=`"text/javascript`" src=`"js/mobile-controls.js`"></script>`n    </body>")
    Write-TextFile $indexPath $ih

    $bc = Parse-HexColor $cfg.ButtonColor "#14507e"
    $extraKey = ([string]$cfg.ExtraKey).Trim().ToUpper()
    if (-not $extraKey) { $extraKey = "C" }
    $extraCode = [int][char]$extraKey[0]
    $controls = (Get-Content (Join-Path $TemplateDir "mobile-controls.js.template") -Raw)
    $controls = $controls.Replace("{{SCALE}}", [string][Math]::Round($cfg.ControlsSize / 100.0, 2))
    $controls = $controls.Replace("{{OPACITY}}", [string][Math]::Round($cfg.ControlsOpacity / 100.0, 2))
    $controls = $controls.Replace("{{BTN_COLOR_RGBA}}", "rgba($($bc.R), $($bc.G), $($bc.B), 0.9)")
    $controls = $controls.Replace("{{BTN_COLOR}}", $cfg.ButtonColor)
    $controls = $controls.Replace("{{EXTRA_ENABLED}}", $(if ($cfg.ExtraButton) { "true" } else { "false" }))
    $controls = $controls.Replace("{{EXTRA_KEY}}", $extraKey[0])
    $controls = $controls.Replace("{{EXTRA_CODE}}", [string]$extraCode)
    $controls = $controls.Replace("{{GAME_VMARGIN}}", [string][Math]::Round($cfg.VMargin / 100.0, 3))
    $audioExt = Get-AudioExt $cfg.GameDir
    if ($audioExt) { Write-Log "   audio files are $audioExt - pinning that extension (MV asks for .m4a on mobile)" }
    $controls = $controls.Replace("{{AUDIO_EXT}}", $audioExt)
    Write-TextFile (Join-Path $wwwDir "js\mobile-controls.js") $controls

    # --- native project (first build only) ---
    if (-not (Test-Path $androidDir)) {
        Run-Cmd "Creating Android project (first build only)" $projDir "npx.cmd" @("cap", "add", "android")
    }

    # per-machine paths (safe to rewrite every build)
    Write-TextFile (Join-Path $androidDir "local.properties") "sdk.dir=$($SdkDir -replace '\\', '\\')"
    $gp = Join-Path $androidDir "gradle.properties"
    if ((Get-Content $gp -Raw) -notmatch "org\.gradle\.java\.home") {
        Add-Content $gp "`norg.gradle.java.home=$($jdk -replace '\\', '\\')"
    }
    Copy-Item (Join-Path $KeysDir "key.properties") (Join-Path $androidDir "key.properties") -Force

    # MainActivity (fullscreen immersive + keep screen on)
    $pkgPath = Join-Path $androidDir ("app\src\main\java\" + ($package -replace "\.", "\"))
    New-Item -ItemType Directory -Force $pkgPath | Out-Null
    Write-TextFile (Join-Path $pkgPath "MainActivity.java") ((Get-Content (Join-Path $TemplateDir "MainActivity.java.template") -Raw).Replace("{{PACKAGE}}", $package))

    # manifest: landscape lock (idempotent; always rewritten BOM-free -
    # a BOM here breaks @capacitor/assets' XML parser)
    $manifest = Join-Path $androidDir "app\src\main\AndroidManifest.xml"
    $mc = Get-Content $manifest -Raw
    if ($mc -notmatch "screenOrientation") {
        $mc = $mc.Replace('android:name=".MainActivity"', "android:screenOrientation=`"sensorLandscape`"`n            android:name=`".MainActivity`"")
    }
    Write-TextFile $manifest $mc

    # build.gradle: signing + version (idempotent inserts, version rewritten)
    $bg = Join-Path $androidDir "app\build.gradle"
    $gc = Get-Content $bg -Raw
    if ($gc -notmatch "keystoreProperties") {
        $gc = $gc.Replace("apply plugin: 'com.android.application'", @"
apply plugin: 'com.android.application'

def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
"@)
        $gc = $gc.Replace("    buildTypes {", @"
    signingConfigs {
        release {
            if (keystorePropertiesFile.exists()) {
                storeFile file(keystoreProperties['storeFile'])
                storePassword keystoreProperties['storePassword']
                keyAlias keystoreProperties['keyAlias']
                keyPassword keystoreProperties['keyPassword']
            }
        }
    }
    buildTypes {
"@)
        $gc = $gc.Replace("            proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'", @"
            proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
            signingConfig signingConfigs.release
"@)
    }

    # version: auto-increment versionCode per build ($stateFile set above)
    $vc = 1
    if (Test-Path $stateFile) {
        try { $vc = ([int](Get-Content $stateFile -Raw | ConvertFrom-Json).versionCode) + 1 } catch { $vc = 1 }
    }
    $gc = $gc -replace "versionCode \d+", "versionCode $vc"
    $gc = $gc -replace 'versionName "[^"]*"', "versionName `"$($cfg.VersionName)`""
    Write-TextFile $bg $gc

    # --- icons / splash ---
    Write-Log "== Generating icons and splash screens"
    Set-Progress -text "Generating icons and splash screens"
    New-ImageAssets $projDir $cfg.IconPath $cfg.BackgroundImage (Parse-HexColor $cfg.BackgroundColor "#000000")
    Run-Cmd "Rendering Android image densities" $projDir "npx.cmd" @("--yes", "@capacitor/assets", "generate", "--android")

    # --- sync + build ---
    Run-Cmd "Syncing web assets into Android project" $projDir "npx.cmd" @("cap", "sync", "android")
    Run-Cmd "Building APK (first build downloads Gradle deps; later builds are fast)" $androidDir ".\gradlew.bat" @("assembleRelease", "--no-daemon", "--console=plain")

    $apk = Join-Path $androidDir "app\build\outputs\apk\release\app-release.apk"
    if (-not (Test-Path $apk)) { throw "Build reported success but APK not found at $apk" }
    New-Item -ItemType Directory -Force $cfg.OutputDir | Out-Null
    $safeFile = ($title -replace '[\\/:*?"<>|]', "") + " v" + $cfg.VersionName + ".apk"
    $dest = Join-Path $cfg.OutputDir $safeFile
    Copy-Item $apk $dest -Force

    # remember settings + build number for next time
    $cfg2 = @{} + $cfg
    $cfg2.versionCode = $vc
    Write-TextFile $stateFile ($cfg2 | ConvertTo-Json)

    Write-Log ""
    Write-Log "=========================================================="
    Write-Log " DONE: $dest"
    Write-Log " Signed with your local key ($KeysDir) - good for itch.io"
    Write-Log " and sideloading. Not a Play Store upload (Play needs an"
    Write-Log " AAB + store setup). versionCode $vc, version $($cfg.VersionName)."
    Write-Log "=========================================================="
    return $dest
}

# ================================================================= headless ==
Add-Type -AssemblyName System.Drawing
if ($NoGui) {
    if (-not $GameDir) { throw "-GameDir is required with -NoGui" }
    # resolve www/ subfolders BEFORE deriving title/icon defaults from it
    $GameDir = Resolve-GameDir $GameDir
    $cfg = @{
        GameDir = $GameDir; DevName = $DevName; GameTitle = $GameTitle
        VersionName = $VersionName; IconPath = $IconPath
        BackgroundImage = $BackgroundImage; BackgroundColor = $BackgroundColor
        FrameEnabled = (-not $NoFrame); FrameColor = $FrameColor
        FrameOpacity = $FrameOpacity; FrameMargin = $FrameMargin
        VMargin = $VMargin
        ButtonColor = $ButtonColor; ControlsOpacity = $ControlsOpacity
        ControlsSize = $ControlsSize; ExtraButton = [bool]$ExtraButton
        ExtraKey = $ExtraKey; OutputDir = $OutputDir
    }
    if (-not $cfg.GameTitle) { $cfg.GameTitle = Get-GameTitle $GameDir }
    if (-not $cfg.IconPath) { $cfg.IconPath = Join-Path $GameDir "icon\icon.png" }
    $null = Build-Apk $cfg
    exit 0
}

# ====================================================================== GUI ==
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::EnableVisualStyles()

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne "STA") {
    Start-Process powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-File", "`"$PSCommandPath`"")
    exit 0
}

# Node.js is required for everything - refuse to open without it.
if (-not (Test-NodeInstalled)) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "RMMZ APK Builder needs Node.js, which is not installed on this PC.`n`nOpen the download page now?`nhttps://nodejs.org/en/download`n`nInstall it (default options are fine), then start this app again.",
        "Node.js required", "YesNo", "Warning")
    if ($r -eq "Yes") { Start-Process "https://nodejs.org/en/download" }
    exit 1
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "RMMZ APK Builder"
$form.ClientSize = New-Object System.Drawing.Size(1232, 780)
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$script:PreviewBgImg = $null
$script:GameAspect = 816.0 / 624.0

function New-Control([string]$type, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text, $parent) {
    $c = New-Object ("System.Windows.Forms." + $type)
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }
    $parent.Controls.Add($c)
    return $c
}

# ---- header ----
$header = New-Control "Panel" 0 0 1232 54 "" $form
$lblTitle = New-Control "Label" 16 6 320 28 "RMMZ APK Builder" $header
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$lblSub = New-Control "Label" 18 34 640 16 "RPG Maker MV / MZ web export  >  Android APK  (itch.io / sideloading)" $header
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$btnHelp = New-Control "Button" 1040 12 84 30 "Help" $header
$chkDark = New-Control "CheckBox" 1140 16 80 24 "Dark" $header
$chkDark.Checked = $true

# ---- credit: pfp + "Made by Doma" (link) ----
$pfpBox = New-Control "PictureBox" 828 9 36 36 "" $header
$pfpBox.SizeMode = "Zoom"
# Embedded credit picture (base64 PNG, pre-cropped to a circle) - no
# external file involved.
$pfpBase64 = "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"
try {
    $script:PfpStream = New-Object System.IO.MemoryStream(, [Convert]::FromBase64String($pfpBase64))
    $pfpBox.Image = [System.Drawing.Image]::FromStream($script:PfpStream)
} catch { }
$lnkDoma = New-Object System.Windows.Forms.LinkLabel
$lnkDoma.Location = New-Object System.Drawing.Point(870, 18)
$lnkDoma.AutoSize = $true
$lnkDoma.Text = "Made by Doma"
$lnkDoma.LinkArea = New-Object System.Windows.Forms.LinkArea(8, 4)
$lnkDoma.LinkBehavior = "HoverUnderline"
$lnkDoma.Add_LinkClicked({ Start-Process "https://linktr.ee/aak581" })
$header.Controls.Add($lnkDoma)

# ---- Game group ----
$gbGame = New-Control "GroupBox" 16 66 600 200 "Game" $form
$null = New-Control "Label" 12 28 124 18 "Game export folder" $gbGame
$txtGame = New-Control "TextBox" 140 25 330 22 "" $gbGame
$btnGame = New-Control "Button" 476 24 36 24 "..." $gbGame
$null = New-Control "Label" 12 60 124 18 "Game title" $gbGame
$txtTitle = New-Control "TextBox" 140 57 372 22 "" $gbGame
$null = New-Control "Label" 12 92 124 18 "Developer name" $gbGame
$txtDev = New-Control "TextBox" 140 89 150 22 $DevName $gbGame
$null = New-Control "Label" 306 92 52 18 "Version" $gbGame
$txtVer = New-Control "TextBox" 360 89 70 22 "1.0" $gbGame
$null = New-Control "Label" 12 124 124 18 "Icon image" $gbGame
$txtIcon = New-Control "TextBox" 140 121 330 22 "" $gbGame
$btnIcon = New-Control "Button" 476 120 36 24 "..." $gbGame
$null = New-Control "Label" 12 156 124 18 "Output folder" $gbGame
$txtOut = New-Control "TextBox" 140 153 330 22 (Join-Path $ToolDir "output") $gbGame
$btnOut = New-Control "Button" 476 152 36 24 "..." $gbGame

# ---- Appearance group ----
$gbLook = New-Control "GroupBox" 16 276 600 212 "Appearance" $form
$null = New-Control "Label" 12 28 124 18 "Background image" $gbLook
$txtBgImg = New-Control "TextBox" 140 25 296 22 "" $gbLook
$btnBgImg = New-Control "Button" 442 24 36 24 "..." $gbLook
$btnBgClr = New-Control "Button" 482 24 30 24 "X" $gbLook
$null = New-Control "Label" 12 60 124 18 "Background color" $gbLook
$txtBgCol = New-Control "TextBox" 140 57 70 22 "#000000" $gbLook
$btnBgCol = New-Control "Button" 216 56 40 24 "pick" $gbLook

$chkFrame = New-Control "CheckBox" 14 92 70 22 "Frame" $gbLook
$chkFrame.Checked = $true
$null = New-Control "Label" 86 95 40 18 "Color" $gbLook
$txtFrCol = New-Control "TextBox" 126 92 60 22 "#bababa" $gbLook
$btnFrCol = New-Control "Button" 190 91 42 24 "pick" $gbLook
$null = New-Control "Label" 238 95 38 18 "Op. %" $gbLook
$numFrOp = New-Control "NumericUpDown" 278 92 44 22 "" $gbLook
$numFrOp.Minimum = 0; $numFrOp.Maximum = 100; $numFrOp.Value = 50
$null = New-Control "Label" 332 95 34 18 "Side" $gbLook
$numFrMg = New-Control "NumericUpDown" 368 92 44 22 "" $gbLook
$numFrMg.Minimum = 0; $numFrMg.Maximum = 15; $numFrMg.Value = 4
$null = New-Control "Label" 422 95 32 18 "Vert" $gbLook
$numVMg = New-Control "NumericUpDown" 456 92 44 22 "" $gbLook
$numVMg.Minimum = 0; $numVMg.Maximum = 15; $numVMg.Value = 5

$null = New-Control "Label" 12 131 100 18 "Buttons color" $gbLook
$txtBtCol = New-Control "TextBox" 140 128 62 22 "#14507e" $gbLook
$btnBtCol = New-Control "Button" 206 127 40 24 "pick" $gbLook
$null = New-Control "Label" 284 131 60 18 "Opacity %" $gbLook
$numCtOp = New-Control "NumericUpDown" 344 128 46 22 "" $gbLook
$numCtOp.Minimum = 5; $numCtOp.Maximum = 100; $numCtOp.Value = 55
$null = New-Control "Label" 398 131 46 18 "Size %" $gbLook
$numCtSz = New-Control "NumericUpDown" 444 128 46 22 "" $gbLook
$numCtSz.Minimum = 50; $numCtSz.Maximum = 160; $numCtSz.Value = 100

$chkExtra = New-Control "CheckBox" 14 166 150 22 "Extra button, key:" $gbLook
$cmbExtra = New-Control "ComboBox" 168 164 62 22 "" $gbLook
$cmbExtra.DropDownStyle = "DropDownList"
# Z, X and SHIFT already exist as dedicated buttons - don't offer duplicates.
foreach ($ch in (65..90 | ForEach-Object { [char]$_ })) {
    if ("Z", "X" -notcontains [string]$ch) { [void]$cmbExtra.Items.Add([string]$ch) }
}
$cmbExtra.SelectedItem = "C"
$lblExtraHint = New-Control "Label" 240 168 340 18 "sends that keyboard key (for plugin keybinds etc.)" $gbLook
$lblExtraHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)

# ---- build button ----
$btnBuild = New-Control "Button" 16 500 600 42 "BUILD  APK" $form
$btnBuild.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnBuild.FlatStyle = "Flat"

# ---- preview ----
$pv = New-Control "Panel" 640 66 576 259 "" $form
$pv.BorderStyle = "FixedSingle"
$pv.GetType().GetProperty("DoubleBuffered", [Reflection.BindingFlags]"NonPublic,Instance").SetValue($pv, $true, $null)
$lblPv = New-Control "Label" 640 330 400 16 "Preview - 2400x1080 landscape phone" $form
$lblPv.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$hint1 = New-Control "Label" 640 354 576 16 "Background image: 2400x1080 recommended. Side strips stay visible; the center sits behind the game." $form
$hint2 = New-Control "Label" 640 372 576 16 "Icon: square, 512x512 or larger (1024x1024 is ideal)." $form
$hint3 = New-Control "Label" 640 390 576 32 "First build on a PC downloads build tools once (~900 MB: JDK + Android SDK + Gradle). After that, builds take a minute or two. Settings and update numbering are remembered per game." $form
foreach ($h in @($hint1, $hint2, $hint3)) { $h.Font = New-Object System.Drawing.Font("Segoe UI", 8) }

# ---- log ----
$script:StatusLabel = New-Control "Label" 640 436 576 18 "" $form
$script:ProgBar = New-Object System.Windows.Forms.ProgressBar
$script:ProgBar.Location = New-Object System.Drawing.Point(640, 458)
$script:ProgBar.Size = New-Object System.Drawing.Size(576, 22)
$script:ProgBar.Style = "Continuous"
$script:ProgBar.MarqueeAnimationSpeed = 30
$form.Controls.Add($script:ProgBar)

$lblLog = New-Control "Label" 16 552 100 18 "Build log" $form
$btnClear = New-Control "Button" 1132 546 84 26 "Clear log" $form
$script:LogBox = New-Control "TextBox" 16 576 1200 190 "" $form
$script:LogBox.Multiline = $true
$script:LogBox.ScrollBars = "Vertical"
$script:LogBox.ReadOnly = $true
$script:LogBox.Font = New-Object System.Drawing.Font("Consolas", 8.5)

# ---- theming ----
# Remembers the theme and the developer name (so it is typed once per PC).
function Save-GuiSettings {
    try {
        $name = ""
        if ($txtDev) { $name = $txtDev.Text }
        Write-TextFile $GuiSettings (@{ dark = $chkDark.Checked; devName = $name } | ConvertTo-Json)
    } catch { }
}

function Apply-Theme([bool]$dark) {
    if ($dark) {
        $bg     = [System.Drawing.Color]::FromArgb(30, 30, 32)
        $fg     = [System.Drawing.Color]::FromArgb(228, 228, 230)
        $sub    = [System.Drawing.Color]::FromArgb(150, 150, 155)
        $inBg   = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $inFg   = [System.Drawing.Color]::FromArgb(238, 238, 240)
        $btnBg  = [System.Drawing.Color]::FromArgb(62, 62, 66)
        $logBg  = [System.Drawing.Color]::FromArgb(18, 18, 20)
        $logFg  = [System.Drawing.Color]::FromArgb(200, 205, 210)
        $accent = [System.Drawing.Color]::FromArgb(45, 125, 210)
        $pvBg   = [System.Drawing.Color]::FromArgb(10, 10, 12)
    } else {
        $bg     = [System.Drawing.SystemColors]::Control
        $fg     = [System.Drawing.Color]::Black
        $sub    = [System.Drawing.Color]::DimGray
        $inBg   = [System.Drawing.Color]::White
        $inFg   = [System.Drawing.Color]::Black
        $btnBg  = [System.Drawing.Color]::WhiteSmoke
        $logBg  = [System.Drawing.Color]::White
        $logFg  = [System.Drawing.Color]::Black
        $accent = [System.Drawing.Color]::FromArgb(26, 111, 196)
        $pvBg   = [System.Drawing.Color]::Black
    }
    $form.BackColor = $bg
    $header.BackColor = $bg
    function Walk($ctrl) {
        foreach ($c in $ctrl.Controls) {
            if ($c -is [System.Windows.Forms.NumericUpDown]) {
                # do not recurse into its internal spinner controls
                $c.BackColor = $inBg; $c.ForeColor = $inFg
                continue
            }
            if ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.ComboBox]) {
                $c.BackColor = $inBg; $c.ForeColor = $inFg
            } elseif ($c -is [System.Windows.Forms.Button]) {
                $c.BackColor = $btnBg; $c.ForeColor = $fg
                $c.FlatStyle = "Flat"; $c.FlatAppearance.BorderColor = $sub
            } elseif ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.GroupBox]) {
                $c.ForeColor = $fg; $c.BackColor = [System.Drawing.Color]::Transparent
            } else {
                $c.ForeColor = $fg
            }
            if ($c.Controls.Count -gt 0) { Walk $c }
        }
    }
    Walk $form
    foreach ($h in @($lblSub, $lblPv, $hint1, $hint2, $hint3, $lblExtraHint, $script:StatusLabel)) { $h.ForeColor = $sub }
    $script:LogBox.BackColor = $logBg
    $script:LogBox.ForeColor = $logFg
    $btnBuild.BackColor = $accent
    $btnBuild.ForeColor = [System.Drawing.Color]::White
    $btnBuild.FlatAppearance.BorderColor = $accent
    $lnkDoma.ForeColor = $fg
    $lnkDoma.LinkColor = $accent
    $lnkDoma.ActiveLinkColor = $accent
    $lnkDoma.VisitedLinkColor = $accent
    $pv.BackColor = $pvBg
    $pv.Invalidate()
    Save-GuiSettings
}

# ---- preview paint ----
$pv.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $W = [double]$s.ClientSize.Width
    $H = [double]$s.ClientSize.Height

    $g.Clear((Parse-HexColor $txtBgCol.Text "#000000"))
    if ($script:PreviewBgImg) { Draw-Cover $g $script:PreviewBgImg $W $H }

    # Game canvas: full height minus the V-margin per side, centered.
    $vm2 = [double]$numVMg.Value / 100.0
    $gh = (1 - 2 * $vm2) * $H
    $gw = $script:GameAspect * $gh
    $gx = ($W - $gw) / 2
    $gy = ($H - $gh) / 2

    if ($chkFrame.Checked) {
        $fc = Parse-HexColor $txtFrCol.Text "#bababa"
        $fw = [Math]::Min(($script:GameAspect * (100 - 2 * [double]$numVMg.Value) + 2 * [double]$numFrMg.Value) / 100 * $H, $W)
        $fa = [int]([double]$numFrOp.Value * 2.55)
        $fb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($fa, $fc.R, $fc.G, $fc.B))
        $g.FillRectangle($fb, [float](($W - $fw) / 2), 0, [float]$fw, [float]$H)
        $fb.Dispose()
    }

    $gb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 12, 12, 12))
    $g.FillRectangle($gb, [float]$gx, [float]$gy, [float]$gw, [float]$gh)
    $gb.Dispose()
    $font = New-Object System.Drawing.Font("Segoe UI", [float]($H * 0.06), [System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = "Center"; $sf.LineAlignment = "Center"
    $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 255, 255, 255))
    $g.DrawString("GAME", $font, $tb, (New-Object System.Drawing.RectangleF([float]$gx, [float]$gy, [float]$gw, [float]$gh)), $sf)
    $tb.Dispose(); $font.Dispose(); $sf.Dispose()

    $bc = Parse-HexColor $txtBtCol.Text "#14507e"
    $alpha = [int]([double]$numCtOp.Value * 2.55)
    $cb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, $bc.R, $bc.G, $bc.B))
    $scale = [double]$numCtSz.Value / 100.0
    $vm = $H / 100.0

    $ds = 42 * $vm * $scale
    $dx = 3 * $vm
    $dy = $H - 8 * $vm - $ds
    $arm = $ds * 0.33
    $g.FillRectangle($cb, [float]$dx, [float]($dy + ($ds - $arm) / 2), [float]$ds, [float]$arm)
    $g.FillRectangle($cb, [float]($dx + ($ds - $arm) / 2), [float]$dy, [float]$arm, [float]$ds)

    $cell = 16 * $vm * $scale
    $gap = 3 * $vm
    $bx2 = $W - 3 * $vm - $cell
    $bx1 = $bx2 - $gap - $cell
    $by2 = $H - 8 * $vm - $cell
    $by1 = $by2 - $gap - $cell
    $bfont = New-Object System.Drawing.Font("Segoe UI", [float][Math]::Max($cell * 0.22, 5), [System.Drawing.FontStyle]::Bold)
    $wb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([Math]::Min(255, $alpha + 60), 240, 244, 248))
    $sf2 = New-Object System.Drawing.StringFormat
    $sf2.Alignment = "Center"; $sf2.LineAlignment = "Center"
    $defs = @()
    if ($chkExtra.Checked) { $defs += , @($bx1, $by1, [string]$cmbExtra.SelectedItem) }
    $defs += , @($bx2, $by1, "Z")
    $defs += , @($bx1, $by2, "SHIFT")
    $defs += , @($bx2, $by2, "X")
    foreach ($def in $defs) {
        $g.FillRectangle($cb, [float]$def[0], [float]$def[1], [float]$cell, [float]$cell)
        $g.DrawString($def[2], $bfont, $wb, (New-Object System.Drawing.RectangleF([float]$def[0], [float]$def[1], [float]$cell, [float]$cell)), $sf2)
    }

    # controls-visibility toggle (bottom center; players start with controls
    # hidden and a "+" - the preview shows the shown state, so draw "-")
    $td = 7 * $vm
    $tx = ($W - $td) / 2
    $ty = $H - 1 * $vm - $td
    $tb2 = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(128, 20, 20, 20))
    $g.FillEllipse($tb2, [float]$tx, [float]$ty, [float]$td, [float]$td)
    $g.DrawString("-", $bfont, $wb, (New-Object System.Drawing.RectangleF([float]$tx, [float]$ty, [float]$td, [float]$td)), $sf2)
    $tb2.Dispose()
    $cb.Dispose(); $wb.Dispose(); $bfont.Dispose(); $sf2.Dispose()
})

# ---- events ----
$refresh = { $pv.Invalidate() }
foreach ($c in @($txtBgCol, $txtFrCol, $txtBtCol)) { $c.Add_TextChanged($refresh) }
foreach ($c in @($numFrOp, $numFrMg, $numVMg, $numCtOp, $numCtSz)) { $c.Add_ValueChanged($refresh) }
$chkFrame.Add_CheckedChanged($refresh)
$chkExtra.Add_CheckedChanged($refresh)
$cmbExtra.Add_SelectedIndexChanged($refresh)
$chkDark.Add_CheckedChanged({ Apply-Theme $chkDark.Checked })

$txtBgImg.Add_TextChanged({
    if ($script:PreviewBgImg) { $script:PreviewBgImg.Dispose(); $script:PreviewBgImg = $null }
    if (Test-Path $txtBgImg.Text -PathType Leaf) {
        try { $script:PreviewBgImg = [System.Drawing.Image]::FromFile($txtBgImg.Text) } catch { }
    }
    $pv.Invalidate()
})

$btnGame.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Select the RPG Maker MZ web export folder (contains index.html)"
    if ($d.ShowDialog() -eq "OK") {
        $resolved = Resolve-GameDir $d.SelectedPath
        $txtGame.Text = $resolved
        $txtTitle.Text = Get-GameTitle $resolved
        $script:GameAspect = Get-GameAspect $resolved
        $pv.Invalidate()
        $defIcon = Join-Path $resolved "icon\icon.png"
        if ((-not $txtIcon.Text) -and (Test-Path $defIcon)) { $txtIcon.Text = $defIcon }
        $state = Join-Path (Join-Path $ProjectsDir (Sanitize-Name $txtTitle.Text)) "builder-state.json"
        if (Test-Path $state) {
            try {
                $s = Get-Content $state -Raw | ConvertFrom-Json
                $txtDev.Text = $s.DevName; $txtVer.Text = $s.VersionName
                $txtIcon.Text = $s.IconPath; $txtBgImg.Text = [string]$s.BackgroundImage
                $txtBgCol.Text = $s.BackgroundColor
                $chkFrame.Checked = [bool]$s.FrameEnabled
                $txtFrCol.Text = $s.FrameColor; $numFrOp.Value = [int]$s.FrameOpacity
                $numFrMg.Value = [decimal]$s.FrameMargin
                if ($null -ne $s.VMargin) { $numVMg.Value = [decimal]$s.VMargin }
                $txtBtCol.Text = $s.ButtonColor
                $numCtOp.Value = [int]$s.ControlsOpacity; $numCtSz.Value = [int]$s.ControlsSize
                if ($null -ne $s.ExtraButton) { $chkExtra.Checked = [bool]$s.ExtraButton }
                if ($s.ExtraKey) { $cmbExtra.SelectedItem = [string]$s.ExtraKey }
                $txtOut.Text = $s.OutputDir
                Write-Log "Restored previous settings for '$($txtTitle.Text)' (next build = versionCode $([int]$s.versionCode + 1))."
            } catch { }
        }
    }
})

$pickImage = {
    param($target)
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Filter = "Images|*.png;*.jpg;*.jpeg;*.webp|All files|*.*"
    if ($d.ShowDialog() -eq "OK") { $target.Text = $d.FileName }
}
$btnIcon.Add_Click({ & $pickImage $txtIcon })
$btnBgImg.Add_Click({ & $pickImage $txtBgImg })
$btnBgClr.Add_Click({ $txtBgImg.Text = "" })
$btnOut.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($d.ShowDialog() -eq "OK") { $txtOut.Text = $d.SelectedPath }
})

$pickColor = {
    param($target)
    $d = New-Object System.Windows.Forms.ColorDialog
    $d.Color = Parse-HexColor $target.Text "#000000"
    $d.FullOpen = $true
    if ($d.ShowDialog() -eq "OK") {
        $target.Text = "#{0:x2}{1:x2}{2:x2}" -f $d.Color.R, $d.Color.G, $d.Color.B
    }
}
$btnBgCol.Add_Click({ & $pickColor $txtBgCol })
$btnFrCol.Add_Click({ & $pickColor $txtFrCol })
$btnBtCol.Add_Click({ & $pickColor $txtBtCol })

$btnClear.Add_Click({ $script:LogBox.Clear() })

$btnHelp.Add_Click({
    $paragraphs = @(
        "WHAT THIS APP DOES",
        "Wraps an RPG Maker MV or MZ web export in a native Android app and builds an installable APK: fullscreen landscape, on-screen touch controls (d-pad, Z / X / SHIFT and an optional extra key button), Android back button opens the game menu, mobile GPU rendering fixes, your background art around the game window, and an optional itch-style frame. MV desktop exports (with the game inside a www folder) are detected automatically.",
        "",
        "The touch controls start hidden behind a small round '+' button at the bottom center (like the Maldives player). Tapping it shows them and turns it into a minus; the player's choice is remembered between sessions.",
        "",
        "HOW TO USE",
        "1. Pick the game export folder (the one with index.html). The title fills in automatically; the icon and all options are remembered per game.",
        "2. Pick an icon (square, 512x512 or larger) and optionally a background image (2400x1080 recommended) and colors. The preview updates live.",
        "3. Click BUILD APK. The first ever build downloads build tools (~900 MB, once) and takes a while; rebuilds take a minute or two.",
        "4. Upload the APK from the output folder to itch.io (or install it directly on a phone).",
        "",
        "FRAME AND MARGINS",
        "The frame is a colored panel behind the game window. 'Side' is how far it extends past the game on each side. 'Vert' is the empty space above and below the game itself: 0 makes the game fill the full screen height, 5 is the engine's default look, bigger values shrink the game so the frame shows on all four sides.",
        "",
        "UPDATES",
        "Rebuilding the same game auto-increases the internal version number, so players can install the new APK over the old one without losing their saves.",
        "",
        "SIGNING",
        "Android refuses unsigned apps, so a private signing key is created once in Documents\android-keys and reused for all your games. BACK THAT FOLDER UP - updates must be signed with the same key. No Google account is involved. These APKs are for itch.io and sideloading; publishing on Google Play would need a different pipeline (AAB, store listing, etc.).",
        "",
        "REQUIREMENTS",
        "Node.js (checked at startup). Everything else (JDK, Android SDK, Gradle) is downloaded automatically on the first build."
    )

    $dark = $chkDark.Checked
    $hForm = New-Object System.Windows.Forms.Form
    $hForm.Text = "RMMZ APK Builder - Help"
    $hForm.ClientSize = New-Object System.Drawing.Size(860, 620)
    $hForm.StartPosition = "CenterParent"
    $hForm.MinimizeBox = $false
    $hForm.MaximizeBox = $false
    $hForm.ShowInTaskbar = $false
    $hForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $hText = New-Object System.Windows.Forms.TextBox
    $hText.Multiline = $true
    $hText.ReadOnly = $true
    $hText.WordWrap = $true
    $hText.ScrollBars = "Vertical"
    $hText.BorderStyle = "None"
    $hText.Location = New-Object System.Drawing.Point(20, 16)
    $hText.Size = New-Object System.Drawing.Size(820, 550)
    $hText.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $hText.Text = ($paragraphs -join "`r`n")
    $hForm.Controls.Add($hText)

    $hOk = New-Object System.Windows.Forms.Button
    $hOk.Text = "OK"
    $hOk.Size = New-Object System.Drawing.Size(110, 32)
    $hOk.Location = New-Object System.Drawing.Point(730, 578)
    $hOk.Add_Click({ $hForm.Close() })
    $hForm.Controls.Add($hOk)
    $hForm.AcceptButton = $hOk
    $hForm.CancelButton = $hOk

    if ($dark) {
        $hForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 32)
        $hText.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 32)
        $hText.ForeColor = [System.Drawing.Color]::FromArgb(228, 228, 230)
        $hOk.BackColor = [System.Drawing.Color]::FromArgb(62, 62, 66)
        $hOk.ForeColor = [System.Drawing.Color]::White
        $hOk.FlatStyle = "Flat"
        $hOk.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(150, 150, 155)
    }

    # deselect the auto-selected text
    $hForm.Add_Shown({ $hText.SelectionLength = 0; $hOk.Focus() })
    [void]$hForm.ShowDialog($form)
    $hForm.Dispose()
})

$btnBuild.Add_Click({
    # Collect every problem and show them all at once, in plain language.
    $problems = @()
    $gameDir = Resolve-GameDir $txtGame.Text.Trim()
    if (-not $gameDir) {
        $problems += "- Pick the game export folder (the one containing index.html)."
    } elseif (-not (Test-Path $gameDir -PathType Container)) {
        $problems += "- The game export folder does not exist: $gameDir"
    } elseif (-not (Test-Path (Join-Path $gameDir "index.html"))) {
        $problems += "- That folder has no index.html - it does not look like a web export."
    }
    if (-not $txtTitle.Text.Trim()) { $problems += "- Enter a game title." }
    elseif (-not (Sanitize-Name $txtTitle.Text)) { $problems += "- The game title needs at least one letter or number." }
    if (-not (Sanitize-Name $txtDev.Text)) { $problems += "- Enter a developer name (letters/numbers)." }
    if (-not $txtVer.Text.Trim()) { $problems += "- Enter a version, e.g. 1.0" }
    $iconPath = $txtIcon.Text.Trim()
    if (-not $iconPath) { $problems += "- Pick an icon image (square, 512x512 or larger)." }
    elseif (-not (Test-Path $iconPath -PathType Leaf)) { $problems += "- Icon image not found: $iconPath" }
    $bgImg = $txtBgImg.Text.Trim()
    if ($bgImg -and -not (Test-Path $bgImg -PathType Leaf)) { $problems += "- Background image not found: $bgImg" }
    foreach ($def in @(@($txtBgCol, "Background color"), @($txtFrCol, "Frame color"), @($txtBtCol, "Buttons color"))) {
        if ($def[0].Text -notmatch "^#?[0-9a-fA-F]{6}$") { $problems += "- $($def[1]) must be a hex color like #1a2b3c." }
    }
    if (-not $txtOut.Text.Trim()) { $txtOut.Text = Join-Path $ToolDir "output" }

    if ($problems.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Before building, please fix:`r`n`r`n" + ($problems -join "`r`n"),
            "Not ready to build", "OK", "Warning") | Out-Null
        return
    }

    try {
        $btnBuild.Enabled = $false
        $btnBuild.Text = "BUILDING..."
        Set-Progress -text "Starting..."
        $cfg = @{
            GameDir = $txtGame.Text; DevName = $txtDev.Text; GameTitle = $txtTitle.Text
            VersionName = $txtVer.Text; IconPath = $txtIcon.Text
            BackgroundImage = $txtBgImg.Text; BackgroundColor = $txtBgCol.Text
            FrameEnabled = $chkFrame.Checked; FrameColor = $txtFrCol.Text
            FrameOpacity = [int]$numFrOp.Value; FrameMargin = [double]$numFrMg.Value
            VMargin = [double]$numVMg.Value
            ButtonColor = $txtBtCol.Text; ControlsOpacity = [int]$numCtOp.Value
            ControlsSize = [int]$numCtSz.Value
            ExtraButton = $chkExtra.Checked; ExtraKey = [string]$cmbExtra.SelectedItem
            OutputDir = $txtOut.Text
        }
        $apk = Build-Apk $cfg
        Set-Progress -text "Done" -percent 100
        Save-GuiSettings
        [System.Windows.Forms.MessageBox]::Show("APK ready:`n$apk", "RMMZ APK Builder", "OK", "Information") | Out-Null
    } catch {
        Write-Log ("ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Build failed", "OK", "Error") | Out-Null
    } finally {
        $btnBuild.Enabled = $true
        $btnBuild.Text = "BUILD  APK"
        $script:ProgBar.Style = "Continuous"
        $script:ProgBar.Value = 0
        $script:StatusLabel.Text = ""
    }
})

# restore theme preference
$darkPref = $true
if (Test-Path $GuiSettings) {
    try {
        $saved = Get-Content $GuiSettings -Raw | ConvertFrom-Json
        $darkPref = [bool]$saved.dark
        if (-not $txtDev.Text -and $saved.devName) { $txtDev.Text = [string]$saved.devName }
    } catch { }
}
$chkDark.Checked = $darkPref
Apply-Theme $darkPref

Write-Log "Ready. Pick your game export folder, icon and colors - the preview updates live. Then BUILD APK."
Write-Log "Signing key: $KeysDir (created automatically; back it up). APKs are for itch.io/sideloading, not the Play Store."
if (-not $AsciiPaths) {
    Write-Log "Note: your Windows user name contains non-English characters, which the Android build tools cannot handle. Build files, tools and the signing key are kept in $DataRoot instead."
}
[void]$form.ShowDialog()
