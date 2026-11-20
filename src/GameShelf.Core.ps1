# GameShelf - Kernfunktionen (Bibliotheken einlesen, Cover, Konfiguration)
# Wird von GameShelf.ps1 geladen. Keine Oberflaeche in dieser Datei.

function Write-Log($msg) {
    try { Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date -Format s), $msg) -Encoding UTF8 } catch {}
}

function Get-DefaultConfig {
    [ordered]@{
        spineWidth     = 34
        scale          = 1.0
        edge           = 'bottom'
        anchorMain     = $null
        anchorCross    = $null
        coverHeight    = 240
        hoverScale     = 1.1
        bottomMargin   = 14
        widthPercent   = 90
        sort           = 'recent'
        style          = 'artwork'
        theme          = 'system'
        gap            = 3
        fps            = 120
        autoHide       = 30
        autoHideLevel  = 'hide'
        heroFirst      = 'off'
        align          = ''
        showRunning    = 'on'
        showPlaytime   = 'on'
        showNew        = 'on'
        showDownloads  = 'on'
        tuck           = 0
        launchAnim     = 'on'
        flashColor     = '#7FB2FF'
        shape          = 'spines'
        effect         = 'none'
        steamGridDbKey = ''
        excludePattern = 'Steamworks|Redistributable|Proton|Steam Linux Runtime|SteamVR|Wallpaper Engine|3DMark|MyDockFinder'
        hidden         = @()
        manual         = @()
        edenExe        = 'D:\Eden\eden.exe'
        edenRoms       = 'D:\Eden\Roms'
        pdnExe         = 'D:\NS2Emu\PokeDinner-Eglantine-2.0.0\eglantine.exe'
        pdnGame        = 'D:\NS2Emu\PPP ROM\PPP ROM\updates\655360\exefs'
        pdnName        = 'Pokémon Pokopia'
        fchExe         = 'D:\NS2Emu\Fritchii-v4\lichii.exe'
        fchGame        = 'D:\NS2Emu\Roms\The Legend of Zelda Ocarina of Time [0400486024DEC000][v131072].nup'
        fchName        = 'The Legend of Zelda: Ocarina of Time'
    }
}

function Read-Config($path) {
    $cfg = Get-DefaultConfig
    if (Test-Path $path) {
        try {
            $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
        } catch { Write-Log "Konfiguration nicht lesbar: $_" }
    }
    $cfg.hidden = @($cfg.hidden | Where-Object { $_ })
    $cfg.manual = @($cfg.manual | Where-Object { $_ })
    $cfg
}

