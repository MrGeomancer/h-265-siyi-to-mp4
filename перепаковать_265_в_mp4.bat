<# : -- batch part: starts PowerShell on this same file --
@echo off
rem NOTE: no "chcp 65001" here on purpose: it switches the console to the
rem raster "Terminal" font, which has no Cyrillic and shows "?????".
set "REPACK_SCRIPT=%~f0"
set "REPACK_ROOT=%~dp0."
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = [IO.File]::ReadAllText($env:REPACK_SCRIPT); $s = [regex]::Replace($s, '\\u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) }); Invoke-Expression $s"
echo.
pause
exit /b
#>

# ============================================================
#  Repack .265 -> .mp4. Put this file into the folder with .265
#  videos and run it.
#  1) Finds byte-identical .265 files in all subfolders. Keeps the
#     copy from the earliest folder (date folders like 2026.11.16
#     sort by date); newer copies and their .mp4 go to Recycle Bin.
#  2) Next to each .265 creates "name_NNN.mp4" with the same stream,
#     no re-encoding. NNN continues after the largest existing one.
#     Output is written as .mp4.part and renamed on success;
#     leftover .part files from an interrupted run are deleted.
#
#  ENCODING: this file is pure ASCII on purpose, so re-saving it in
#  any editor/encoding cannot break it. Russian text is stored as
#  \uXXXX codes and decoded when the script starts.
# ============================================================

$ErrorActionPreference = 'Continue'
$Host.UI.RawUI.WindowTitle = '\u041f\u0435\u0440\u0435\u043f\u0430\u043a\u043e\u0432\u043a\u0430 .265 \u0432 .mp4'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# If the console uses a raster font (no Cyrillic -> "?????"), switch it to Consolas
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RepackConFont {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct FONTINFO {
        public uint cbSize; public uint nFont; public short X; public short Y;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool m, ref FONTINFO i);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool m, ref FONTINFO i);
    public static string Ensure() {
        var i = new FONTINFO(); i.cbSize = (uint)Marshal.SizeOf(i);
        IntPtr h = GetStdHandle(-11);
        if (!GetCurrentConsoleFontEx(h, false, ref i)) return "n/a";
        if ((i.FontFamily & 4) != 0) return i.FaceName;          // already TrueType
        i.FaceName = "Consolas"; i.FontFamily = 54; i.FontWeight = 400; i.X = 0;
        if (i.Y < 14) i.Y = 16;
        SetCurrentConsoleFontEx(h, false, ref i);
        GetCurrentConsoleFontEx(h, false, ref i);
        return i.FaceName;
    }
}
'@
    $font = [RepackConFont]::Ensure()
    if ($env:REPACK_FONTLOG) { "font=$font cp=$([Console]::OutputEncoding.CodePage)" | Out-File -LiteralPath $env:REPACK_FONTLOG -Encoding utf8 }
} catch { }
$root = (Resolve-Path -LiteralPath $env:REPACK_ROOT).Path
$scriptDir = Split-Path -LiteralPath $env:REPACK_SCRIPT

