param([switch]$Resume)

# ============================================================
#  Последовательная установка обновлений Windows (*.msu)
#  - ищет *.msu в папке со скриптом
#  - окно со списком, выбор и порядок установки
#  - после КАЖДОГО обновления перезагрузка, затем автоматически
#    продолжается установка следующего
#  Совместим с Windows PowerShell 5.1 (WinForms).
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$scriptPath = $MyInvocation.MyCommand.Path
$updateDir  = Split-Path -Parent $scriptPath
$stateFile  = Join-Path $updateDir 'update_queue.txt'
$logFile    = Join-Path $updateDir 'update_install.log'
$taskName   = 'MsuSequentialInstaller'

# ---------- Права администратора (автоматический запрос UAC) ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$scriptPath`""
    if ($Resume) { $argList += ' -Resume' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    } catch {
        [System.Windows.Forms.MessageBox]::Show('Нужны права администратора.', 'Установка обновлений') | Out-Null
    }
    exit
}

# ---------- Вспомогательные функции ----------
$script:busy   = $false
$script:cancel = $false

function Get-KB([string]$name) {
    if ($name -match '(KB\d+)') { return $matches[1].ToUpper() }
    return ''
}

# Порядок установки по умолчанию (файлы с другими KB идут после, по имени)
$defaultOrder = @(
    'KB5124008',
    'KB5129195',
    'KB5124010',
    'KB5127648',
    'KB5121794',
    'KB5134133',
    'KB5127936',
    'KB5132061',
    'KB5132057'
)

function Sort-ByDefaultOrder($files) {
    return @($files | Sort-Object `
        @{ Expression = {
            $i = [array]::IndexOf($defaultOrder, (Get-KB $_.Name))
            if ($i -lt 0) { 9999 } else { $i }
        } }, `
        @{ Expression = { $_.Name } })
}

# Возвращает хэш-таблицу: KB -> источник, где найдено обновление.
# Get-HotFix сам по себе неполный (часто не видит накопительные обновления),
# поэтому используются три источника.
function Get-InstalledKBs {
    $res = @{}

    # 1. Журнал Центра обновлений Windows (то же, что в «Параметры → Журнал обновлений»)
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count    = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $okDate  = @{}   # последняя успешная установка
            $delDate = @{}   # последнее удаление
            foreach ($h in $searcher.QueryHistory(0, $count)) {
                if (-not $h.Title -or $h.Title -notmatch '(KB\d+)') { continue }
                $kb = $matches[1].ToUpper()
                if ($h.Operation -eq 1 -and $h.ResultCode -eq 2) {
                    if (-not $okDate.ContainsKey($kb) -or $h.Date -gt $okDate[$kb]) { $okDate[$kb] = $h.Date }
                } elseif ($h.Operation -eq 2 -and $h.ResultCode -eq 2) {
                    if (-not $delDate.ContainsKey($kb) -or $h.Date -gt $delDate[$kb]) { $delDate[$kb] = $h.Date }
                }
            }
            foreach ($kb in $okDate.Keys) {
                if (-not $delDate.ContainsKey($kb) -or $delDate[$kb] -lt $okDate[$kb]) {
                    $res[$kb] = 'журнал обновлений'
                }
            }
        }
    } catch { }

    # 2. Пакеты обслуживания (CBS) в реестре — только полностью установленные
    try {
        $root = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages')
        if ($root) {
            foreach ($name in $root.GetSubKeyNames()) {
                if ($name -notmatch '(KB\d+)') { continue }
                $kb = $matches[1].ToUpper()
                if ($res.ContainsKey($kb)) { continue }
                $sub = $root.OpenSubKey($name)
                if ($sub) {
                    $state = $sub.GetValue('CurrentState')
                    $sub.Close()
                    if ($state -eq 112) { $res[$kb] = 'пакеты системы' }
                }
            }
            $root.Close()
        }
    } catch { }

    # 3. Get-HotFix (Win32_QuickFixEngineering)
    try {
        foreach ($h in (Get-HotFix -ErrorAction Stop)) {
            $kb = $h.HotFixID.ToUpper()
            if (-not $res.ContainsKey($kb)) { $res[$kb] = 'Get-HotFix' }
        }
    } catch { }

    return $res
}