function Save-Config($cfg, $path) {
    ($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
}

function New-Game($id, $name, $source, $type, $target, $launchArgs, $lastPlayed, $steamAppId, $installDir) {
    [pscustomobject]@{
        Id         = $id
        Name       = $name
        Source     = $source
        Type       = $type
        Target     = $target
        Args       = $launchArgs
        LastPlayed = [int64]$lastPlayed
        SteamAppId = $steamAppId
        InstallDir = $installDir
    }
}

# ---------------------------------------------------------------- Steam

function Get-SteamRoot {
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $p = Get-ItemProperty $k -ErrorAction Stop
            $v = $p.SteamPath
            if (-not $v) { $v = $p.InstallPath }
            if ($v -and (Test-Path $v)) { return ($v -replace '/', '\') }
        } catch {}
    }
    $null
}

function Get-SteamLibraries($steamRoot) {
    $libs = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    $libs.Add($steamRoot); $seen[$steamRoot.ToLower().TrimEnd('\', '/')] = 1
    $vdf = Join-Path (Join-Path $steamRoot 'steamapps') 'libraryfolders.vdf'
    if (Test-Path $vdf) {
        $t = Get-Content $vdf -Raw
        foreach ($m in [regex]::Matches($t, '"path"\s+"([^"]+)"')) {
            $p = $m.Groups[1].Value -replace '\\\\', '\'
            $key = $p.ToLower().TrimEnd('\', '/')
            if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; $libs.Add($p) }
        }
    }
    , $libs.ToArray()
}

function Get-SteamGames($steamRoot) {
    $out = @()
    if (-not $steamRoot) { return $out }
    foreach ($lib in (Get-SteamLibraries $steamRoot)) {
        $sa = Join-Path $lib 'steamapps'
        if (-not (Test-Path $sa)) { continue }
        foreach ($f in (Get-ChildItem $sa -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
            try {
                $t = Get-Content $f.FullName -Raw -Encoding UTF8
                $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
                $name = [regex]::Match($t, '"name"\s+"([^"]*)"').Groups[1].Value
                $lp = [regex]::Match($t, '"LastPlayed"\s+"(\d+)"').Groups[1].Value
                if (-not $lp) { $lp = 0 }
                $idir = [regex]::Match($t, '"installdir"\s+"([^"]*)"').Groups[1].Value
                $full = $null
                if ($idir) { $full = Join-Path (Join-Path $sa 'common') $idir }
                if ($id -and $name) {
                    $out += New-Game "steam_$id" $name 'Steam' 'url' "steam://rungameid/$id" '' $lp $id $full
                }
            } catch { Write-Log "Steam-Manifest $($f.Name): $_" }
        }
    }
    $out
}

# Spielzeit in Minuten je Steam-App aus der localconfig.vdf des zuletzt aktiven Kontos.
function Get-SteamPlaytimes($steamRoot) {
    $h = @{}
    if (-not $steamRoot) { return $h }
    $ud = Join-Path $steamRoot 'userdata'
    if (-not (Test-Path $ud)) { return $h }
    $f = Get-ChildItem $ud -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'config\localconfig.vdf' } |
        Where-Object { Test-Path $_ } | Get-Item | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $h }
    $t = [IO.File]::ReadAllText($f.FullName)
    $rx = New-Object Text.RegularExpressions.Regex ('"(\d+)"\s*\{(?:[^{}]|\{[^{}]*\})*?"Playtime"\s+"(\d+)"')
    foreach ($m in $rx.Matches($t)) {
        $id = $m.Groups[1].Value
        $v = [int]$m.Groups[2].Value
        if ($v -gt 0 -and (-not $h.ContainsKey($id) -or $h[$id] -lt $v)) { $h[$id] = $v }
    }
    $h
}

# ---------------------------------------------------------------- Epic

function Get-EpicGames($manifestDir) {
    $out = @()
    if (-not $manifestDir) { $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests' }
    if (-not (Test-Path $manifestDir)) { return $out }
    foreach ($f in (Get-ChildItem $manifestDir -Filter '*.item' -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.bIsIncompleteInstall) { continue }
            if (-not $j.DisplayName -or -not $j.AppName) { continue }
            $cats = @($j.AppCategories)
            if ($cats.Count -gt 0 -and ($cats -notcontains 'games')) { continue }
            $ns = $j.CatalogNamespace; $item = $j.CatalogItemId
            if ($ns -and $item) {
                $url = "com.epicgames.launcher://apps/$ns%3A$item%3A$($j.AppName)?action=launch&silent=true"
            } else {
                $url = "com.epicgames.launcher://apps/$($j.AppName)?action=launch&silent=true"
            }
            $out += New-Game ("epic_" + ($j.AppName -replace '[^\w]', '_')) $j.DisplayName 'Epic' 'url' $url '' 0 $null $j.InstallLocation
        } catch { Write-Log "Epic-Manifest $($f.Name): $_" }
    }
    $out
}

# ---------------------------------------------------------------- Xbox / Game Pass

function Get-XboxGames {
    $out = @()
    try {
        $found = @()
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -ne 'Fixed') { continue }
            $xg = Join-Path $d.RootDirectory.FullName 'XboxGames'
            if (-not (Test-Path $xg)) { continue }
            foreach ($g in (Get-ChildItem $xg -Directory -ErrorAction SilentlyContinue)) {
                $cfg = Join-Path (Join-Path $g.FullName 'Content') 'MicrosoftGame.config'
                if (Test-Path $cfg) { $found += [pscustomobject]@{ Dir = $g.FullName; Cfg = $cfg } }
            }
        }
        if ($found.Count -eq 0) { return $out }
        # Die Startmenue-Abfrage ist langsam und laeuft nur, wenn es Xbox-Spiele gibt.
        $start = @{}
        foreach ($a in (Get-StartApps)) { $start[$a.AppID] = $a.Name }
        $seen = @{}
        foreach ($f in $found) {
            $ident = $null
            try { [xml]$x = Get-Content $f.Cfg -Raw; $ident = $x.Game.Identity.Name } catch { continue }
            if (-not $ident) { continue }
            $key = $start.Keys | Where-Object { $_ -like "${ident}_*!*" } | Select-Object -First 1
            if ($key -and -not $seen.ContainsKey($key)) {
                $seen[$key] = 1
                $out += New-Game ("xbox_" + ($ident -replace '[^\w]', '_')) $start[$key] 'Xbox' 'aumid' $key '' 0 $null $f.Dir
            }
        }
    } catch { Write-Log "Xbox-Suche: $_" }
    $out
}

