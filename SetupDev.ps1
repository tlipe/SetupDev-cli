#requires -Version 5.1
<#
    Setup Dev v1.1.0
    Developer workstation bootstrapper for Windows 10/11 x64.

    Controls:
      UP/DOWN  move
      SPACE    select/unselect
      ENTER    analyze selection and continue
      ESC      cancel/back out

    Requires:
      Windows 10/11 + WinGet (App Installer)
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$Version = 'v1.1.0'
$Title = 'Setup Dev'

function Write-Color {
    param(
        [string]$Text = '',
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoNewLine
    )

    if ($NoNewLine) {
        Write-Host $Text -ForegroundColor $Color -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Write-Rule {
    $width = [Math]::Min([Console]::WindowWidth - 2, 70)
    if ($width -lt 20) { $width = 20 }
    Write-Color ([string][char]0x2500 * $width) DarkGray
}

function Show-Header {
    Clear-Host
    Write-Color ''
    Write-Color "  Setup Dev $Version" Cyan
    Write-Color ''
}

function Test-WinGet {
    return [bool](Get-Command winget.exe -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')

    $parts = @()
    if ($machine) { $parts += $machine }
    if ($user) { $parts += $user }

    $env:Path = ($parts -join ';')
}

function Test-Command {
    param([string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-WinGetInstalledMap {
    $map = @{}

    if (-not (Test-WinGet)) {
        return $map
    }

    try {
        $output = & winget.exe list --accept-source-agreements --disable-interactivity 2>$null | Out-String
        foreach ($item in $script:Items) {
            if ($output -match [Regex]::Escape($item.Id)) {
                $map[$item.Id] = $true
            }
        }
    } catch {}

    return $map
}

function Test-Python312 {
    try {
        $out = & py.exe '-3.12' '--version' 2>$null | Select-Object -First 1
        return ($out -match '^Python 3\.12\.')
    } catch {
        return $false
    }
}

function Test-RustComplete {
    Refresh-Path

    $required = @('rustup', 'rustc', 'cargo', 'rustfmt', 'cargo-clippy')
    foreach ($cmd in $required) {
        if (-not (Test-Command $cmd)) {
            return $false
        }
    }

    try {
        $toolchains = & rustup.exe toolchain list 2>$null | Out-String
        if ($toolchains -notmatch 'stable-x86_64-pc-windows-msvc') {
            return $false
        }

        & rustup.exe run stable rustc --version 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
    } catch {
        return $false
    }

    return $true
}

function Test-MinGW {
    return (
        (Test-Path 'C:\msys64\ucrt64\bin\gcc.exe') -and
        (Test-Path 'C:\msys64\ucrt64\bin\g++.exe') -and
        (Test-Path 'C:\msys64\ucrt64\bin\gdb.exe')
    )
}

function Test-Docker {
    if (Test-Command 'docker') {
        return $true
    }

    $paths = @(
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe",
        "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe"
    )

    return [bool]($paths | Where-Object { Test-Path $_ })
}

function Test-VSCode {
    if (Test-Command 'code') { return $true }

    $paths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "$env:ProgramFiles\Microsoft VS Code\Code.exe"
    )

    return [bool]($paths | Where-Object { Test-Path $_ })
}

function Test-Codex {
    Refresh-Path
    return (Test-Command 'codex')
}

function Test-OpenCode {
    Refresh-Path
    return (Test-Command 'opencode')
}

function Test-VSBuildToolsCpp {
    $paths = @(
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    $vswhere = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $vswhere) {
        return $false
    }

    try {
        $result = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -latest -property installationPath 2>$null
        return [bool]$result
    } catch {
        return $false
    }
}

function Invoke-WinGetInstall {
    param(
        [string]$Id,
        [string[]]$ExtraArguments = @()
    )

    $wingetArgs = @(
        'install',
        '--id', $Id,
        '--exact',
        '--source', 'winget',
        '--accept-source-agreements',
        '--accept-package-agreements'
    ) + $ExtraArguments

    & winget.exe @wingetArgs
    return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010)
}

function Install-Rust {
    Write-Color '  Rustup' White

    if (-not (Invoke-WinGetInstall 'Rustlang.Rustup' @('--silent'))) {
        return $false
    }

    Refresh-Path

    if (-not (Test-Command 'rustup')) {
        return $false
    }

    if (-not (Test-VSBuildToolsCpp)) {
        Write-Color '    Instalando C++ Build Tools exigidos pelo toolchain MSVC...' Gray

        $ok = Invoke-WinGetInstall 'Microsoft.VisualStudio.BuildTools' @(
            '--override',
            '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
        )

        if (-not $ok) {
            return $false
        }
    }

    Refresh-Path

    & rustup.exe toolchain install stable-x86_64-pc-windows-msvc --profile complete 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    & rustup.exe default stable-x86_64-pc-windows-msvc 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    & rustup.exe component add rustfmt clippy rust-src 2>&1
    if ($LASTEXITCODE -ne 0) { return $false }

    Refresh-Path
    return (Test-RustComplete)
}

function Install-MinGW {
    if (-not (Invoke-WinGetInstall 'MSYS2.MSYS2' @('--silent'))) {
        return $false
    }

    $pacman = 'C:\msys64\usr\bin\pacman.exe'
    if (-not (Test-Path $pacman)) {
        return $false
    }

    & $pacman '-S' '--needed' '--noconfirm' 'mingw-w64-ucrt-x86_64-toolchain'
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    $bin = 'C:\msys64\ucrt64\bin'
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')

    if ($userPath -and $userPath -notlike "*$bin*") {
        [Environment]::SetEnvironmentVariable(
            'Path',
            (($userPath.TrimEnd(';') + ';' + $bin).Trim(';')),
            'User'
        )
    } elseif (-not $userPath) {
        [Environment]::SetEnvironmentVariable('Path', $bin, 'User')
    }

    Refresh-Path
    return (Test-MinGW)
}

function Install-Docker {
    return (Invoke-WinGetInstall 'Docker.DockerDesktop' @('--silent'))
}

function Install-OpenCode {
    Refresh-Path

    if (-not (Test-Command 'npm')) {
        Write-Color '    Dependencia ausente: Node.js LTS. Instalando...' Gray

        if (-not (Invoke-WinGetInstall 'OpenJS.NodeJS.LTS' @('--silent'))) {
            return $false
        }

        Refresh-Path
    }

    if (-not (Test-Command 'npm')) {
        return $false
    }

    & npm.cmd 'install' '-g' 'opencode-ai'
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    Refresh-Path
    return (Test-OpenCode)
}

function Install-Codex {
    return (Invoke-WinGetInstall 'OpenAI.Codex' @('--silent'))
}

function Invoke-Install {
    param($Item)

    switch ($Item.Key) {
        'git'      { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'python'   { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'go'       { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'rust'     { return (Install-Rust) }
        'mingw'    { return (Install-MinGW) }
        'docker'   { return (Install-Docker) }
        'node'     { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'bun'      { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'park'     { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'vscode'   { return (Invoke-WinGetInstall $Item.Id @('--silent')) }
        'codex'    { return (Install-Codex) }
        'opencode' { return (Install-OpenCode) }
        default    { return $false }
    }
}

function Test-Item {
    param(
        $Item,
        [hashtable]$WingetMap
    )

    Refresh-Path

    switch ($Item.Key) {
        'git'      { return (Test-Command 'git') }
        'python'   { return (Test-Python312) }
        'go'       { return (Test-Command 'go') }
        'rust'     { return (Test-RustComplete) }
        'mingw'    { return (Test-MinGW) }
        'docker'   { return (Test-Docker) }
        'node'     { return (Test-Command 'node') }
        'bun'      { return (Test-Command 'bun') }
        'park'     { return $WingetMap.ContainsKey($Item.Id) }
        'vscode'   { return (Test-VSCode) }
        'codex'    { return (Test-Codex) }
        'opencode' { return (Test-OpenCode) }
        default    { return $false }
    }
}

function Get-ItemStatusText {
    param(
        $Item,
        [hashtable]$WingetMap
    )

    $present = Test-Item $Item $WingetMap

    if ($present) {
        return @{
            Present = $true
            Text = 'INSTALADO'
            Color = [ConsoleColor]::Green
        }
    }

    return @{
        Present = $false
        Text = 'FALTANDO'
        Color = [ConsoleColor]::Yellow
    }
}

function Render-Menu {
    param(
        [int]$Cursor,
        [hashtable]$StatusMap
    )

    Clear-Host
    Write-Color ''
    Write-Color "  Setup Dev $Version" Cyan
    Write-Color '  Up/Down mover  SPACE selecionar  A todos  ENTER confirmar  ESC cancelar' DarkGray
    Write-Color ''
    Write-Rule

    $groups = [ordered]@{}
    foreach ($item in $script:Items) {
        if (-not $groups.Contains($item.Category)) {
            $groups[$item.Category] = [System.Collections.ArrayList]::new()
        }
        [void]$groups[$item.Category].Add($item)
    }

    $i = 0
    foreach ($cat in $groups.Keys) {
        Write-Color ''
        Write-Color "  $cat" Blue

        foreach ($item in $groups[$cat]) {
            $box = if ($item.Selected) { '[X]' } else { '[ ]' }
            $status = $StatusMap[$item.Key]
            $statusText = if ($status) { $status.Text } else { '---' }
            $statusColor = if ($status) { $status.Color } else { [ConsoleColor]::Gray }

            $padLen = 24 - $item.Name.Length
            if ($padLen -lt 1) { $padLen = 1 }
            $namePadded = $item.Name + (' ' * $padLen)

            if ($i -eq $Cursor) {
                Write-Color "  > $box $namePadded" White -NoNewLine
                Write-Color " $statusText" $statusColor
            } else {
                Write-Color "    $box $namePadded" Gray -NoNewLine
                Write-Color " $statusText" $statusColor
            }
            $i++
        }
    }

    Write-Color ''
    Write-Rule

    $selectedCount = @($script:Items | Where-Object Selected).Count
    Write-Color "  Selecionados: $selectedCount" Gray

    $focused = $script:Items[$Cursor]
    if ($focused.Description) {
        Write-Color "  $($focused.Description)" DarkGray
    }
}

function Build-StatusMap {
    $wingetMap = Get-WinGetInstalledMap
    $map = @{}

    foreach ($item in $script:Items) {
        $map[$item.Key] = Get-ItemStatusText $item $wingetMap
    }

    return @{
        Winget = $wingetMap
        Items = $map
    }
}

function Show-Scan {
    param([string]$Phase)

    Clear-Host
    Write-Color ''
    Write-Color "  Setup Dev $Version" Cyan
    Write-Color ''
    Write-Color "  $Phase" White
    Write-Color ''
    Write-Color '  Aguarde...' Gray
}

function Get-SelectionPlan {
    return @($script:Items | Where-Object Selected)
}

function Add-Dependency {
    param(
        [System.Collections.ArrayList]$Plan,
        $Dependency
    )

    if (-not ($Plan | Where-Object Key -eq $Dependency.Key)) {
        [void]$Plan.Add($Dependency)
    }
}

function Resolve-Dependencies {
    param(
        [System.Collections.ArrayList]$Plan,
        [hashtable]$StatusMap
    )

    if (($Plan | Where-Object Key -eq 'opencode') -and -not $StatusMap['node'].Present) {
        Add-Dependency $Plan ($script:Items | Where-Object Key -eq 'node')
    }

    return $Plan
}

function Show-Confirmation {
    param(
        [System.Collections.ArrayList]$Plan
    )

    Show-Header
    Write-Color '  Plano final de instalacao' White
    Write-Color ''

    foreach ($item in $Plan) {
        if ($item.Key -eq 'node' -and -not $item.Selected) {
            Write-Color "  + $($item.Name)    (dependencia do OpenCode)" DarkCyan
        } elseif ($item.Key -eq 'rust' -and $item.Selected) {
            Write-Color "  + Rust             (Rustup + stable MSVC + componentes)" Cyan
        } else {
            Write-Color "  + $($item.Name)" Gray
        }
    }

    Write-Color ''
    Write-Rule
    Write-Color ''
    Write-Color '  ENTER  instalar    ESC  cancelar' White

    while ($true) {
        $key = [Console]::ReadKey($true)

        if ($key.Key -eq [ConsoleKey]::Enter) {
            return $true
        }

        if ($key.Key -eq [ConsoleKey]::Escape) {
            return $false
        }
    }
}

$script:Items = @(
    [pscustomobject]@{
        Key='git'; Category='Versionamento'; Name='Git'; Id='Git.Git'
        Description='Controle de versao distribuido'
        Selected=$false
    }
    [pscustomobject]@{
        Key='python'; Category='Linguagens'; Name='Python 3.12'; Id='Python.Python.3.12'
        Description='Linha estavel 3.12'
        Selected=$false
    }
    [pscustomobject]@{
        Key='go'; Category='Linguagens'; Name='Golang'; Id='GoLang.Go'
        Description='Compilador e toolchain Go'
        Selected=$false
    }
    [pscustomobject]@{
        Key='rust'; Category='Linguagens'; Name='Rust'; Id='Rustlang.Rustup'
        Description='Rustup + stable MSVC + componentes essenciais'
        Selected=$false
    }
    [pscustomobject]@{
        Key='mingw'; Category='Build e Toolchains'; Name='MinGW / MSYS2 UCRT64'; Id='MSYS2.MSYS2'
        Description='GCC + G++ + GDB + Make + toolchain completo'
        Selected=$false
    }
    [pscustomobject]@{
        Key='docker'; Category='Containers'; Name='Docker Desktop'; Id='Docker.DockerDesktop'
        Description='Containers e ambiente Docker'
        Selected=$false
    }
    [pscustomobject]@{
        Key='node'; Category='JavaScript Runtime'; Name='Node.js LTS'; Id='OpenJS.NodeJS.LTS'
        Description='Node + npm + npx'
        Selected=$false
    }
    [pscustomobject]@{
        Key='bun'; Category='JavaScript Runtime'; Name='Bun'; Id='Oven-sh.Bun'
        Description='Runtime + package manager + bundler'
        Selected=$false
    }
    [pscustomobject]@{
        Key='park'; Category='Sistema'; Name='ParkControl'; Id='BitSum.ParkControl'
        Description='Controle de core parking / desempenho da CPU'
        Selected=$false
    }
    [pscustomobject]@{
        Key='vscode'; Category='Ferramentas'; Name='Visual Studio Code'; Id='Microsoft.VisualStudioCode'
        Description='Editor de codigo'
        Selected=$false
    }
    [pscustomobject]@{
        Key='codex'; Category='AI Dev CLI'; Name='Codex CLI'; Id='OpenAI.Codex'
        Description='Agente de codigo da OpenAI no terminal'
        Selected=$false
    }
    [pscustomobject]@{
        Key='opencode'; Category='AI Dev CLI'; Name='OpenCode'; Id='opencode-ai'
        Description='Agente de codigo open source no terminal'
        Selected=$false
    }
)

if (-not (Test-WinGet)) {
    Show-Header
    Write-Color '  ERRO: WinGet nao foi encontrado.' Red
    Write-Color ''
    Write-Color '  O Setup Dev usa o Windows Package Manager para instalar os aplicativos.' Gray
    Write-Color '  Atualize/instale o App Installer pela Microsoft Store e execute novamente.' Gray
    Write-Color ''
    Read-Host '  Pressione ENTER para sair'
    exit 1
}

Show-Scan 'Analisando seu ambiente...'
$initial = Build-StatusMap
$statuses = $initial.Items

$cursor = 0
$menuDone = $false

while (-not $menuDone) {
    Render-Menu $cursor $statuses
    $key = [Console]::ReadKey($true)

    switch ($key.Key) {
        'UpArrow' {
            $cursor = ($cursor - 1 + $script:Items.Count) % $script:Items.Count
        }
        'DownArrow' {
            $cursor = ($cursor + 1) % $script:Items.Count
        }
        'Spacebar' {
            $script:Items[$cursor].Selected = -not $script:Items[$cursor].Selected
        }
        'A' {
            $allSelected = @($script:Items | Where-Object Selected).Count -eq $script:Items.Count
            foreach ($item in $script:Items) { $item.Selected = -not $allSelected }
        }
        'Enter' {
            $menuDone = $true
        }
        'Escape' {
            Show-Header
            Write-Color '  Cancelado.' Yellow
            exit 0
        }
    }
}

Show-Scan 'Reanalisando a selecao...'
$second = Build-StatusMap
$statuses = $second.Items

$selected = Get-SelectionPlan
$plan = [System.Collections.ArrayList]::new()

foreach ($item in $selected) {
    if (-not $statuses[$item.Key].Present) {
        [void]$plan.Add($item)
    }
}

$plan = Resolve-Dependencies $plan $statuses

Show-Header
Write-Color '  Resultado da analise' White
Write-Color ''

if ($selected.Count -eq 0) {
    Write-Color '  Nenhum item foi selecionado.' Yellow
    Write-Color ''
    exit 0
}

foreach ($item in $selected) {
    if ($statuses[$item.Key].Present) {
        Write-Color "  OK   $($item.Name) - ja instalado" Green
    } else {
        Write-Color "  ADD  $($item.Name) - sera instalado" Yellow
    }
}

if ($plan.Count -eq 0) {
    Write-Color ''
    Write-Color '  Tudo o que foi selecionado ja esta instalado.' Green
    Write-Color ''
    exit 0
}

Write-Color ''
Write-Color '  O instalador nao reinstala itens detectados como presentes.' DarkGray
Write-Color ''

if (-not (Show-Confirmation $plan)) {
    Show-Header
    Write-Color '  Instalacao cancelada.' Yellow
    exit 0
}

Show-Header
Write-Color '  Instalando ambiente...' White
Write-Color ''

$results = @()

foreach ($item in $plan) {
    Write-Color "  [$($item.Name)]" Cyan

    try {
        $ok = Invoke-Install $item
    } catch {
        $ok = $false
    }

    Refresh-Path

    if ($ok) {
        Write-Color '      OK' Green
    } else {
        Write-Color '      FALHOU' Red
    }

    $results += [pscustomobject]@{
        Name = $item.Name
        Success = $ok
    }

    Write-Color ''
}

Show-Scan 'Verificacao final...'
$final = Build-StatusMap

Show-Header
Write-Color '  Resultado final' White
Write-Color ''

foreach ($result in $results) {
    $item = $script:Items | Where-Object Name -eq $result.Name | Select-Object -First 1
    $status = $final.Items[$item.Key]

    if ($status.Present) {
        Write-Color "  OK   $($item.Name)" Green
    } else {
        Write-Color "  !!   $($item.Name) - ainda nao detectado" Yellow
    }
}

Write-Color ''
Write-Rule
Write-Color '  Observacoes:' Gray
Write-Color '  PATH atualizado nesta sessao quando possivel; abra um novo terminal se necessario.' DarkGray
Write-Color '  Docker Desktop pode exigir configuracao/reinicio do WSL 2.' DarkGray
Write-Color '  ParkControl e instalado, mas o script nao altera planos de energia.' DarkGray
Write-Color '  OpenCode usa npm; no Windows, WSL e recomendado pelo projeto.' DarkGray
Write-Color ''
Read-Host '  Pressione ENTER para sair'