function Read-Queue {
    if (-not (Test-Path $stateFile)) { return @() }
    return @(Get-Content -Path $stateFile -Encoding UTF8 | Where-Object { $_ -and $_.Trim() })
}

function Save-Queue([string[]]$queue) {
    if ($queue -and $queue.Count -gt 0) {
        Set-Content -Path $stateFile -Value $queue -Encoding UTF8
    } elseif (Test-Path $stateFile) {
        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    }
}

function Register-ResumeTask {
    try {
        $user   = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $arg    = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$scriptPath`" -Resume"
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $trig   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $princ  = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trig -Principal $princ -Force | Out-Null
        return $true
    } catch {
        Add-Log ("Не удалось создать задачу автозапуска: " + $_.Exception.Message)
        return $false
    }
}

function Remove-ResumeTask {
    try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
}

# ---------- Интерфейс ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Последовательная установка обновлений (.msu)'
$form.ClientSize = New-Object System.Drawing.Size(860, 640)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760, 560)

$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Location = New-Object System.Drawing.Point(12, 10)
$lblDir.Size = New-Object System.Drawing.Size(836, 20)
$lblDir.Anchor = 'Top,Left,Right'
$lblDir.Text = "Папка: $updateDir   (отметьте галочками и расставьте порядок установки)"
$form.Controls.Add($lblDir)

$lv = New-Object System.Windows.Forms.ListView
$lv.Location = New-Object System.Drawing.Point(12, 34)
$lv.Size = New-Object System.Drawing.Size(836, 290)
$lv.Anchor = 'Top,Left,Right'
$lv.View = 'Details'
$lv.CheckBoxes = $true
$lv.FullRowSelect = $true
$lv.GridLines = $true
$lv.HideSelection = $false
$lv.MultiSelect = $false
[void]$lv.Columns.Add('№', 45)
[void]$lv.Columns.Add('Файл', 340)
[void]$lv.Columns.Add('KB', 90)
[void]$lv.Columns.Add('Размер', 90)
[void]$lv.Columns.Add('Статус', 250)
$form.Controls.Add($lv)

function New-Button([string]$text, [int]$x, [int]$w) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 332)
    $b.Size = New-Object System.Drawing.Size($w, 30)
    $form.Controls.Add($b)
    return $b
}

$btnUp      = New-Button '▲ Вверх' 12 85
$btnDown    = New-Button '▼ Вниз' 103 85
$btnAll     = New-Button 'Выбрать все' 200 100
$btnNone    = New-Button 'Снять все' 306 100
$btnRefresh = New-Button 'Проверить новые файлы' 412 160
$btnStart   = New-Button 'Начать установку' 620 140
$btnCancel  = New-Button 'Отмена' 766 82
$btnStart.Anchor  = 'Top,Right'
$btnCancel.Anchor = 'Top,Right'
$btnCancel.Enabled = $false
$btnStart.Font = New-Object System.Drawing.Font($btnStart.Font, [System.Drawing.FontStyle]::Bold)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(12, 372)
$lblStatus.Size = New-Object System.Drawing.Size(836, 22)
$lblStatus.Anchor = 'Top,Left,Right'
$lblStatus.Font = New-Object System.Drawing.Font($lblStatus.Font, [System.Drawing.FontStyle]::Bold)
$lblStatus.Text = 'Готово к работе.'
$form.Controls.Add($lblStatus)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(12, 398)
$txtLog.Size = New-Object System.Drawing.Size(836, 230)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$form.Controls.Add($txtLog)

function Add-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch { }
    $txtLog.AppendText($line + "`r`n")
}

function Set-Status([string]$text) {
    $lblStatus.Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Numbers {
    for ($i = 0; $i -lt $lv.Items.Count; $i++) {
        $lv.Items[$i].Text = [string]($i + 1)
    }
}

function Add-Row([string]$file, [string]$status, [bool]$checked, [bool]$gray) {
    $full = Join-Path $updateDir $file
    $size = ''
    if (Test-Path $full) { $size = '{0:N1} МБ' -f ((Get-Item $full).Length / 1MB) }
    $it = New-Object System.Windows.Forms.ListViewItem('')
    [void]$it.SubItems.Add($file)
    [void]$it.SubItems.Add((Get-KB $file))
    [void]$it.SubItems.Add($size)
    [void]$it.SubItems.Add($status)
    if ($gray) { $it.ForeColor = [System.Drawing.Color]::Gray }
    [void]$lv.Items.Add($it)
    $it.Checked = $checked
}

function Find-Row([string]$file) {
    foreach ($it in $lv.Items) { if ($it.SubItems[1].Text -eq $file) { return $it } }
    return $null
}

# Добавляет строку для файла с учётом того, установлено ли обновление
function Add-FileRow([string]$name, $installed, [bool]$checkNew) {
    $kb = Get-KB $name
    if ($kb -and $installed.ContainsKey($kb)) {
        Add-Row $name ('Уже установлено (' + $installed[$kb] + ')') $false $true
    } else {
        Add-Row $name 'Не установлено' $checkNew $false
    }
}

# Повторно сканирует папку: добавляет новые *.msu в конец списка,
# убирает файлы, которых больше нет. Порядок и галочки остальных не меняются.
function Update-FileList {
    Set-Status 'Проверка папки...'
    $files = @()
    try {
        $files = Sort-ByDefaultOrder (Get-ChildItem -Path $updateDir -Filter '*.msu' -File -ErrorAction Stop)
    } catch {
        Set-Status 'Не удалось прочитать папку.'
        Add-Log ('Ошибка чтения папки: ' + $_.Exception.Message)
        return
    }
    $installed = Get-InstalledKBs

    $added = @()
    foreach ($fi in $files) {
        if (Find-Row $fi.Name) { continue }
        Add-FileRow $fi.Name $installed (-not $Resume)
        $added += $fi.Name
    }

    $removed = @()
    for ($i = $lv.Items.Count - 1; $i -ge 0; $i--) {
        $n = $lv.Items[$i].SubItems[1].Text
        if (-not (Test-Path (Join-Path $updateDir $n))) {
            $removed += $n
            $lv.Items.RemoveAt($i)
        }
    }
    Update-Numbers

    foreach ($n in $added)   { Add-Log "Найден новый файл: $n" }
    foreach ($n in $removed) { Add-Log "Файл исчез из папки: $n" }

    if ($lv.Items.Count -gt 0) { $btnStart.Enabled = $true }
    if ($added.Count -eq 0 -and $removed.Count -eq 0) {
        Set-Status 'Проверка завершена: изменений нет.'
    } else {
        Set-Status ("Проверка завершена: добавлено {0}, удалено {1}." -f $added.Count, $removed.Count)
    }
}

function Set-RowStatus([string]$file, [string]$status, $color) {
    $it = Find-Row $file
    if ($it) {
        $it.SubItems[4].Text = $status
        if ($color) { $it.ForeColor = $color }
        $it.EnsureVisible()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy([bool]$state) {
    $script:busy = $state
    $on = -not $state
    $btnUp.Enabled = $on; $btnDown.Enabled = $on
    $btnAll.Enabled = $on; $btnNone.Enabled = $on; $btnRefresh.Enabled = $on
    $btnStart.Enabled = $on
    $lv.Enabled = $on
}

function Move-Row([int]$dir) {
    if ($lv.SelectedItems.Count -eq 0) { return }
    $item = $lv.SelectedItems[0]
    $i = $item.Index
    $j = $i + $dir
    if ($j -lt 0 -or $j -ge $lv.Items.Count) { return }
    $lv.BeginUpdate()
    $lv.Items.RemoveAt($i)
    [void]$lv.Items.Insert($j, $item)
    $item.Selected = $true
    $lv.EndUpdate()
    Update-Numbers
    $item.EnsureVisible()
    $lv.Focus() | Out-Null
}

# Обратный отсчёт с возможностью отмены. Возвращает $true, если дождались конца.
function Wait-Countdown([int]$seconds, [string]$template) {
    $script:cancel = $false
    $btnCancel.Enabled = $true
    for ($i = $seconds; $i -gt 0; $i--) {
        Set-Status ($template -f $i)
        for ($k = 0; $k -lt 10; $k++) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:cancel) { break }
            Start-Sleep -Milliseconds 100
        }
        if ($script:cancel) { break }
    }
    $btnCancel.Enabled = $false
    return (-not $script:cancel)
}

# ---------- Установка одного обновления ----------
# Возвращает: 'ok' (нужна перезагрузка), 'skip' (перезагрузка не нужна), 'error'
function Install-One([string]$file) {
    $path = Join-Path $updateDir $file
    $kb = Get-KB $file
    if (-not (Test-Path $path)) {
        Set-RowStatus $file 'ФАЙЛ НЕ НАЙДЕН' ([System.Drawing.Color]::Red)
        Add-Log "Файл не найден: $file"
        return 'error'
    }

    Set-RowStatus $file 'Установка...' ([System.Drawing.Color]::DarkBlue)
    Set-Status "Устанавливается $kb ($file) — это может занять несколько минут..."
    Add-Log "Начало установки: $kb ($file)"

    $p = Start-Process -FilePath 'wusa.exe' -ArgumentList ('"' + $path + '" /quiet /norestart') -PassThru
    $null = $p.Handle   # чтобы корректно получить ExitCode
    while (-not $p.HasExited) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 200
    }
    $code = $p.ExitCode
    $hex  = '0x{0:X8}' -f $code
    Add-Log "wusa.exe завершился с кодом $code ($hex)"

    switch -Regex ($hex) {
        '^0x00000000$|^0x00000BC2$|^0x00240005$' {   # 0 / 3010 / WU_S_REBOOT_REQUIRED
            Set-RowStatus $file 'Установлено (нужна перезагрузка)' ([System.Drawing.Color]::Green)
            return 'ok'
        }
        '^0x00240006$' {                              # уже установлено
            Set-RowStatus $file 'Уже установлено' ([System.Drawing.Color]::Gray)
            return 'skip'
        }
        '^0x80240017$' {                              # не применимо
            Set-RowStatus $file 'Не применимо к этой системе' ([System.Drawing.Color]::DarkOrange)
            return 'skip'
        }
        default {
            Set-RowStatus $file "ОШИБКА $hex" ([System.Drawing.Color]::Red)
            return 'error'
        }
    }
}

# ---------- Основной цикл очереди ----------
function Run-Queue([string[]]$queue) {
    $queue = @($queue)
    Set-Busy $true
    $txtLog.Clear()

    while ($queue.Count -gt 0) {
        $file = $queue[0]
        $rest = @()
        if ($queue.Count -gt 1) { $rest = @($queue[1..($queue.Count - 1)]) }

        $result = Install-One $file

        if ($result -eq 'error') {
            Remove-ResumeTask
            Save-Queue $queue            # сбойное обновление остаётся первым в очереди
            Set-Status 'Установка остановлена из-за ошибки. Подробности в журнале.'
            Add-Log 'Очередь остановлена. Автопродолжение отключено.'
            Set-Busy $false
            [System.Windows.Forms.MessageBox]::Show("Ошибка при установке:`n$file`n`nСм. журнал: $logFile", 'Ошибка', 'OK', 'Error') | Out-Null
            return
        }

        $queue = $rest
        Save-Queue $queue

        if ($result -eq 'skip') { continue }   # перезагрузка не требуется

        # --- 'ok': перезагрузка после каждого обновления ---
        if ($queue.Count -eq 0) {
            Remove-ResumeTask
            Add-Log 'Все обновления установлены. Финальная перезагрузка.'
        } else {
            Add-Log ("Перезагрузка. Осталось обновлений: {0}" -f $queue.Count)
        }

        $go = Wait-Countdown 30 'Перезагрузка через {0} сек. (кнопка «Отмена» — не перезагружать)'
        if ($go) {
            Restart-Computer -Force
            Start-Sleep -Seconds 60
            return
        } else {
            Set-Status 'Перезагрузка отменена. Перезагрузите ПК вручную; установка продолжится после входа в систему.'
            Add-Log 'Перезагрузка отменена пользователем.'
            Set-Busy $false
            return
        }
    }

    # очередь пуста без перезагрузки (все пропущены)
    Remove-ResumeTask
    Save-Queue @()
    Set-Status 'Готово. Очередь обработана.'
    Add-Log 'Очередь обработана.'
    Set-Busy $false
    [System.Windows.Forms.MessageBox]::Show('Очередь обработана.', 'Готово') | Out-Null
}