# ---------------------------------------------------------------- GOG (Registry, nur installierte Spiele)

function Get-GogGames {
    $out = @()
    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games', 'HKLM:\SOFTWARE\GOG.com\Games') {
        if (-not (Test-Path $k)) { continue }
        foreach ($s in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $s.PSPath -ErrorAction Stop
                if ($p.dependsOn) { continue }   # Erweiterungen/DLC
                $name = [string]$p.gameName; $exe = [string]$p.exe; $dir = [string]$p.path; $gid = [string]$p.gameID
                if (-not $gid) { $gid = $s.PSChildName }
                if (-not $name -or -not $exe -or -not (Test-Path $exe)) { continue }
                $out += New-Game ("gog_" + ($gid -replace '[^\w]', '_')) $name 'GOG' 'exe' $exe ([string]$p.launchParam) 0 $null $dir
            } catch { Write-Log "GOG $($s.PSChildName): $_" }
        }
    }
    $out
}

# ---------------------------------------------------------------- Ubisoft Connect

function Get-UbisoftGames {
    $out = @()
    $k = 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs'
    if (-not (Test-Path $k)) { return $out }
    foreach ($s in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
        try {
            $id = $s.PSChildName
            $dir = ([string](Get-ItemProperty $s.PSPath -ErrorAction Stop).InstallDir) -replace '/', '\'
            if (-not $dir -or -not (Test-Path $dir)) { continue }
            $name = $null
            $u = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Uplay Install $id"
            if (Test-Path $u) { $name = [string](Get-ItemProperty $u).DisplayName }
            if (-not $name) { $name = Split-Path $dir.TrimEnd('\') -Leaf }
            $out += New-Game "ubisoft_$id" $name 'Ubisoft' 'url' "uplay://launch/$id/0" '' 0 $null $dir
        } catch { Write-Log "Ubisoft $($s.PSChildName): $_" }
    }
    $out
}

# ---------------------------------------------------------------- EA App und Battle.net (ueber die Windows-Deinstallationsliste)

function Get-LauncherUninstallGames {
    $out = @()
    foreach ($r in 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path $r)) { continue }
        foreach ($s in (Get-ChildItem $r -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $s.PSPath -ErrorAction Stop
                $us = [string]$p.UninstallString; $pub = [string]$p.Publisher; $dn = [string]$p.DisplayName
                if (-not $dn) { continue }
                $src = $null
                if ($us -match 'EAInstaller|EA Desktop|\\Electronic Arts\\' -or ($pub -match 'Electronic Arts' -and $us -match 'Cleanup\.exe')) { $src = 'EA' }
                elseif ($us -match 'Battle\.net') { $src = 'Battle.net' }
                if (-not $src) { continue }
                if ($dn -match '^(EA app|EA|Origin|Battle\.net)$') { continue }
                $dir = [string]$p.InstallLocation
                if (-not $dir -or -not (Test-Path $dir)) { continue }
                $exe = ([string]$p.DisplayIcon) -replace '"', '' -replace ',-?\d+$', ''
                if (-not $exe -or $exe -notmatch '\.exe$' -or -not (Test-Path $exe)) { continue }
                $out += New-Game (($src.ToLower() -replace '[^a-z]', '') + '_' + ($s.PSChildName -replace '[^\w]', '_')) $dn $src 'exe' $exe '' 0 $null $dir
            } catch {}
        }
    }
    $out
}