function Find-Tool($name) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$scriptDir\$name.exe", "C:\Program Files (x86)\ffmpeg\bin\$name.exe", "C:\Program Files\ffmpeg\bin\$name.exe")) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Format-Span([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return '{0} \u0447 {1} \u043c\u0438\u043d {2} \u0441\u0435\u043a' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds }
    if ($t.TotalMinutes -ge 1) { return '{0} \u043c\u0438\u043d {1} \u0441\u0435\u043a' -f $t.Minutes, $t.Seconds }
    return '{0:N1} \u0441\u0435\u043a' -f $t.TotalSeconds
}
function Format-Size([long]$b) {
    if ($b -ge 1GB) { return '{0:N1} \u0413\u0411' -f ($b / 1GB) }
    return '{0:N0} \u041c\u0411' -f ($b / 1MB)
}
function Rel($p) { $p.Substring($root.Length).TrimStart('\') }

# Existing .mp4 for a source: "name_NNN.mp4" (or old-style "name.mp4"), else $null
function Find-Mp4($f) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $old = Join-Path $f.DirectoryName "$base.mp4"
    if (Test-Path -LiteralPath $old) { return $old }
    $rx = '^' + [regex]::Escape($base) + '_(\d+)\.mp4$'
    $m = Get-ChildItem -LiteralPath $f.DirectoryName -File -Filter "$base`_*.mp4" | Where-Object { $_.Name -match $rx } | Select-Object -First 1
    if ($m) { return $m.FullName }
    return $null
}

$ffmpeg = Find-Tool 'ffmpeg'
$ffprobe = Find-Tool 'ffprobe'
if (-not $ffmpeg) { Write-Host '[\u041e\u0428\u0418\u0411\u041a\u0410] \u041d\u0435 \u043d\u0430\u0439\u0434\u0435\u043d ffmpeg. \u0423\u0441\u0442\u0430\u043d\u043e\u0432\u0438\u0442\u0435 ffmpeg \u0438\u043b\u0438 \u043f\u043e\u043b\u043e\u0436\u0438\u0442\u0435 ffmpeg.exe \u0438 ffprobe.exe \u0440\u044f\u0434\u043e\u043c \u0441\u043e \u0441\u043a\u0440\u0438\u043f\u0442\u043e\u043c.' -ForegroundColor Red; return }

$swAll = [Diagnostics.Stopwatch]::StartNew()
Write-Host '============================================================'
Write-Host " \u041f\u0430\u043f\u043a\u0430: $root"
Write-Host '============================================================'

# ---------------- 1. Duplicates ----------------
Write-Host ''
Write-Host '\u0428\u0410\u0413 1. \u041f\u043e\u0438\u0441\u043a \u0434\u0443\u0431\u043b\u0438\u043a\u0430\u0442\u043e\u0432 .265' -ForegroundColor Cyan
$all = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.265 | Where-Object { $_.Extension -eq '.265' })
Write-Host (" \u041d\u0430\u0439\u0434\u0435\u043d\u043e \u0444\u0430\u0439\u043b\u043e\u0432 .265: {0} (\u0432\u0441\u0435\u0433\u043e {1})" -f $all.Count, (Format-Size (($all | Measure-Object Length -Sum).Sum)))