# ---------- Обработчики ----------
$btnUp.Add_Click({ Move-Row -1 })
$btnDown.Add_Click({ Move-Row 1 })
$btnAll.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $true } })
$btnNone.Add_Click({ foreach ($it in $lv.Items) { $it.Checked = $false } })
$btnCancel.Add_Click({ $script:cancel = $true })
$btnRefresh.Add_Click({ if (-not $script:busy) { Update-FileList } })

$btnStart.Add_Click({
    $q = @()
    foreach ($it in $lv.Items) { if ($it.Checked) { $q += $it.SubItems[1].Text } }
    if ($q.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Отметьте хотя бы одно обновление.', 'Нет выбора') | Out-Null
        return
    }
    $text = "Будет установлено обновлений: $($q.Count).`nПосле каждого — перезагрузка, затем установка продолжится автоматически после входа в систему.`n`nПорядок:`n"
    $n = 1
    foreach ($f in $q) { $text += "{0}. {1}`n" -f $n, $f; $n++ }
    $text += "`nСохраните открытые документы. Продолжить?"
    $ans = [System.Windows.Forms.MessageBox]::Show($text, 'Подтверждение', 'YesNo', 'Question')
    if ($ans -ne 'Yes') { return }

    Save-Queue $q
    if (-not (Register-ResumeTask)) {
        $a2 = [System.Windows.Forms.MessageBox]::Show("Не удалось создать задачу автопродолжения после перезагрузки.`nПродолжить без неё (после перезагрузки запустите скрипт вручную)?", 'Внимание', 'YesNo', 'Warning')
        if ($a2 -ne 'Yes') { return }
    }
    Run-Queue $q
})