# ---------------------------------------------------------------- Eigene Eintraege

function Get-ManualGames($cfg) {
    $out = @()
    foreach ($m in @($cfg.manual)) {
        if (-not $m -or -not $m.name -or -not $m.path) { continue }
        $id = "manual_" + ($m.name -replace '[^\w]', '_')
        $a = ''
        if ($m.args) { $a = [string]$m.args }
        $dir = $null
        try { $dir = Split-Path -Parent $m.path } catch {}
        $out += New-Game $id $m.name 'Eigene' 'exe' $m.path $a 0 $null $dir
    }
    $out
}

# ---------------------------------------------------------------- Eden (Switch-Emulator): Spiele aus dem Rom-Ordner
# Spielzeiten/zuletzt gespielt fuehrt das Deck selbst in user\emu-played.json (der Emulator liefert keine).
function Get-EmuPlayFile { Join-Path (Split-Path -Parent $script:CoverDir) 'user\emu-played.json' }
function Read-EmuPlayed {
    $h = @{}
    try {
        $f = Get-EmuPlayFile
        if (Test-Path $f) {
            $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $j.PSObject.Properties) {
                $ss = @(); foreach ($x in @($p.Value.s)) { if ($x) { $ss += @{ t = [int64]$x.t; m = [int]$x.m } } }
                $h[$p.Name] = @{ last = [int64]$p.Value.last; min = [int]$p.Value.min; s = $ss }
            }
        }
    } catch { Write-Log "Emulator-Spielzeiten nicht lesbar: $_" }
    $h
}
function Save-EmuPlayed($h) {
    $f = Get-EmuPlayFile; $d = Split-Path -Parent $f
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    (ConvertTo-Json -InputObject $h -Depth 6 -Compress) | Set-Content -Path $f -Encoding UTF8
}
function Get-EdenGames($cfg) {
    $out = @()
    $exe = [string]$cfg.edenExe; $roms = [string]$cfg.edenRoms
    if (-not $exe -or -not $roms -or -not (Test-Path $exe) -or -not (Test-Path $roms)) { return $out }
    $played = Read-EmuPlayed
    foreach ($f in (Get-ChildItem -LiteralPath $roms -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(nsp|xci|nsz|xcz)$' })) {
        $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
        $id = 'eden_' + ($base -replace '[^\w]', '_')
        $name = (($base -replace '\s*[\[\(][^\]\)]*[\]\)]', '') -replace [char]0x2019, "'").Trim()
        if (-not $name) { $name = $base }
        $lp = 0; if ($played.ContainsKey($id)) { $lp = $played[$id].last }
        $out += New-Game $id $name 'Eden' 'exe' $exe ('-f -g "' + $f.FullName + '"') $lp $null $roms
    }
    $out
}

# ---------------------------------------------------------------- PokeDinner/Eglantine (Switch-Emulator, Eden-Ableger): ein fest eingetragenes Spiel
# Das Spiel liegt entpackt vor (exefs-Ordner) - gestartet wird wie im Emulator ueber die Datei "main" in diesem Ordner.
function Get-PokeDinnerGames($cfg) {
    $out = @()
    $exe = [string]$cfg.pdnExe; $game = [string]$cfg.pdnGame
    if (-not $exe -or -not $game -or -not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $game)) { return $out }
    $boot = $game
    if (Test-Path -LiteralPath $game -PathType Container) { $mf = Join-Path $game 'main'; if (Test-Path -LiteralPath $mf) { $boot = $mf } }
    $name = [string]$cfg.pdnName; if (-not $name) { $name = Split-Path -Leaf $game }
    $id = 'pdn_' + ($name -replace '[^A-Za-z0-9]', '_')
    $played = Read-EmuPlayed
    $lp = 0; if ($played.ContainsKey($id)) { $lp = $played[$id].last }
    $dir = $game; if (-not (Test-Path -LiteralPath $game -PathType Container)) { $dir = Split-Path -Parent $game }
    $out += New-Game $id $name 'PokeDinner' 'exe' $exe ('-f -g "' + $boot + '"') $lp $null $dir
    $out
}

