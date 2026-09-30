<#
.SYNOPSIS
原生库门禁：导出符号清单、导出函数体内的浮点收缩（FMA）计数。

.DESCRIPTION
浮点必须保持严格模式（等价于 C++ 的 -ffp-contract=off），否则碰撞结果会与基线分叉。
口径：只统计**落在导出符号地址区间内**的指令——产物还会链入编译器运行时的数学例程
（fsqrt + 多项式修正），里面有真的 fma，但不在碰撞路径上；全文计数会误报。

用法：
  ./tools/verify-native.ps1 -Library build/zig-native
  ./tools/verify-native.ps1 -Library build/zig-native/windows-x64/EntityCollisionOptimizer.dll

需要 LLVM 工具链里的 llvm-objdump。Mach-O 的导出名取自 __LINKEDIT 的 exports trie
（strip 后 .text 里的标签带前导下划线，且不含"哪些是导出"的信息）。
#>
param(
    [Parameter(Mandatory)][string]$Library,
    [string[]]$ExpectedExportNames = @(
        'lastNativeException', 'createCollisionContext', 'destroyCollisionContext',
        'insertCollisionEntity', 'removeCollisionEntity', 'updateCollisionEntityState',
        'updateCollisionEntityBounds', 'updateCollisionEntitySection',
        'invalidateEntityPushEligibilityCache', 'invalidatePushEligibilityCacheFields',
        'queryHardCollisionEntities', 'queryEntitiesInBox', 'queryPushableEntities',
        'executePushRun', 'prepareMovement', 'solveMovement', 'scanCollisionBlocks'
    )
)

$ErrorActionPreference = 'Stop'

# Mach-O 的 C 符号带一个前导下划线，ELF/PE 不带。比对前统一剥掉。
function Get-CanonicalName([string]$Name) {
    if ($Name.StartsWith('_')) { return $Name.Substring(1) }
    return $Name
}

# 反汇编指令行 → 所属符号的 FMA 计数。符号边界由 "<地址> <名字>:" 标签确定。
function Get-FmaBySymbol([string]$Objdump, [string]$Path) {
    $labelPattern = '^(?<addr>[0-9a-fA-F]+) <(?<name>[^>]+)>:$'
    $insnPattern = '^(?<addr>[0-9a-fA-F]+):\s+(?<text>.*)$'
    $fmaPattern = '\b(v?f(?:n)?m(?:add|sub)(?:1[23][0-9])?[sd]|f(?:n)?m(?:add|sub)[sd])\b'

    $fma = @{}
    $instructions = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    $current = $null
    foreach ($line in (& $Objdump -d --no-show-raw-insn $Path 2>&1)) {
        $label = [regex]::Match($line, $labelPattern)
        if ($label.Success) {
            $current = $label.Groups['name'].Value
            if (-not $fma.ContainsKey($current)) {
                $fma[$current] = 0
                $instructions[$current] = 0
                $order.Add($current)
            }
            continue
        }
        $insn = [regex]::Match($line, $insnPattern)
        if ($insn.Success -and $null -ne $current) {
            $instructions[$current] = $instructions[$current] + 1
            if ([regex]::IsMatch($insn.Groups['text'].Value, $fmaPattern)) {
                $fma[$current] = $fma[$current] + 1
            }
        }
    }
    return @{ Fma = $fma; Instructions = $instructions; Order = $order }
}

# 导出名：Mach-O 读 exports trie，其余格式读反汇编里的标签（strip 后剩下的正是导出）。
function Get-ExportedNames([string]$Objdump, [string]$Path, [string]$Extension, $Labels) {
    if ($Extension -ne '.dylib') { return @($Labels) }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($line in (& $Objdump --macho --exports-trie $Path 2>&1)) {
        $match = [regex]::Match($line, '^0x[0-9a-fA-F]+\s+(?<name>\S+)$')
        if ($match.Success) { $names.Add($match.Groups['name'].Value) }
    }
    return @($names)
}

function Test-NativeLibrary([string]$Path) {
    Write-Host "== $Path"
    $objdump = (Get-Command llvm-objdump -ErrorAction SilentlyContinue).Source
    if (-not $objdump) { throw '需要 llvm-objdump（LLVM 工具链）来反汇编产物。' }

    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $disassembly = Get-FmaBySymbol $objdump $Path
    $rawNames = Get-ExportedNames $objdump $Path $extension $disassembly.Order
    $exported = @($rawNames | ForEach-Object { Get-CanonicalName $_ } | Where-Object { $ExpectedExportNames -contains $_ })

    $missing = @($ExpectedExportNames | Where-Object { $exported -notcontains $_ })
    $unexpected = @($exported | Where-Object { $ExpectedExportNames -notcontains $_ })

    # 按规范名汇总 FMA：Mach-O 的标签名与 trie 名都剥过下划线。
    $fmaInExports = 0
    $offenders = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $disassembly.Fma.GetEnumerator()) {
        $canonical = Get-CanonicalName $entry.Key
        if ($ExpectedExportNames -contains $canonical -and $entry.Value -gt 0) {
            $fmaInExports += $entry.Value
            $offenders.Add("$canonical($($entry.Value))")
        }
    }

    Write-Host ("   导出 {0}/{1}；导出体内 FMA={2}" -f $exported.Count, $ExpectedExportNames.Count, $fmaInExports)

    $ok = $true
    if ($missing.Count -gt 0) {
        Write-Host ("   [失败] 缺失导出：{0}" -f ($missing -join ', ')) -ForegroundColor Red
        $ok = $false
    }
    if ($unexpected.Count -gt 0) {
        Write-Host ("   [失败] 出现预期之外的导出：{0}" -f ($unexpected -join ', ')) -ForegroundColor Red
        $ok = $false
    }
    if ($fmaInExports -gt 0) {
        Write-Host ("   [失败] 导出体内出现浮点收缩：{0}" -f ($offenders -join ', ')) -ForegroundColor Red
        $ok = $false
    }
    if ($ok) { Write-Host '   通过' -ForegroundColor Green }
    return $ok
}

$targets = if (Test-Path -LiteralPath $Library -PathType Container) {
    Get-ChildItem -LiteralPath $Library -Recurse -File | Where-Object { $_.Extension -in '.dll', '.so', '.dylib' }
} else {
    Get-Item -LiteralPath $Library
}
if (-not $targets) { throw "在 $Library 下没有找到原生产物。" }

$allOk = $true
foreach ($target in $targets) {
    if (-not (Test-NativeLibrary $target.FullName)) { $allOk = $false }
}
if (-not $allOk) { throw '原生库门禁未通过。' }
Write-Host '原生库门禁通过。' -ForegroundColor Green
