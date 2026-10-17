#requires -Version 7.0
<#
.SYNOPSIS
    Read Minecraft / NeoForge decompiled sources straight out of the sources jar.

.DESCRIPTION
    Read-only helper for the mc-sources skill. The jar is opened as a zip and
    entries are streamed; nothing is extracted to disk.

.EXAMPLE
    pwsh mcsrc.ps1 info

.EXAMPLE
    pwsh mcsrc.ps1 grep "PrimedTnt" -Path net/minecraft/world/level/block -Context 2

.EXAMPLE
    pwsh mcsrc.ps1 show net.minecraft.world.level.block.TntBlock -Lines 30-60
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('info', 'find', 'grep', 'show', 'list', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Query,

    [Alias('Package')]
    [string]$Path,

    [int]$Context = 0,
    [int]$Max = 40,
    [string]$Lines,
    [ValidateSet('mc', 'neoforge')]
    [string]$Source = 'mc',
    [switch]$CaseSensitive,
    [switch]$All,
    [switch]$UseTar,
    [switch]$Full,
    [string]$ProjectRoot,
    [string]$Jar
)

$ErrorActionPreference = 'Stop'

$script:UseTarMode = [bool]$UseTar
if (-not $script:UseTarMode -and $ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    $script:UseTarMode = $true
}

try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Get-HomeDir {
    if ($env:USERPROFILE) { return $env:USERPROFILE }
    if ($env:HOME) { return $env:HOME }
    return '.'
}

# A Gradle project root needs both a .git marker and a Gradle marker. The skill
# itself is often installed as a git submodule under .agents/skills, so a bare
# .git check would stop at the skill directory instead of the game project.
function Test-ProjectRoot([string]$Dir) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir '.git'))) { return $false }
    foreach ($marker in @('settings.gradle', 'settings.gradle.kts', 'gradle.properties')) {
        if (Test-Path -LiteralPath (Join-Path $Dir $marker)) { return $true }
    }
    return $false
}