# ---------------------------------------------------------------- Fritchii/lichii (Switch-Emulator, Yuzu-Familie): ein fest eingetragenes Spiel (.nup-Paket)
function Get-FritchiiGames($cfg) {
    $out = @()
    $exe = [string]$cfg.fchExe; $game = [string]$cfg.fchGame
    # deckos-199: Fritchii heisst seit v6 fritchii.exe (frueher lichii.exe) - fehlt die eingetragene Datei, im selben Ordner nach der anderen suchen
    if ($exe -and -not (Test-Path -LiteralPath $exe)) { $dir = Split-Path -Parent $exe; if ($dir) { foreach ($n in 'fritchii.exe', 'lichii.exe') { $cand = Join-Path $dir $n; if (Test-Path -LiteralPath $cand) { $exe = $cand; break } } } }
    if (-not $exe -or -not $game -or -not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $game)) { return $out }
    $name = [string]$cfg.fchName
    if (-not $name) { $name = ([IO.Path]::GetFileNameWithoutExtension($game) -replace '\s*\[[^\]]*\]', '').Trim() }
    $id = 'fch_' + ($name -replace '[^A-Za-z0-9]', '_')
    $played = Read-EmuPlayed
    $lp = 0; if ($played.ContainsKey($id)) { $lp = $played[$id].last }
    $out += New-Game $id $name 'Fritchii' 'exe' $exe ('-f -g "' + $game + '"') $lp $null (Split-Path -Parent $game)
    $out
}

# Breites Titelbild (Hero) fuer Nicht-Steam-Spiele ueber SteamGridDB
function Resolve-HeroSgdb($game) {
    $c = Find-CoverFile 'hero_' $game.Id
    if ($c) { return $c }
    if (-not $script:Config.steamGridDbKey) { return $null }
    $gid = Get-SgdbGameId $game
    if (-not $gid) { return $null }
    $r = Invoke-Sgdb "/heroes/game/${gid}?types=static&nsfw=false&humor=false"
    if ($r -and $r.success -and $r.data) { return (Save-CoverFromUrl $game (@($r.data)[0].url) 'hero_') }
    $null
}

function Get-AllGames($cfg, $steamRoot) {
    $all = @()
    $all += Get-SteamGames $steamRoot
    $all += Get-EpicGames $null
    $all += Get-XboxGames
    $all += Get-GogGames
    $all += Get-UbisoftGames
    $all += Get-LauncherUninstallGames
    $all += Get-ManualGames $cfg
    $all += Get-EdenGames $cfg
    $all += Get-PokeDinnerGames $cfg
    $all += Get-FritchiiGames $cfg
    $pattern = [string]$cfg.excludePattern
    $hidden = @($cfg.hidden)
    $res = @()
    $ids = @{}
    foreach ($g in $all) {
        if ($ids.ContainsKey($g.Id)) { continue }
        if ($hidden -contains $g.Id) { continue }
        if ($pattern -and $g.Source -eq 'Steam' -and $g.Name -match $pattern) { continue }
        $ids[$g.Id] = 1
        $res += $g
    }
    if ($cfg.sort -eq 'name') {
        $res = @($res | Sort-Object Name)
    } else {
        $res = @($res | Sort-Object @{Expression = 'LastPlayed'; Descending = $true }, @{Expression = 'Name'; Descending = $false })
    }
    $res
}

# ---------------------------------------------------------------- Cover

function Find-CoverFile($prefix, $id) {
    foreach ($e in 'png', 'jpg', 'jpeg', 'webp') {
        $p = Join-Path $script:CoverDir "$prefix$id.$e"
        if (Test-Path $p) { return $p }
    }
    $null
}

$script:SteamAssetIndex = @{}