# Only files of equal size can be identical; hash just those
$sameSize = @($all | Group-Object Length | Where-Object { $_.Count -gt 1 })
$candidates = @($sameSize | ForEach-Object { $_.Group })
$dupRemoved = 0; $dupFreed = 0L
$isFixed = ([IO.DriveInfo]([IO.Path]::GetPathRoot($root))).DriveType -eq 'Fixed'
if ($candidates.Count -eq 0) {
    Write-Host ' \u0424\u0430\u0439\u043b\u043e\u0432 \u043e\u0434\u0438\u043d\u0430\u043a\u043e\u0432\u043e\u0433\u043e \u0440\u0430\u0437\u043c\u0435\u0440\u0430 \u043d\u0435\u0442, \u0434\u0443\u0431\u043b\u0438\u043a\u0430\u0442\u043e\u0432 \u043d\u0435\u0442.'
} else {
    Write-Host (" \u0424\u0430\u0439\u043b\u043e\u0432 \u043e\u0434\u0438\u043d\u0430\u043a\u043e\u0432\u043e\u0433\u043e \u0440\u0430\u0437\u043c\u0435\u0440\u0430: {0}, \u0441\u0432\u0435\u0440\u044f\u044e \u0441\u043e\u0434\u0435\u0440\u0436\u0438\u043c\u043e\u0435..." -f $candidates.Count)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $i = 0
    $hashed = foreach ($f in $candidates) {
        $i++
        Write-Host ("   [{0} \u0438\u0437 {1}] \u0445\u044d\u0448: {2}" -f $i, $candidates.Count, (Rel $f.FullName))
        [pscustomobject]@{ File = $f; Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm MD5).Hash }
    }
    $groups = @($hashed | Group-Object Hash | Where-Object { $_.Count -gt 1 })
    if ($groups.Count -eq 0) { Write-Host ' \u041e\u0434\u0438\u043d\u0430\u043a\u043e\u0432\u044b\u0445 \u0444\u0430\u0439\u043b\u043e\u0432 \u043d\u0435\u0442.' }
    foreach ($g in $groups) {
        $sorted = @($g.Group | Sort-Object { $_.File.FullName })
        $keep = $sorted[0].File
        Write-Host ''
        Write-Host (" \u041e\u0434\u0438\u043d\u0430\u043a\u043e\u0432\u044b\u0435 \u0444\u0430\u0439\u043b\u044b ({0}):" -f (Format-Size $keep.Length)) -ForegroundColor Yellow
        Write-Host ("   \u043e\u0441\u0442\u0430\u0432\u043b\u0435\u043d: {0}" -f (Rel $keep.FullName)) -ForegroundColor Green
        foreach ($d in $sorted | Select-Object -Skip 1) {
            $victims = @($d.File.FullName)
            $mp4 = Find-Mp4 $d.File
            if ($mp4) { $victims += $mp4 }
            foreach ($v in $victims) {
                $len = (Get-Item -LiteralPath $v).Length
                if ($isFixed) {
                    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($v, 'OnlyErrorDialogs', 'SendToRecycleBin')
                    Write-Host ("   \u0443\u0434\u0430\u043b\u0451\u043d \u0432 \u041a\u043e\u0440\u0437\u0438\u043d\u0443: {0}" -f (Rel $v)) -ForegroundColor DarkYellow
                } else {
                    # Removable drive has no Recycle Bin: move into _\u0414\u0423\u0411\u041b\u0418\u041a\u0410\u0422\u042b instead
                    $target = Join-Path (Join-Path $root '_\u0414\u0423\u0411\u041b\u0418\u041a\u0410\u0422\u042b') (Split-Path (Rel $v))
                    New-Item -ItemType Directory -Force -Path $target | Out-Null
                    Move-Item -LiteralPath $v -Destination $target
                    Write-Host ("   \u043f\u0435\u0440\u0435\u043d\u0435\u0441\u0451\u043d \u0432 _\u0414\u0423\u0411\u041b\u0418\u041a\u0410\u0422\u042b: {0}" -f (Rel $v)) -ForegroundColor DarkYellow
                }
                $dupFreed += $len
            }
            $dupRemoved++
        }
    }
}

# ---------------- 2. Repack ----------------
Write-Host ''
Write-Host '\u0428\u0410\u0413 2. \u041f\u0435\u0440\u0435\u043f\u0430\u043a\u043e\u0432\u043a\u0430 .265 \u0432 .mp4' -ForegroundColor Cyan
# Leftovers of an interrupted run: "name_NNN.mp4.part" are incomplete, delete them
$parts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.mp4.part)
foreach ($p in $parts) {
    Remove-Item -LiteralPath $p.FullName -Force
    Write-Host (" \u0423\u0434\u0430\u043b\u0451\u043d \u043d\u0435\u0434\u043e\u0434\u0435\u043b\u0430\u043d\u043d\u044b\u0439 \u0444\u0430\u0439\u043b \u0441 \u043f\u0440\u043e\u0448\u043b\u043e\u0433\u043e \u0437\u0430\u043f\u0443\u0441\u043a\u0430: {0}" -f (Rel $p.FullName)) -ForegroundColor DarkYellow
}
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.265 |
    Where-Object { $_.Extension -eq '.265' -and $_.FullName -notlike "$root\_\u0414\u0423\u0411\u041b\u0418\u041a\u0410\u0422\u042b\*" } | Sort-Object FullName)