function Find-ProjectRootUp([string]$Start) {
    $dir = $Start
    while ($dir) {
        if (Test-ProjectRoot $dir) { return $dir }
        $parent = Split-Path -Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-ProjectRoot {
    if ($script:Root) { return $script:Root }
    if ($ProjectRoot) {
        $script:Root = (Resolve-Path -LiteralPath $ProjectRoot).Path
        return $script:Root
    }
    $hit = Find-ProjectRootUp $PSScriptRoot
    if (-not $hit) { $hit = Find-ProjectRootUp (Get-Location).Path }
    if ($hit) {
        $script:Root = $hit
        return $hit
    }
    $script:Root = (Get-Location).Path
    return $script:Root
}

function Get-GradleProperty([string]$File, [string]$Name) {
    if (-not (Test-Path -LiteralPath $File)) { return $null }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*=\s*(.+?)\s*$'
    foreach ($line in Get-Content -LiteralPath $File -ErrorAction SilentlyContinue) {
        if ($line -match $pattern) { return $Matches[1].Trim() }
    }
    return $null
}

function Get-McJarPath([string]$Root, [string]$McVersion) {
    $artifactDir = Join-Path $Root 'build/moddev/artifacts'
    if (Test-Path -LiteralPath $artifactDir) {
        if ($McVersion) {
            $exact = Join-Path $artifactDir "minecraft-patched-$McVersion-sources.jar"
            if (Test-Path -LiteralPath $exact) { return $exact }
        }
        $hit = Get-ChildItem -LiteralPath $artifactDir -Filter 'minecraft-*-sources.jar' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    $cacheRoots = @(
        (Join-Path (Get-HomeDir) '.gradle/caches/neoformruntime'),
        (Join-Path (Get-HomeDir) '.gradle/caches/moddev-gradle')
    )
    foreach ($cacheRoot in $cacheRoots) {
        if (-not (Test-Path -LiteralPath $cacheRoot)) { continue }
        $hit = Get-ChildItem -LiteralPath $cacheRoot -Recurse -File -Filter '*-sources.jar' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'minecraft-*' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Get-NeoForgeJarPath([string]$NeoVersion) {
    $base = Join-Path (Get-HomeDir) '.gradle/caches/modules-2/files-2.1/net.neoforged/neoforge'
    if ($NeoVersion) {
        $dir = Join-Path $base $NeoVersion
        if (Test-Path -LiteralPath $dir) {
            $hit = Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*-sources.jar' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Get-JarPath {
    if ($script:JarPath) { return $script:JarPath }
    if ($Jar) {
        if (-not (Test-Path -LiteralPath $Jar)) { throw "-Jar file not found: $Jar" }
        $script:JarPath = (Resolve-Path -LiteralPath $Jar).Path
        return $script:JarPath
    }
    $root = Get-ProjectRoot
    $props = Join-Path $root 'gradle.properties'
    $mcVersion = Get-GradleProperty $props 'minecraft_version'
    $neoVersion = Get-GradleProperty $props 'neo_version'

    if ($Source -eq 'neoforge') {
        $found = Get-NeoForgeJarPath $neoVersion
        if (-not $found) {
            throw "NeoForge sources jar not found for '$neoVersion'; expected it under the Gradle cache (net.neoforged/neoforge/$neoVersion)."
        }
    }
    else {
        $found = Get-McJarPath $root $mcVersion
        if (-not $found) {
            throw "Minecraft sources jar not found. Run '.\gradlew.bat build' once (or re-sync the Gradle project) so ModDevGradle produces build/moddev/artifacts/*-sources.jar."
        }
    }
    $script:JarPath = $found
    return $script:JarPath
}

function Get-EntryNames([string]$JarPath) {
    if ($script:UseTarMode) {
        $names = & tar -tf $JarPath
        if ($LASTEXITCODE -ne 0) { throw "tar failed to list $JarPath" }
        return @($names | Where-Object { $_ -and -not $_.EndsWith('/') })
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        return @($zip.Entries | ForEach-Object { $_.FullName })
    }
    finally { $zip.Dispose() }
}

function Read-EntryText([string]$JarPath, [string]$Name) {
    if ($script:UseTarMode) {
        $raw = & tar -xOf $JarPath $Name
        if ($LASTEXITCODE -ne 0) { throw "tar failed to read $Name" }
        return ($raw -join "`n")
    }
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $entry = $zip.GetEntry($Name)
        if (-not $entry) { throw "entry not found: $Name" }
        $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $zip.Dispose() }
}

function ConvertTo-Lines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return @() }
    $lines = @($Text -split "`r?`n")
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        if ($lines.Count -eq 1) { return @() }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    Write-Output -NoEnumerate $lines
}

function Get-Pattern([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'missing search pattern' }
    if ($CaseSensitive) { return $Value }
    return "(?i)$Value"
}

function ConvertTo-Prefix([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $p = $Value -replace '\\', '/'
    $p = $p.Trim('/')
    if ($p -notmatch '/' -and $p -match '\.' -and -not $p.EndsWith('.java')) {
        $p = $p -replace '\.', '/'
    }
    if (-not $p.EndsWith('/') -and -not $p.EndsWith('.java')) { $p += '/' }
    return $p
}

function Test-Prefix([string]$Name, [string]$Prefix) {
    if (-not $Prefix) { return $true }
    if ($Name.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Name.IndexOf('/' + $Prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Find-Matches([string]$Text, [string]$Pattern, [int]$Limit = [int]::MaxValue) {
    $textLines = ConvertTo-Lines $Text
    $hits = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $textLines.Count; $i++) {
        if ($textLines[$i] -notmatch $Pattern) { continue }
        $hits.Add($i)
        if (-not $All -and $hits.Count -ge $Limit) { break }
    }
    return [pscustomobject]@{
        Lines = $textLines
        Hits  = $hits
    }
}

# Prints one file's hits once with the path in a header, so long paths are not
# repeated on every line. Output shape (':' marks a hit, '-' a context line):
#
#   == net/minecraft/world/level/Level.java (2 matches)
#    565:     public void explode(...)
#    566:         this.explode(
#    567-             source,
function Format-MatchGroup([string]$Name, [string[]]$TextLines, [System.Collections.Generic.List[int]]$Hits, [int]$ContextLines) {
    if ($Hits.Count -eq 0) { return @() }

    $hitSet = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($i in $Hits) { $null = $hitSet.Add($i) }

    $ranges = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $Hits) {
        $from = [Math]::Max(0, $i - $ContextLines)
        $to = [Math]::Min($TextLines.Count - 1, $i + $ContextLines)
        if ($ranges.Count -gt 0) {
            $last = $ranges[$ranges.Count - 1]
            if ($from -le ($last.To + 1)) {
                if ($to -gt $last.To) { $last.To = $to }
                continue
            }
        }
        $range = @{}
        $range.From = $from
        $range.To = $to
        $ranges.Add($range)
    }

    $width = ([string]($ranges[$ranges.Count - 1].To + 1)).Length
    $out = @()
    $label = if ($Hits.Count -eq 1) { '1 match' } else { "$($Hits.Count) matches" }
    $out += "== $Name ($label)"
    for ($r = 0; $r -lt $ranges.Count; $r++) {
        if ($r -gt 0 -and $ContextLines -gt 0) { $out += '   ...' }
        $range = $ranges[$r]
        for ($j = $range.From; $j -le $range.To; $j++) {
            $sep = if ($hitSet.Contains($j)) { ':' } else { '-' }
            $out += ("{0,$width}{1} {2}" -f ($j + 1), $sep, $TextLines[$j])
        }
    }
    return $out
}

function Invoke-Info {
    $jarPath = Get-JarPath
    $root = Get-ProjectRoot
    $props = Join-Path $root 'gradle.properties'
    $mcVersion = Get-GradleProperty $props 'minecraft_version'
    $neoVersion = Get-GradleProperty $props 'neo_version'
    $names = Get-EntryNames $jarPath
    $javaCount = @($names | Where-Object { $_.EndsWith('.java') }).Count
    $file = Get-Item -LiteralPath $jarPath

    Write-Output ("jar      : " + $jarPath)
    if ($mcVersion -or $neoVersion) {
        Write-Output ("version  : MC {0} / NeoForge {1}" -f $mcVersion, $neoVersion)
    }
    Write-Output ("entries  : {0} (java {1})" -f $names.Count, $javaCount)
    Write-Output ("size     : {0:N1} MB, built {1}" -f ($file.Length / 1MB), $file.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    Write-Output ("mode     : " + $(if ($script:UseTarMode) { 'tar fallback (read-only sandbox)' } else { 'zip stream' }))

    if ($Source -eq 'mc') {
        $neoJar = Get-NeoForgeJarPath $neoVersion
        if ($neoJar) {
            $neoFile = Get-Item -LiteralPath $neoJar
            Write-Output ("neoforge : {0} ({1:N1} MB)" -f $neoJar, ($neoFile.Length / 1MB))
        }
        else {
            Write-Output "neoforge : (not cached; -Source neoforge unavailable)"
        }
    }
}

function Invoke-Find {
    $jarPath = Get-JarPath
    $pattern = Get-Pattern $Query
    $byPath = $Query -match '[./]'
    $names = Get-EntryNames $jarPath
    $found = [System.Collections.Generic.List[string]]::new()

    foreach ($name in $names) {
        if (-not $name.EndsWith('.java')) { continue }
        $fqcn = $name.Substring(0, $name.Length - 5) -replace '/', '.'
        $haystack = if ($byPath) { $fqcn } else { [System.IO.Path]::GetFileNameWithoutExtension($name) }
        if ($haystack -match $pattern) {
            if (-not $found.Contains($fqcn)) { $found.Add($fqcn) }
            if (-not $All -and $found.Count -ge $Max) { break }
        }
    }

    if ($found.Count -eq 0) {
        Write-Output ("# no class matching '" + $Query + "'")
        return
    }
    $found | Sort-Object
    if (-not $All -and $found.Count -ge $Max) {
        Write-Output ("# capped at $Max results; use -All for everything")
    }
}

function Invoke-Grep {
    $jarPath = Get-JarPath
    $pattern = Get-Pattern $Query
    $prefix = ConvertTo-Prefix $Path
    $total = 0

    if ($script:UseTarMode) {
        $names = @(Get-EntryNames $jarPath | Where-Object {
                $_.EndsWith('.java') -and (Test-Prefix $_ $prefix)
            })
        if (-not $prefix -and $names.Count -gt 400) {
            throw "read-only fallback would read $($names.Count) entries through tar; pass -Path to narrow the search"
        }
        foreach ($name in $names) {
            $text = Read-EntryText $jarPath $name
            $found = Find-Matches $text $pattern ([Math]::Max(1, $Max - $total))
            if ($found.Hits.Count -gt 0) {
                Format-MatchGroup $name $found.Lines $found.Hits $Context
            }
            $total += $found.Hits.Count
            if (-not $All -and $total -ge $Max) { break }
        }
        if ($total -eq 0) { Write-Output ("# no match for '" + $Query + "'") }
        return
    }

    $zip = [System.IO.Compression.ZipFile]::OpenRead($jarPath)
    try {
        foreach ($entry in $zip.Entries) {
            if (-not $entry.FullName.EndsWith('.java')) { continue }
            if (-not (Test-Prefix $entry.FullName $prefix)) { continue }

            $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false), $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }

            $found = Find-Matches $text $pattern ([Math]::Max(1, $Max - $total))
            if ($found.Hits.Count -gt 0) {
                Format-MatchGroup $entry.FullName $found.Lines $found.Hits $Context
            }
            $total += $found.Hits.Count
            if (-not $All -and $total -ge $Max) {
                $noun = if ($Max -eq 1) { 'match' } else { 'matches' }
                Write-Output ("# capped at {0} {1}; use -All or narrow with -Path" -f $Max, $noun)
                break
            }
        }
    }
    finally { $zip.Dispose() }

    if ($total -eq 0) { Write-Output ("# no match for '" + $Query + "'") }
}

function Resolve-Entry([string[]]$Names, [string]$Value) {
    $q = $Value.Trim()
    $norm = $q -replace '\\', '/'
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($norm.EndsWith('.java')) { $candidates.Add($norm) }
    elseif ($norm -match '/') { $candidates.Add("$norm.java") }
    elseif ($norm -match '\.') { $candidates.Add((($norm -replace '\.', '/') + '.java')) }

    foreach ($candidate in $candidates) {
        $hit = $Names | Where-Object { $_ -ieq $candidate } | Select-Object -First 1
        if ($hit) { return $hit }
    }

    if ($norm -match '/') { $leaf = Split-Path -Leaf $norm }
    elseif ($norm -match '\.') { $leaf = ($norm -split '\.')[-1] }
    else { $leaf = $norm }
    $leaf = $leaf -replace '\.java$', ''

    $hits = @($Names | Where-Object { $_.EndsWith('.java') -and [System.IO.Path]::GetFileNameWithoutExtension($_) -ieq $leaf })
    if ($hits.Count -eq 1) { return $hits[0] }
    if ($hits.Count -eq 0) { throw "no source entry matching '$Value'" }
    $sample = ($hits | Select-Object -First 15) -join "`n  "
    throw "ambiguous '$Value'; candidates:`n  $sample"
}

function Invoke-Show {
    $jarPath = Get-JarPath
    $names = Get-EntryNames $jarPath
    $entryName = Resolve-Entry $names $Query
    $text = Read-EntryText $jarPath $entryName
    $textLines = ConvertTo-Lines $text

    $from = 1
    $to = $textLines.Count
    if ($Lines) {
        if ($Lines -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
            $from = [int]$Matches[1]
            $to = [int]$Matches[2]
        }
        elseif ($Lines -match '^\s*(\d+)\s*$') {
            $from = [int]$Matches[1]
            $to = [Math]::Min($textLines.Count, $from + 79)
        }
        else { throw "bad -Lines '$Lines'; use '40' or '40-80'" }
    }
    elseif (-not $Full -and $textLines.Count -gt 600) {
        $to = 600
    }

    $from = [Math]::Max(1, $from)
    $to = [Math]::Min($textLines.Count, $to)
    if ($from -gt $to) { throw "-Lines range is outside 1..$($textLines.Count)" }

    Write-Output ("# {0}  ({1} lines)" -f $entryName, $textLines.Count)
    for ($i = $from; $i -le $to; $i++) {
        Write-Output ("{0,5}: {1}" -f $i, $textLines[$i - 1])
    }
    if ($to -lt $textLines.Count) {
        Write-Output ("# ... {0} more lines; use -Lines {1}-{2} or -Full" -f ($textLines.Count - $to), ($to + 1), $textLines.Count)
    }
}

function Invoke-List {
    $jarPath = Get-JarPath
    $prefix = ConvertTo-Prefix $Query
    $names = Get-EntryNames $jarPath

    if (-not $prefix) {
        $names | ForEach-Object {
            $parts = $_ -split '/'
            if ($parts.Count -ge 2) { "$($parts[0])/$($parts[1])" } else { $parts[0] }
        } | Sort-Object -Unique
        return
    }

    $entries = @($names | Where-Object {
            (Test-Prefix $_ $prefix) -and $_.EndsWith('.java')
        })
    if ($entries.Count -eq 0) {
        Write-Output ("# no java sources under '" + $prefix + "'")
        return
    }
    $entries | ForEach-Object { ($_ -replace '\.java$', '') -replace '/', '.' } | Sort-Object | Select-Object -First ([Math]::Max(1, $Max))
    if ($entries.Count -gt $Max) { Write-Output ("# ... {0} more; raise -Max or use -All" -f ($entries.Count - $Max)) }
}

function Invoke-Help {
    Write-Output @'
mcsrc - read Minecraft / NeoForge sources from the ModDevGradle sources jar (read-only)

  info                                  jar path, version, entry counts
  find <regex>                          class names matching regex
  grep <regex> [-Path <prefix>]         search source text, grouped per file:
                                        '== path (N matches)' then 'NNN: hit' / 'NNN- context'
       [-Context N] [-Max N] [-All]
  show <class|path> [-Lines 40-80]      print a class (default: first 600 lines)
  list [<prefix>]                       list packages / classes

Global: -Source mc|neoforge  -CaseSensitive  -UseTar  -ProjectRoot <dir>  -Jar <file>

Examples:
  pwsh mcsrc.ps1 find TntBlock
  pwsh mcsrc.ps1 grep "PrimedTnt" -Path net/minecraft/world/level/block -Context 2
  pwsh mcsrc.ps1 show net.minecraft.world.level.block.TntBlock -Lines 30-70
  pwsh mcsrc.ps1 grep "class .*Block" -Path world/level/block -Max 10
'@
}

try {
    switch ($Command) {
        'info' { Invoke-Info }
        'find' { Invoke-Find }
        'grep' { Invoke-Grep }
        'show' { Invoke-Show }
        'list' { Invoke-List }
        default { Invoke-Help }
    }
}
catch {
    Write-Output ("mcsrc: " + $_.Exception.Message)
    if ($env:MCSRC_DEBUG) {
        Write-Output $_.InvocationInfo.PositionMessage
        Write-Output $_.ScriptStackTrace
    }
    exit 2
}