function Find-SteamLocalAsset($steamRoot, $appid, [string[]]$names) {
    if (-not $steamRoot) { return $null }
    $base = Join-Path (Join-Path $steamRoot 'appcache') 'librarycache'
    foreach ($n in $names) {
        $old = Join-Path $base "${appid}_$n"
        if (Test-Path $old) { return $old }
    }
    # Ein einziger Verzeichnisdurchlauf je Spiel, danach aus dem Zwischenspeicher.
    if (-not $script:SteamAssetIndex.ContainsKey($appid)) {
        $idx = @{}
        $dir = Join-Path $base $appid
        if (Test-Path $dir) {
            foreach ($f in (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
                $k = $f.Name.ToLower()
                if (-not $idx.ContainsKey($k) -or $idx[$k].Length -lt $f.Length) { $idx[$k] = $f }
            }
        }
        $script:SteamAssetIndex[$appid] = $idx
    }
    $idx = $script:SteamAssetIndex[$appid]
    foreach ($n in $names) {
        if ($idx.ContainsKey($n.ToLower())) { return $idx[$n.ToLower()].FullName }
    }
    $null
}

function Find-SteamLocalCover($steamRoot, $appid) {
    Find-SteamLocalAsset $steamRoot $appid @('library_600x900.jpg', 'library_capsule.jpg')
}

function Get-SteamCdnCover($game) {
    $dst = Join-Path $script:CoverDir "auto_$($game.Id).jpg"
    foreach ($n in 'library_600x900_2x.jpg', 'library_600x900.jpg') {
        try {
            Invoke-WebRequest -Uri "https://cdn.cloudflare.steamstatic.com/steam/apps/$($game.SteamAppId)/$n" -OutFile $dst -UseBasicParsing -TimeoutSec 8
            # Steam liefert fuer fehlende Cover ein graues Platzhalterbild von wenigen KB.
            if ((Test-Path $dst) -and ((Get-Item $dst).Length -gt 15000)) { return $dst }
        } catch {}
    }
    if (Test-Path $dst) { Remove-Item $dst -Force }
    $null
}

function Invoke-Sgdb($path) {
    Invoke-RestMethod -Uri ("https://www.steamgriddb.com/api/v2" + $path) -Headers @{ Authorization = "Bearer $($script:Config.steamGridDbKey)" } -TimeoutSec 12
}

function Get-SgdbGrids($game) {
    $q = '?dimensions=600x900,342x482,660x930&types=static&nsfw=false&humor=false'
    if ($game.SteamAppId) {
        try {
            $r = Invoke-Sgdb "/grids/steam/$($game.SteamAppId)$q"
            if ($r.success -and $r.data) { return @($r.data) }
        } catch {}
    }
    $s = Invoke-Sgdb ("/search/autocomplete/" + [uri]::EscapeDataString($game.Name))
    if ($s.success -and $s.data) {
        $gid = @($s.data)[0].id
        $r = Invoke-Sgdb "/grids/game/$gid$q"
        if ($r.success -and $r.data) { return @($r.data) }
    }
    @()
}

function Save-CoverFromUrl($game, $url, $prefix) {
    $ext = 'jpg'
    if ($url -match '\.png(\?|$)') { $ext = 'png' }
    foreach ($e in 'png', 'jpg', 'jpeg') {
        $old = Join-Path $script:CoverDir "$prefix$($game.Id).$e"
        if (Test-Path $old) { Remove-Item $old -Force }
    }
    $dst = Join-Path $script:CoverDir "$prefix$($game.Id).$ext"
    Invoke-WebRequest -Uri $url -OutFile $dst -UseBasicParsing -TimeoutSec 20
    $dst
}

function Get-SgdbGameId($game) {
    $s = Invoke-Sgdb ("/search/autocomplete/" + [uri]::EscapeDataString($game.Name))
    if ($s.success -and $s.data) { return @($s.data)[0].id }
    $null
}

function Resolve-Cover($game, $steamRoot) {
    $c = Find-CoverFile '' $game.Id
    if ($c) { return $c }
    $c = Find-CoverFile 'auto_' $game.Id
    if ($c) {
        if ((Get-Item $c).Length -gt 15000) { return $c }
        Remove-Item $c -Force
    }
    if ($game.SteamAppId) {
        $c = Find-SteamLocalCover $steamRoot $game.SteamAppId
        if ($c) { return $c }
        $c = Get-SteamCdnCover $game
        if ($c) { return $c }
    }
    if ($script:Config.steamGridDbKey) {
        try {
            $grids = Get-SgdbGrids $game
            if ($grids.Count -gt 0) { return (Save-CoverFromUrl $game $grids[0].url 'auto_') }
        } catch { Write-Log "SteamGridDB ($($game.Name)): $_" }
    }
    $null
}

function Resolve-Hero($game, $steamRoot) {
    if ($game.SteamAppId) { return (Find-SteamLocalAsset $steamRoot $game.SteamAppId @('library_hero.jpg')) }
    $null
}

function Resolve-Logo($game, $steamRoot) {
    $c = Find-CoverFile 'logo_' $game.Id
    if ($c) { return $c }
    if ($game.SteamAppId) {
        $c = Find-SteamLocalAsset $steamRoot $game.SteamAppId @('logo.png')
        if ($c) { return $c }
    }
    if ($script:Config.steamGridDbKey) {
        try {
            $r = $null
            if ($game.SteamAppId) { try { $r = Invoke-Sgdb "/logos/steam/$($game.SteamAppId)?types=static" } catch {} }
            if (-not $r -or -not $r.data) {
                $gid = Get-SgdbGameId $game
                if ($gid) { $r = Invoke-Sgdb "/logos/game/${gid}?types=static" }
            }
            if ($r -and $r.success -and $r.data) {
                $png = @($r.data) | Where-Object { $_.url -match '\.png(\?|$)' } | Select-Object -First 1
                if ($png) { return (Save-CoverFromUrl $game $png.url 'logo_') }
            }
        } catch { Write-Log "SteamGridDB-Logo ($($game.Name)): $_" }
    }
    $null
}

# ---------------------------------------------------------------- Zwischenspeicher der Spieleliste

function Read-GameCache($path) {
    if (-not (Test-Path $path)) { return @() }
    try {
        $j = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @()
        foreach ($g in @($j)) {
            if ($g.Id -and $g.Name) {
                $out += New-Game $g.Id $g.Name $g.Source $g.Type $g.Target $g.Args $g.LastPlayed $g.SteamAppId $g.InstallDir
            }
        }
        return $out
    } catch { Write-Log "Zwischenspeicher nicht lesbar: $_"; return @() }
}

function Save-GameCache($games, $path) {
    try { (ConvertTo-Json -InputObject @($games) -Depth 4) | Set-Content -Path $path -Encoding UTF8 } catch { Write-Log "Zwischenspeicher: $_" }
}

function Copy-LocalImage($game, $file, $prefix) {
    $ext = [IO.Path]::GetExtension($file).TrimStart('.').ToLower()
    if ($ext -eq 'jpeg') { $ext = 'jpg' }
    if (@('png', 'jpg') -notcontains $ext) { throw "Nur PNG- oder JPG-Dateien." }
    foreach ($e in 'png', 'jpg', 'jpeg') {
        $old = Join-Path $script:CoverDir "$prefix$($game.Id).$e"
        if (Test-Path $old) { Remove-Item $old -Force }
    }
    $dst = Join-Path $script:CoverDir "$prefix$($game.Id).$ext"
    Copy-Item -Path $file -Destination $dst -Force
    $dst
}

# Liefert die ausgeblendeten Spiele mit Namen (fuer die Einstellungen).
function Get-HiddenGames($cfg, $steamRoot) {
    $hidden = @($cfg.hidden)
    if ($hidden.Count -eq 0) { return @() }
    $probe = [ordered]@{ hidden = @(); manual = @($cfg.manual); excludePattern = ''; sort = 'name' }
    $all = @(Get-AllGames $probe $steamRoot)
    $out = @()
    foreach ($id in $hidden) {
        $g = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if ($g) { $out += $g } else { $out += New-Game $id $id '' 'none' '' '' 0 $null $null }
    }
    $out
}