$todo = @($files | Where-Object { -not (Find-Mp4 $_) })
Write-Host (" \u0424\u0430\u0439\u043b\u043e\u0432 .265: {0}  |  \u0443\u0436\u0435 \u0435\u0441\u0442\u044c .mp4: {1}  |  \u043f\u0440\u0435\u0434\u0441\u0442\u043e\u0438\u0442 \u043f\u0435\u0440\u0435\u043f\u0430\u043a\u043e\u0432\u0430\u0442\u044c: {2} ({3})" -f $files.Count, ($files.Count - $todo.Count), $todo.Count, (Format-Size (($todo | Measure-Object Length -Sum).Sum)))

# Sequence number: continue after the largest NNN among existing "name_NNN.mp4"
$maxNum = 0
foreach ($f in $files) {
    $base = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $rx = '^' + [regex]::Escape($base) + '_(\d+)\.mp4$'
    Get-ChildItem -LiteralPath $f.DirectoryName -File -Filter "$base`_*.mp4" | ForEach-Object {
        if ($_.Name -match $rx -and [int]$Matches[1] -gt $maxNum) { $maxNum = [int]$Matches[1] }
    }
}
$seq = $maxNum + 1
if ($maxNum -gt 0) { Write-Host " \u0423\u0436\u0435 \u0435\u0441\u0442\u044c \u0444\u0430\u0439\u043b\u044b \u0441 \u043d\u043e\u043c\u0435\u0440\u0430\u043c\u0438 \u0434\u043e $maxNum, \u043d\u043e\u0432\u044b\u0435 \u043d\u0443\u043c\u0435\u0440\u0443\u044e\u0442\u0441\u044f \u0441 $seq" } else { Write-Host ' \u041d\u0443\u043c\u0435\u0440\u0430\u0446\u0438\u044f \u043d\u043e\u0432\u044b\u0445 \u0444\u0430\u0439\u043b\u043e\u0432 \u0441 1' }
Write-Host ''

$ok = 0; $skip = 0; $fail = 0; $n = 0
foreach ($f in $files) {
    $n++
    $left = $files.Count - $n
    Write-Host ("[{0} \u0438\u0437 {1}] {2}  ({3})" -f $n, $files.Count, (Rel $f.FullName), (Format-Size $f.Length))
    $existing = Find-Mp4 $f
    if ($existing) {
        Write-Host ("   \u041f\u0440\u043e\u043f\u0443\u0449\u0435\u043d: \u0443\u0436\u0435 \u0435\u0441\u0442\u044c {0}" -f (Split-Path -Leaf $existing)) -ForegroundColor DarkGray
        $skip++
        Write-Host "   \u041e\u0441\u0442\u0430\u043b\u043e\u0441\u044c \u0444\u0430\u0439\u043b\u043e\u0432: $left"; Write-Host ''
        continue
    }
    # Frame rate from stream headers (ffprobe gives a fraction: 30/1 = 30 fps)
    $fps = '30'
    if ($ffprobe) {
        $r = & $ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 $f.FullName 2>$null | Select-Object -First 1
        if ($r -match '^\d+/\d+$' -and $r -notmatch '/0$') { $fps = $r }
    }
    $a, $b = $fps -split '/'; if (-not $b) { $b = 1 }
    $fpsNice = [math]::Round([double]$a / [double]$b, 2)

    $dst = Join-Path $f.DirectoryName ('{0}_{1:D3}.mp4' -f [IO.Path]::GetFileNameWithoutExtension($f.Name), $seq)
    # Write to "name_NNN.mp4.part" and rename only after success, so an
    # interrupted run never leaves a half-written file under the final name
    $tmp = "$dst.part"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $ffmpeg -v error -nostdin -y -r $fps -i $f.FullName -c copy -tag:v hvc1 -movflags +faststart -f mp4 $tmp
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -eq 0) {
        try { Move-Item -LiteralPath $tmp -Destination $dst -ErrorAction Stop } catch { $code = -1 }
    }
    if ($code -ne 0) {
        Write-Host "   [\u041e\u0428\u0418\u0411\u041a\u0410] \u043d\u0435 \u0443\u0434\u0430\u043b\u043e\u0441\u044c \u043f\u0435\u0440\u0435\u043f\u0430\u043a\u043e\u0432\u0430\u0442\u044c (\u043a\u043e\u0434 $code)" -ForegroundColor Red
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $fail++
    } else {
        $dur = '?'
        if ($ffprobe) {
            $s = & $ffprobe -v error -show_entries format=duration -of csv=p=0 $dst 2>$null | Select-Object -First 1
            if ($s -as [double]) { $dur = [TimeSpan]::FromSeconds([double]$s).ToString('h\:mm\:ss') }
        }
        $seq++
        Write-Host ("   \u0413\u043e\u0442\u043e\u0432\u043e: {3}  |  \u0434\u043b\u0438\u0442\u0435\u043b\u044c\u043d\u043e\u0441\u0442\u044c \u0432\u0438\u0434\u0435\u043e {0}  |  {1} \u043a\u0430\u0434\u0440\u043e\u0432/\u0441  |  \u0437\u0430 {2}" -f $dur, $fpsNice, (Format-Span $sw.Elapsed), (Split-Path -Leaf $dst)) -ForegroundColor Green
        $ok++
    }
    Write-Host "   \u041e\u0441\u0442\u0430\u043b\u043e\u0441\u044c \u0444\u0430\u0439\u043b\u043e\u0432: $left"; Write-Host ''
}

