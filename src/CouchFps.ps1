# GameShelf Deck - Couch-Modus: globales RTSS-Bildratenlimit
# Aufruf durch die Apollo-App "Couch" (erhoehte Rechte, weil die RTSS-Profile unter Programme liegen):
#   CouchFps.ps1 on   -> bisheriges Limit sichern, 60 FPS setzen
#   CouchFps.ps1 off  -> gesichertes Limit wiederherstellen
param([string]$Mode = 'on', [int]$Fps = 60)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $PSScriptRoot 'user'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$bak = Join-Path $dir 'couch-fps.txt'
$logf = Join-Path $dir 'couch-fps.log'
function W($t) { try { Add-Content -LiteralPath $logf -Value ("{0}  {1}" -f (Get-Date -Format s), $t) -Encoding UTF8 } catch { } }

$rtss = $null
try { $rtss = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Unwinder\RTSS' -Name InstallDir).InstallDir } catch { }
if (-not $rtss) { $rtss = Join-Path ${env:ProgramFiles(x86)} 'RivaTuner Statistics Server' }
$dll = Join-Path $rtss 'RTSSHooks64.dll'
$global = Join-Path $rtss 'Profiles\Global'

# Weg 1: offizielle RTSS-Schnittstelle (wirkt sofort)
function Use-Api([int]$set) {
    if (-not ('RtssApi' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class RtssApi {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadLibrary(string p);
    [DllImport("RTSSHooks64.dll", CharSet = CharSet.Ansi)] public static extern bool LoadProfile(string profile);
    [DllImport("RTSSHooks64.dll", CharSet = CharSet.Ansi)] public static extern bool SaveProfile(string profile);
    [DllImport("RTSSHooks64.dll", CharSet = CharSet.Ansi)] public static extern bool GetProfileProperty(string name, ref int data, int size);
    [DllImport("RTSSHooks64.dll", CharSet = CharSet.Ansi)] public static extern bool SetProfileProperty(string name, ref int data, int size);
    [DllImport("RTSSHooks64.dll")] public static extern void UpdateProfiles();
}
'@
    }
    if ([RtssApi]::LoadLibrary($dll) -eq [IntPtr]::Zero) { throw "RTSSHooks64.dll nicht ladbar ($dll)" }
    [void][RtssApi]::LoadProfile('')
    $cur = 0; [void][RtssApi]::GetProfileProperty('FramerateLimit', [ref]$cur, 4)
    $v = $set
    if (-not [RtssApi]::SetProfileProperty('FramerateLimit', [ref]$v, 4)) { throw 'SetProfileProperty fehlgeschlagen' }
    [void][RtssApi]::SaveProfile('')
    [RtssApi]::UpdateProfiles()
    return $cur
}
# Weg 2 (Ersatz): Profildatei direkt aendern - greift erst, wenn RTSS die Profile neu liest
function Use-File([int]$set) {
    $txt = Get-Content -LiteralPath $global -Raw
    $cur = 0; if ($txt -match '(?ms)^\[Framerate\][^\[]*?^Limit=(\d+)') { $cur = [int]$Matches[1] }
    if ($txt -match '(?ms)^\[Framerate\][^\[]*?^Limit=\d+') { $txt = [regex]::Replace($txt, '(?ms)(^\[Framerate\][^\[]*?^Limit=)\d+', ('${1}' + $set)) }
    elseif ($txt -match '(?m)^\[Framerate\]') { $txt = [regex]::Replace($txt, '(?m)^\[Framerate\]\r?\n', ("[Framerate]`r`nLimit=$set`r`n")) }
    else { $txt = $txt.TrimEnd() + "`r`n[Framerate]`r`nLimit=$set`r`n" }
    Set-Content -LiteralPath $global -Value $txt -Encoding ASCII -NoNewline
    return $cur
}
function Set-Limit([int]$v) {
    try { return (Use-Api $v) } catch { W "RTSS-Schnittstelle: $_ - weiche auf Profildatei aus" }
    return (Use-File $v)
}

try {
    if ($Mode -eq 'on') {
        $old = Set-Limit $Fps
        if (-not (Test-Path -LiteralPath $bak)) { Set-Content -LiteralPath $bak -Value $old -Encoding ASCII }   # nur das echte Ausgangslimit sichern
        W "an: Limit $Fps (vorher $old)"
    } else {
        $old = 0; if (Test-Path -LiteralPath $bak) { $old = [int](Get-Content -LiteralPath $bak -Raw).Trim() }
        [void](Set-Limit $old)
        Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
        W "aus: Limit $old wiederhergestellt"
    }
} catch { W "Fehler ($Mode): $_"; exit 1 }