$form.Add_FormClosing({
    param($s, $e)
    if ($script:busy) {
        $e.Cancel = $true
        [System.Windows.Forms.MessageBox]::Show('Идёт установка. Дождитесь завершения.', 'Занято') | Out-Null
    }
})

# ---------- Старт ----------
# Незавершённая очередь без -Resume (например, перезагрузку отменили)
if (-not $Resume) {
    $pending = Read-Queue
    if ($pending.Count -gt 0) {
        $ans = [System.Windows.Forms.MessageBox]::Show("Найдена незавершённая очередь ($($pending.Count) шт.).`nПродолжить установку? («Нет» — сбросить очередь)", 'Продолжение', 'YesNo', 'Question')
        if ($ans -eq 'Yes') { $Resume = $true }
        else { Save-Queue @(); Remove-ResumeTask }
    }
}

$installed = Get-InstalledKBs

if ($Resume) {
    foreach ($f in (Read-Queue)) { Add-Row $f 'Ожидает' $true $false }
} else {
    $files = Sort-ByDefaultOrder (Get-ChildItem -Path $updateDir -Filter '*.msu' -File)
    foreach ($fi in $files) { Add-FileRow $fi.Name $installed $true }
}
Update-Numbers

if ($lv.Items.Count -eq 0) {
    Set-Status 'В папке не найдено файлов *.msu'
    $btnStart.Enabled = $false
}

$form.Add_Shown({
    $form.Activate()
    if ($Resume -and $lv.Items.Count -gt 0) {
        Add-Log 'Продолжение установки после перезагрузки.'
        $go = Wait-Countdown 20 'Продолжение установки через {0} сек. (дайте системе завершить настройку обновлений)'
        if ($go) {
            $q = @(Read-Queue)
            Run-Queue $q
        } else {
            Remove-ResumeTask
            Set-Status 'Автопродолжение отменено. Можно изменить порядок и запустить вручную.'
            Add-Log 'Автопродолжение отменено пользователем.'
        }
    }
})

[void]$form.ShowDialog()