$swAll.Stop()
Write-Host '============================================================'
Write-Host ' \u0412\u0421\u0401 \u0413\u041e\u0422\u041e\u0412\u041e.' -ForegroundColor Green
Write-Host (" \u0414\u0443\u0431\u043b\u0438\u043a\u0430\u0442\u043e\u0432 \u0443\u0431\u0440\u0430\u043d\u043e: {0} (\u043e\u0441\u0432\u043e\u0431\u043e\u0436\u0434\u0435\u043d\u043e {1})" -f $dupRemoved, (Format-Size $dupFreed))
Write-Host " \u041f\u0435\u0440\u0435\u043f\u0430\u043a\u043e\u0432\u0430\u043d\u043e: $ok"
Write-Host " \u041f\u0440\u043e\u043f\u0443\u0449\u0435\u043d\u043e (mp4 \u0443\u0436\u0435 \u0431\u044b\u043b): $skip"
if ($fail) { Write-Host " \u041e\u0448\u0438\u0431\u043e\u043a: $fail" -ForegroundColor Red } else { Write-Host ' \u041e\u0448\u0438\u0431\u043e\u043a: 0' }
Write-Host (" \u0417\u0430\u0442\u0440\u0430\u0447\u0435\u043d\u043e \u0432\u0440\u0435\u043c\u0435\u043d\u0438: {0}" -f (Format-Span $swAll.Elapsed))
Write-Host '============================================================'
Write-Host ' \u041f\u0440\u0435\u0434\u0443\u043f\u0440\u0435\u0436\u0434\u0435\u043d\u0438\u044f \u0432\u0438\u0434\u0430 "PPS id out of range" \u043d\u0435 \u043e\u0448\u0438\u0431\u043a\u0430: \u0444\u0430\u0439\u043b'
Write-Host ' \u043d\u0430\u0447\u0438\u043d\u0430\u0435\u0442\u0441\u044f \u043f\u043e\u0441\u0440\u0435\u0434\u0438 \u043f\u043e\u0442\u043e\u043a\u0430, \u043f\u0435\u0440\u0432\u044b\u0435 \u0434\u043e\u043b\u0438 \u0441\u0435\u043a\u0443\u043d\u0434\u044b \u043c\u043e\u0433\u0443\u0442 \u0431\u044b\u0442\u044c \u0431\u0438\u0442\u044b\u043c\u0438.'
