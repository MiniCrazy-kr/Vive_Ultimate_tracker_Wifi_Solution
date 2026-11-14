Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$appScript = Join-Path $PSScriptRoot "UTK-WiFiOnly-App.ps1"

function Convert-PrefixLengthToMask {
    param([Parameter(Mandatory = $true)][int]$PrefixLength)

    $mask = [uint32]0
    for ($i = 0; $i -lt $PrefixLength; $i++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $i))
    }
    $bytes = [BitConverter]::GetBytes($mask)
    [Array]::Reverse($bytes)
    return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Get-PreferredIPv4Info {
    $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
        Sort-Object RouteMetric, InterfaceMetric |
        Select-Object -First 1
    if (-not $route) {
        throw "No active IPv4 default route was found."
    }

    $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop |
        Where-Object { $_.IPAddress -and $_.IPAddress -notlike "169.254.*" -and $_.IPAddress -ne "127.0.0.1" } |
        Select-Object -First 1
    if (-not $ip) {
        throw "No usable IPv4 address was found on the default-route adapter."
    }

    $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses)
    if (-not $dns -or $dns.Count -eq 0) {
        $dns = @($route.NextHop)
    }

    return [pscustomobject]@{
        InterfaceIndex = [int]$route.InterfaceIndex
        InterfaceAlias = $adapter.Name
        IPAddress = $ip.IPAddress
        PrefixLength = [int]$ip.PrefixLength
        SubnetMask = Convert-PrefixLengthToMask -PrefixLength ([int]$ip.PrefixLength)
        Gateway = $route.NextHop
        DnsServers = @($dns | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Start-StaticIpAdmin {
    param([Parameter(Mandatory = $true)]$Info)

    $dnsLiteral = "@(" + (($Info.DnsServers | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ",") + ")"
    $adminScript = @"
`$ErrorActionPreference = "Stop"
`$alias = '$($Info.InterfaceAlias -replace "'", "''")'
`$ip = '$($Info.IPAddress)'
`$mask = '$($Info.SubnetMask)'
`$gateway = '$($Info.Gateway)'
`$dns = $dnsLiteral
netsh interface ip set address name="`$alias" static `$ip `$mask `$gateway 1
if (`$dns.Count -gt 0) {
    `$primaryDns = `$dns[0]
    netsh interface ip set dns name="`$alias" static `$primaryDns primary
    for (`$i = 1; `$i -lt `$dns.Count; `$i++) {
        `$dnsServer = `$dns[`$i]
        `$dnsIndex = `$i + 1
        netsh interface ip add dns name="`$alias" `$dnsServer index=`$dnsIndex
    }
}
Write-Host "Static IP applied to `${alias}: `$ip / `$mask gateway `$gateway"
Start-Sleep -Seconds 2
"@

    $tempScript = Join-Path $env:TEMP ("utk_static_ip_init_{0}.ps1" -f ([Guid]::NewGuid().ToString("N")))
    Set-Content -LiteralPath $tempScript -Value $adminScript -Encoding ASCII
    Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $tempScript
    ) | Out-Null
}

function Start-AppProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExtraArgs,
        [switch]$Visible
    )

    $argsList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $appScript
    ) + $ExtraArgs

    $style = if ($Visible) { "Normal" } else { "Hidden" }
    $argumentText = (($argsList | ForEach-Object {
        $text = [string]$_
        if ($text -match '[\s"]') {
            '"' + ($text -replace '"', '\"') + '"'
        } else {
            $text
        }
    }) -join " ")
    Start-Process -FilePath "powershell.exe" -ArgumentList $argumentText -WindowStyle $style | Out-Null
}

function ConvertFrom-TrackerDevicesTsv {
    param([string]$Text)
    $output = @($Text -split '\r?\n')
    if (-not $output -or $output.Count -lt 2) {
        return @()
    }
    $headers = @($output[0] -split "`t")
    $items = @()
    foreach ($line in @($output | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = @($line -split "`t", $headers.Count)
        $item = [ordered]@{}
        for ($i = 0; $i -lt $headers.Count; $i++) {
            $value = if ($i -lt $parts.Count) { $parts[$i] } else { "" }
            $item[$headers[$i]] = $value
        }
        $items += [pscustomobject]$item
    }
    return $items
}

function Compare-TrackerDeviceSortValue {
    param([string]$Column, [string]$Left, [string]$Right)
    if ($Column -eq "IP") {
        $leftIp = $null
        $rightIp = $null
        if ([version]::TryParse($Left, [ref]$leftIp) -and [version]::TryParse($Right, [ref]$rightIp)) {
            return $leftIp.CompareTo($rightIp)
        }
    } elseif ($Column -in @("SteamVRUdpPort", "TcpPort")) {
        $leftPort = 0
        $rightPort = 0
        [void][int]::TryParse($Left, [ref]$leftPort)
        [void][int]::TryParse($Right, [ref]$rightPort)
        return $leftPort.CompareTo($rightPort)
    }
    return [string]::Compare($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-TrackerControl {
    param([string]$Ip, [ValidateSet("power_off", "identify", "start_map_sync")][string]$Action = "power_off",
        [string]$PrimarySerial, [string]$SecondarySerial)

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $connect = $client.BeginConnect("127.0.0.1", 19005, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(1200)) {
            throw "Control API is not available. Restart Start Service once to enable tracker controls."
        }
        $client.EndConnect($connect)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        $stream.WriteTimeout = 1500
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($stream, $utf8NoBom)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $reader = New-Object System.IO.StreamReader($stream, $utf8NoBom)
        $target = if ([string]::IsNullOrWhiteSpace($Ip)) { "all" } else { $Ip }
        $payload = @{ action = $Action; ip = $target; primary_serial = $PrimarySerial; secondary_serial = $SecondarySerial } | ConvertTo-Json -Compress
        $writer.WriteLine($payload)
        $line = $reader.ReadLine()
        if (-not $line) {
            throw "No response from control API."
        }
        $response = $line | ConvertFrom-Json
        if (-not $response.ok) {
            throw "Tracker command failed: $($response.error)"
        }
        if ($Action -eq "start_map_sync") { return "Map sync requested for $SecondarySerial." }
        $label = if ($Action -eq "identify") { "Identify" } else { "Power off" }
        return "$label sent to: $(@($response.sent) -join ', ')"
    } finally {
        if ($client) {
            $client.Close()
        }
    }
}

function Show-DevicesWindow {
    $devicesForm = New-Object System.Windows.Forms.Form
    $devicesForm.Text = "Connected UTK Devices"
    $devicesForm.StartPosition = "CenterParent"
    $devicesForm.Size = New-Object System.Drawing.Size(980, 500)
    $devicesForm.MinimumSize = New-Object System.Drawing.Size(860, 390)
    $devicesForm.Font = $font
    $devicesForm.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $headerLabel = New-Object System.Windows.Forms.Label
    $headerLabel.Text = "Connected trackers"
    $headerLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 12, [System.Drawing.FontStyle]::Bold)
    $headerLabel.Location = New-Object System.Drawing.Point(14, 12)
    $headerLabel.Size = New-Object System.Drawing.Size(260, 26)
    $devicesForm.Controls.Add($headerLabel)

    $hintLabel = New-Object System.Windows.Forms.Label
    $hintLabel.Text = "Select one tracker for single-device actions."
    $hintLabel.ForeColor = [System.Drawing.Color]::FromArgb(94, 103, 115)
    $hintLabel.Location = New-Object System.Drawing.Point(280, 16)
    $hintLabel.Size = New-Object System.Drawing.Size(390, 22)
    $devicesForm.Controls.Add($hintLabel)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(14, 46)
    $grid.Size = New-Object System.Drawing.Size(710, 350)
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.BorderStyle = "FixedSingle"
    $grid.EnableHeadersVisualStyles = $false
    $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(232, 237, 244)
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(35, 42, 52)
    foreach ($column in @("IP", "PeerPort", "TcpPort", "SteamVRUdpPort", "TrackingStatus", "TrackerSN", "DeviceSN", "Firmware", "LastPoseAgeMs", "PoseStatus", "Battery", "MapReport")) {
        [void]$grid.Columns.Add($column, $column)
    }
    $grid.Columns["TrackingStatus"].HeaderText = "Tracking"
    $grid.Columns["TrackingStatus"].FillWeight = 90
    $grid.Columns["TrackerSN"].FillWeight = 155
    $grid.Columns["DeviceSN"].FillWeight = 145
    $grid.Columns["IP"].FillWeight = 125
    $grid.Columns["SteamVRUdpPort"].HeaderText = "SteamVR"
    $grid.Columns["LastPoseAgeMs"].HeaderText = "Pose age (ms)"
    $sortState = @{
        Column = "IP"
        Direction = [System.ComponentModel.ListSortDirection]::Ascending
    }
    $grid.Columns["IP"].HeaderCell.SortGlyphDirection = [System.Windows.Forms.SortOrder]::Ascending
    $grid.Add_SortCompare({
        param($sender, $eventArgs)
        $result = Compare-TrackerDeviceSortValue -Column $eventArgs.Column.Name -Left $eventArgs.CellValue1 -Right $eventArgs.CellValue2
        if ($result -eq 0 -and $eventArgs.Column.Name -ne "IP") {
            $leftIp = $sender.Rows[$eventArgs.RowIndex1].Cells["IP"].Value
            $rightIp = $sender.Rows[$eventArgs.RowIndex2].Cells["IP"].Value
            $result = Compare-TrackerDeviceSortValue -Column "IP" -Left $leftIp -Right $rightIp
        }
        $eventArgs.SortResult = $result
        $eventArgs.Handled = $true
    })
    $grid.Add_Sorted({
        if ($grid.SortedColumn -and $grid.SortOrder -ne [System.Windows.Forms.SortOrder]::None) {
            $sortState.Column = $grid.SortedColumn.Name
            $sortState.Direction = if ($grid.SortOrder -eq [System.Windows.Forms.SortOrder]::Descending) {
                [System.ComponentModel.ListSortDirection]::Descending
            } else {
                [System.ComponentModel.ListSortDirection]::Ascending
            }
        }
    })
    $devicesForm.Controls.Add($grid)

    $sidePanel = New-Object System.Windows.Forms.Panel
    $sidePanel.Location = New-Object System.Drawing.Point(742, 46)
    $sidePanel.Size = New-Object System.Drawing.Size(210, 350)
    $sidePanel.Anchor = "Top,Bottom,Right"
    $sidePanel.BackColor = [System.Drawing.Color]::White
    $sidePanel.BorderStyle = "FixedSingle"
    $devicesForm.Controls.Add($sidePanel)

    $actionsLabel = New-Object System.Windows.Forms.Label
    $actionsLabel.Text = "Device actions"
    $actionsLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
    $actionsLabel.Location = New-Object System.Drawing.Point(14, 14)
    $actionsLabel.Size = New-Object System.Drawing.Size(170, 24)
    $sidePanel.Controls.Add($actionsLabel)

    $selectedLabel = New-Object System.Windows.Forms.Label
    $selectedLabel.Text = "Selected: none"
    $selectedLabel.Location = New-Object System.Drawing.Point(14, 50)
    $selectedLabel.Size = New-Object System.Drawing.Size(180, 42)
    $selectedLabel.ForeColor = [System.Drawing.Color]::FromArgb(72, 81, 94)
    $sidePanel.Controls.Add($selectedLabel)

    $powerOneButton = New-Object System.Windows.Forms.Button
    $powerOneButton.Text = "Power Off Selected"
    $powerOneButton.Location = New-Object System.Drawing.Point(14, 106)
    $powerOneButton.Size = New-Object System.Drawing.Size(180, 34)
    $sidePanel.Controls.Add($powerOneButton)

    $identifyButton = New-Object System.Windows.Forms.Button
    $identifyButton.Text = "$([char]::ConvertFromUtf32(0x1F50D)) Identify Selected"
    $identifyButton.Location = New-Object System.Drawing.Point(14, 154)
    $identifyButton.Size = New-Object System.Drawing.Size(180, 34)
    $sidePanel.Controls.Add($identifyButton)
    $syncCheck = New-Object System.Windows.Forms.CheckBox
    $syncCheck.Text = "Sync with main tracker"
    $syncCheck.Location = New-Object System.Drawing.Point(14, 194)
    $syncCheck.Size = New-Object System.Drawing.Size(180, 24)
    $sidePanel.Controls.Add($syncCheck)

    $syncButton = New-Object System.Windows.Forms.Button
    $syncButton.Text = "Sync Selected"
    $syncButton.Location = New-Object System.Drawing.Point(14, 224)
    $syncButton.Size = New-Object System.Drawing.Size(180, 34)
    $syncButton.Enabled = $false
    $sidePanel.Controls.Add($syncButton)
    $syncCheck.Add_CheckedChanged({ $syncButton.Enabled = $syncCheck.Checked })
    $resetButton = New-Object System.Windows.Forms.Button
    $resetButton.Text = "Factory Reset (USB)"
    $resetButton.Location = New-Object System.Drawing.Point(14, 264)
    $resetButton.Size = New-Object System.Drawing.Size(180, 34)
    $sidePanel.Controls.Add($resetButton)
    $resetButton.Add_Click({
        if ($grid.SelectedRows.Count -ne 1) {
            $statusLabel.Text = "Select one tracker first."
            return
        }
        $serial = ([string]$grid.SelectedRows[0].Cells["TrackerSN"].Value).TrimStart([char]0x2605, [char]32).Trim()
        if (-not $serial) {
            $statusLabel.Text = "The selected tracker has no reported serial."
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $devicesForm, "Factory reset $serial? This may erase saved tracker settings and maps.",
            "Factory Reset (USB)", "YesNo", "Warning", "Button2")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            if (-not ("UtkUsbReset" -as [type])) {
                Add-Type -Path (Join-Path $PSScriptRoot "UTK-UsbReset.cs") -ErrorAction Stop
            }
            [UtkUsbReset]::Reset($serial)
            $statusLabel.Text = "Factory reset command sent to $serial."
        } catch {
            $statusLabel.Text = $_.Exception.GetBaseException().Message
        }
    })



    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh"
    $refreshButton.Location = New-Object System.Drawing.Point(14, 412)
    $refreshButton.Size = New-Object System.Drawing.Size(95, 30)
    $refreshButton.Anchor = "Bottom,Left"
    $devicesForm.Controls.Add($refreshButton)

    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.Location = New-Object System.Drawing.Point(120, 418)
    $statusLabel.Size = New-Object System.Drawing.Size(520, 24)
    $statusLabel.Anchor = "Bottom,Left,Right"
    $statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(72, 81, 94)
    $devicesForm.Controls.Add($statusLabel)

    $powerAllButton = New-Object System.Windows.Forms.Button
    $powerAllButton.Text = "Power Off All"
    $powerAllButton.Location = New-Object System.Drawing.Point(742, 412)
    $powerAllButton.Size = New-Object System.Drawing.Size(100, 30)
    $powerAllButton.Anchor = "Bottom,Right"
    $devicesForm.Controls.Add($powerAllButton)

    $closeDevicesButton = New-Object System.Windows.Forms.Button
    $closeDevicesButton.Text = "Close"
    $closeDevicesButton.Location = New-Object System.Drawing.Point(852, 412)
    $closeDevicesButton.Size = New-Object System.Drawing.Size(95, 30)
    $closeDevicesButton.Anchor = "Bottom,Right"
    $devicesForm.Controls.Add($closeDevicesButton)

    function Get-SelectedTrackerIp {
        if ($grid.SelectedRows.Count -le 0) {
            return ""
        }
        return [string]$grid.SelectedRows[0].Cells["IP"].Value
    }

    function Update-SelectedLabel {
        $ip = Get-SelectedTrackerIp
        if ($ip) {
            $selectedLabel.Text = "Selected:`r`n$ip"
        } else {
            $selectedLabel.Text = "Selected: none"
        }
    }

    # The worker returns TSV. Only WinForms timer callbacks read or update controls.
    $refreshState = @{ Process = $null; Output = $null; Errors = $null; Deadline = $null }
    $completionTimer = New-Object System.Windows.Forms.Timer
    $completionTimer.Interval = 100

    function Stop-DeviceQuery {
        $completionTimer.Stop()
        if ($refreshState.Process) {
            try {
                if (-not $refreshState.Process.HasExited) {
                    $refreshState.Process.Kill()
                }
            } catch [System.InvalidOperationException] {
                # The process can exit between HasExited and Kill.
            } finally {
                $refreshState.Process.Dispose()
                $refreshState.Process = $null
                $refreshState.Output = $null
                $refreshState.Errors = $null
            }
        }
        $refreshButton.Enabled = $true
    }

    function Start-DeviceRefresh {
        param([switch]$Manual)
        if ($Manual) {
            $refreshButton.Enabled = $false
            $statusLabel.Text = "Refreshing tracker list..."
        }
        if ($refreshState.Process) {
            return
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo.FileName = "powershell.exe"
        $process.StartInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action DevicesTsv' -f $appScript
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        try {
            [void]$process.Start()
            $refreshState.Process = $process
            $refreshState.Output = $process.StandardOutput.ReadToEndAsync()
            $refreshState.Errors = $process.StandardError.ReadToEndAsync()
            $refreshState.Deadline = [DateTime]::UtcNow.AddSeconds(15)
            $completionTimer.Start()
        } catch {
            if ($refreshState.Process) { Stop-DeviceQuery } else { $process.Dispose() }
            $refreshButton.Enabled = $true
            $statusLabel.Text = "Refresh failed: $($_.Exception.Message)"
        }
    }

    function Update-DeviceGrid {
        param([object[]]$Rows)
        $selectedIp = Get-SelectedTrackerIp
        $mainSerial = if (Test-Path -LiteralPath $mainTrackerPath) {
            [string](Get-Content -LiteralPath $mainTrackerPath -TotalCount 1 -ErrorAction SilentlyContinue)
        }
        $existing = @{}
        foreach ($gridRow in $grid.Rows) {
            $existing[[string]$gridRow.Cells["IP"].Value] = $gridRow
        }
        $sortNeeded = $false
        foreach ($row in $rows) {
            $key = [string]$row.IP
            if ($existing.ContainsKey($key)) {
                $gridRow = $existing[$key]
                $existing.Remove($key)
            } else {
                $gridRow = $grid.Rows[$grid.Rows.Add()]
                $sortNeeded = $true
            }
            $values = @(
                [string]$row.IP,
                [string]$row.PeerPort,
                [string]$row.TcpPort,
                [string]$row.SteamVRUdpPort,
                [string]$row.TrackingStatus,
                $(if ($mainSerial -and $row.TrackerSN -eq $mainSerial) {
                    "$([char]0x2605) $($row.TrackerSN)"
                } else { [string]$row.TrackerSN }),
                [string]$row.DeviceSN,
                [string]$row.Firmware,
                [string]$row.LastPoseAgeMs,
                [string]$row.PoseStatus,
                [string]$row.Battery,
                [string]$row.MapReport
            )
            for ($i = 0; $i -lt $values.Count; $i++) {
                $cell = $gridRow.Cells[$i]
                if ([string]$cell.Value -cne $values[$i]) {
                    $cell.Value = $values[$i]
                    if ($grid.Columns[$i].Name -eq $sortState.Column) { $sortNeeded = $true }
                }
            }
            $statusCell = $gridRow.Cells["TrackingStatus"]
            $statusColor = switch ($row.TrackingStatus) {
                "Tracking" { [System.Drawing.Color]::DarkGreen }
                "Tracking lost" { [System.Drawing.Color]::DarkRed }
                "Offline" { [System.Drawing.Color]::DimGray }
                default { [System.Drawing.Color]::SaddleBrown }
            }
            if ($statusCell.Style.ForeColor -ne $statusColor) { $statusCell.Style.ForeColor = $statusColor }
        }
        foreach ($obsolete in $existing.Values) { $grid.Rows.Remove($obsolete) }
        if ($grid.Rows.Count -gt 0 -and $sortNeeded) {
            $grid.Sort($grid.Columns[$sortState.Column], $sortState.Direction)
        }
        if ($grid.Rows.Count -gt 0 -and (Get-SelectedTrackerIp) -ne $selectedIp -or
            $grid.Rows.Count -gt 0 -and -not $selectedIp) {
            $selectedRow = $grid.Rows | Where-Object { $_.Cells["IP"].Value -eq $selectedIp } | Select-Object -First 1
            $grid.ClearSelection()
            if ($selectedRow) {
                $selectedRow.Selected = $true
            } elseif (-not $selectedIp) {
                $grid.Rows[0].Selected = $true
            }
        }
        Update-SelectedLabel
        $statusLabel.Text = "Found $($rows.Count) tracker device(s). Last refresh: $(Get-Date -Format 'HH:mm:ss')"
    }

    $completionTimer.Add_Tick({
        try {
            if (-not ($refreshState.Process.HasExited -and $refreshState.Output.IsCompleted -and $refreshState.Errors.IsCompleted)) {
                if ([DateTime]::UtcNow -lt $refreshState.Deadline) { return }
                throw "Tracker query timed out."
            }
            if ($refreshState.Process.ExitCode -ne 0) {
                $message = $refreshState.Errors.GetAwaiter().GetResult().Trim()
                if (-not $message) { $message = "Tracker query exited with code $($refreshState.Process.ExitCode)." }
                throw $message
            }
            $rows = @(ConvertFrom-TrackerDevicesTsv -Text $refreshState.Output.GetAwaiter().GetResult())
            Update-DeviceGrid -Rows $rows
        } catch {
            $statusLabel.Text = "Refresh failed: $($_.Exception.Message)"
        }
        Stop-DeviceQuery
    })
    $refreshButton.Add_Click({ Start-DeviceRefresh -Manual })
    $grid.Add_SelectionChanged({ Update-SelectedLabel })
    $syncButton.Add_Click({
        if (-not $syncCheck.Checked -or $grid.SelectedRows.Count -ne 1) {
            $statusLabel.Text = "Select one secondary tracker."
            return
        }
        try {
            $primary = if (Test-Path -LiteralPath $mainTrackerPath) {
                ([string](Get-Content -LiteralPath $mainTrackerPath -TotalCount 1 -ErrorAction Stop)).Trim()
            }
            if (-not $primary) {
                $statusLabel.Text = "Set the main tracker in Tracker Bindings first."
                return
            }
            $secondary = ([string]$grid.SelectedRows[0].Cells["TrackerSN"].Value).TrimStart([char]0x2605, [char]32).Trim()
            $statusLabel.Text = Invoke-TrackerControl -Action start_map_sync -PrimarySerial $primary -SecondarySerial $secondary
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $identifyButton.Add_Click({
        $ip = Get-SelectedTrackerIp
        if (-not $ip) {
            $statusLabel.Text = "Select a tracker first."
            return
        }
        try {
            $statusLabel.Text = Invoke-TrackerControl -Ip $ip -Action identify
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $powerOneButton.Add_Click({
        $ip = Get-SelectedTrackerIp
        if (-not $ip) {
            [System.Windows.Forms.MessageBox]::Show("Select a tracker first.", "No tracker selected", "OK", "Information") | Out-Null
            return
        }
        $answer = [System.Windows.Forms.MessageBox]::Show("Power off tracker $ip?", "Confirm power off", "YesNo", "Warning")
        if ($answer -ne "Yes") {
            return
        }
        try {
            $statusLabel.Text = Invoke-TrackerControl -Ip $ip
            Start-DeviceRefresh
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $powerAllButton.Add_Click({
        $answer = [System.Windows.Forms.MessageBox]::Show("Power off all connected trackers?", "Confirm power off all", "YesNo", "Warning")
        if ($answer -ne "Yes") {
            return
        }
        try {
            $statusLabel.Text = Invoke-TrackerControl -Ip "all"
            Start-DeviceRefresh
        } catch {
            $statusLabel.Text = $_.Exception.Message
        }
    })
    $closeDevicesButton.Add_Click({ $devicesForm.Close() })
    $refreshTimer = New-Object System.Windows.Forms.Timer
    $refreshTimer.Interval = 3000
    $refreshTimer.Add_Tick({ Start-DeviceRefresh })
    Start-DeviceRefresh
    try {
        $refreshTimer.Start()
        $workArea = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $devicesForm.Size = New-Object System.Drawing.Size([Math]::Min(1220, $workArea.Width), [Math]::Min(560, $workArea.Height))
        [void]$devicesForm.ShowDialog($form)
    } finally {
        $refreshTimer.Dispose()
        Stop-DeviceQuery
        $completionTimer.Dispose()
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "UTK WiFi-only One Click"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(700, 500)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Font = $font

$title = New-Object System.Windows.Forms.Label
$title.Text = "VIVE Ultimate Tracker WiFi-only"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 13, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(22, 18)
$title.Size = New-Object System.Drawing.Size(390, 28)
$form.Controls.Add($title)

$devicesButton = New-Object System.Windows.Forms.Button
$devicesButton.Text = "Devices"
$devicesButton.Location = New-Object System.Drawing.Point(580, 18)
$devicesButton.Size = New-Object System.Drawing.Size(84, 28)
$form.Controls.Add($devicesButton)

$ssidLabel = New-Object System.Windows.Forms.Label
$ssidLabel.Text = "Hotspot SSID"
$ssidLabel.Location = New-Object System.Drawing.Point(24, 68)
$ssidLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($ssidLabel)

$ssidBox = New-Object System.Windows.Forms.TextBox
$ssidBox.Text = ""
$ssidBox.Location = New-Object System.Drawing.Point(160, 66)
$ssidBox.Size = New-Object System.Drawing.Size(300, 24)
$form.Controls.Add($ssidBox)

$passwordLabel = New-Object System.Windows.Forms.Label
$passwordLabel.Text = "Hotspot Password"
$passwordLabel.Location = New-Object System.Drawing.Point(24, 106)
$passwordLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($passwordLabel)

$passwordBox = New-Object System.Windows.Forms.TextBox
$passwordBox.Text = ""
$passwordBox.UseSystemPasswordChar = $true
$passwordBox.Location = New-Object System.Drawing.Point(160, 104)
$passwordBox.Size = New-Object System.Drawing.Size(300, 24)
$form.Controls.Add($passwordBox)

$serverIpLabel = New-Object System.Windows.Forms.Label
$serverIpLabel.Text = "Local PC IP"
$serverIpLabel.Location = New-Object System.Drawing.Point(24, 144)
$serverIpLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($serverIpLabel)

$serverIpBox = New-Object System.Windows.Forms.TextBox
$serverIpBox.Text = ""
$serverIpBox.Location = New-Object System.Drawing.Point(160, 142)
$serverIpBox.Size = New-Object System.Drawing.Size(180, 24)
$form.Controls.Add($serverIpBox)

$initButton = New-Object System.Windows.Forms.Button
$initButton.Text = "Initialize"
$initButton.Location = New-Object System.Drawing.Point(350, 140)
$initButton.Size = New-Object System.Drawing.Size(110, 28)
$form.Controls.Add($initButton)

$bindingsButton = New-Object System.Windows.Forms.Button
$bindingsButton.Text = "Tracker Bindings"
$bindingsButton.Location = New-Object System.Drawing.Point(470, 140)
$bindingsButton.Size = New-Object System.Drawing.Size(140, 28)
$form.Controls.Add($bindingsButton)

$steamvrCheck = New-Object System.Windows.Forms.CheckBox
$steamvrCheck.Text = "Auto-register SteamVR driver"
$steamvrCheck.Checked = $true
$steamvrCheck.Location = New-Object System.Drawing.Point(160, 184)
$steamvrCheck.Size = New-Object System.Drawing.Size(210, 24)
$form.Controls.Add($steamvrCheck)

$firewallCheck = New-Object System.Windows.Forms.CheckBox
$firewallCheck.Text = "Try to add firewall rule"
$firewallCheck.Checked = $false
$firewallCheck.Location = New-Object System.Drawing.Point(160, 214)
$firewallCheck.Size = New-Object System.Drawing.Size(210, 24)
$form.Controls.Add($firewallCheck)

$debugModeCheck = New-Object System.Windows.Forms.CheckBox
$debugModeCheck.Text = "Debug mode"
$debugModeCheck.Checked = $false
$debugModeCheck.Location = New-Object System.Drawing.Point(370, 214)
$debugModeCheck.Size = New-Object System.Drawing.Size(120, 24)
$form.Controls.Add($debugModeCheck)

$trackerLabel = New-Object System.Windows.Forms.Label
$trackerLabel.Text = "Reserved UTK slots"
$trackerLabel.Location = New-Object System.Drawing.Point(24, 248)
$trackerLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($trackerLabel)

$trackerCountBox = New-Object System.Windows.Forms.NumericUpDown
$trackerCountBox.Minimum = 1
$trackerCountBox.Maximum = 16
$trackerCountBox.Value = 5
$trackerCountBox.Location = New-Object System.Drawing.Point(160, 246)
$trackerCountBox.Size = New-Object System.Drawing.Size(80, 24)
$form.Controls.Add($trackerCountBox)

$bindingModeBox = New-Object System.Windows.Forms.ComboBox
$bindingModeBox.DropDownStyle = "DropDownList"
$bindingModeBox.Location = New-Object System.Drawing.Point(260, 246)
$bindingModeBox.Size = New-Object System.Drawing.Size(396, 24)
[void]$bindingModeBox.Items.Add("Fixed binding (tracker serial)")
[void]$bindingModeBox.Items.Add("Legacy binding (arrival order)")
$bindingModeBox.SelectedIndex = 0
$stateDir = Join-Path (Split-Path -Parent $PSScriptRoot) "backups\utk_wifi_only_app"
$bindingStatePath = Join-Path $stateDir "keepalive_process.json"
$bindingPath = Join-Path $stateDir "tracker_bindings.json"
$mainTrackerPath = Join-Path $stateDir "main_tracker.txt"
if (Test-Path -LiteralPath $bindingStatePath) {
    try {
        $bindingState = Get-Content -LiteralPath $bindingStatePath -Raw | ConvertFrom-Json
        if ($bindingState.binding_mode -eq "Legacy") { $bindingModeBox.SelectedIndex = 1 }
    } catch { }
}
$form.Controls.Add($bindingModeBox)
$bindingModeBox.Add_SelectedIndexChanged({
    $statusBox.Text = "Binding mode applies on next service start. Click Stop, then Start Service. Saved fixed bindings are retained in Legacy mode."
})

$frequencyLabel = New-Object System.Windows.Forms.Label
$frequencyLabel.Text = "Power / Pose Rate"
$frequencyLabel.Location = New-Object System.Drawing.Point(24, 279)
$frequencyLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($frequencyLabel)

$frequencyBox = New-Object System.Windows.Forms.ComboBox
$frequencyBox.DropDownStyle = "DropDownList"
$frequencyBox.Location = New-Object System.Drawing.Point(160, 277)
$frequencyBox.Size = New-Object System.Drawing.Size(100, 24)
[void]$frequencyBox.Items.Add("50 Hz")
[void]$frequencyBox.Items.Add("60 Hz")
$frequencyBox.SelectedIndex = if ($bindingState.power_frequency_hz -eq 60) { 1 } else { 0 }
$form.Controls.Add($frequencyBox)
$frequencyBox.Add_SelectedIndexChanged({
    $statusBox.Text = "Power frequency and pose rate apply on next service start. Click Stop, then Start Service."
})

$trackingDelayLabel = New-Object System.Windows.Forms.Label
$trackingDelayLabel.Text = "Tracking lost delay (ms)"
$trackingDelayLabel.Location = New-Object System.Drawing.Point(280, 279)
$trackingDelayLabel.Size = New-Object System.Drawing.Size(160, 24)
$form.Controls.Add($trackingDelayLabel)

$trackingDelayBox = New-Object System.Windows.Forms.NumericUpDown
$trackingDelayBox.Location = New-Object System.Drawing.Point(447, 277)
$trackingDelayBox.Size = New-Object System.Drawing.Size(90, 24)
$trackingDelayBox.Minimum = 50
$trackingDelayBox.Maximum = 2000
$trackingDelayBox.Increment = 50
$trackingDelayBox.Value = if ($bindingState.tracking_lost_delay_ms -ge 50 -and $bindingState.tracking_lost_delay_ms -le 2000) {
    [int]$bindingState.tracking_lost_delay_ms
} else { 200 }
$form.Controls.Add($trackingDelayBox)
$trackingDelayBox.Add_ValueChanged({
    $statusBox.Text = "To apply the tracking lost delay, restart the service and then SteamVR."
})

$serviceLogCheck = New-Object System.Windows.Forms.CheckBox
$serviceLogCheck.Text = "Save logs"
$serviceLogCheck.Checked = $bindingState.service_logging -ne $false
$serviceLogCheck.Location = New-Object System.Drawing.Point(548, 277)
$serviceLogCheck.Size = New-Object System.Drawing.Size(108, 24)
$form.Controls.Add($serviceLogCheck)

$statusBox = New-Object System.Windows.Forms.TextBox
$statusBox.Multiline = $true
$statusBox.ReadOnly = $true
$statusBox.ScrollBars = "Vertical"
$statusBox.Location = New-Object System.Drawing.Point(24, 315)
$statusBox.Size = New-Object System.Drawing.Size(632, 82)
$statusBox.Text = "Normal mode starts compact UDP with ACK-on-connect and binary UTKP paced at the selected rate. Periodic ATM21 refresh is disabled because it can trigger lost-tracking flashes."
$form.Controls.Add($statusBox)

$serviceButton = New-Object System.Windows.Forms.Button
$serviceButton.Text = "Start Service"
$serviceButton.Location = New-Object System.Drawing.Point(24, 412)
$serviceButton.Size = New-Object System.Drawing.Size(112, 30)
$form.Controls.Add($serviceButton)

$flashButton = New-Object System.Windows.Forms.Button
$flashButton.Text = "Flash WiFi"
$flashButton.Location = New-Object System.Drawing.Point(146, 412)
$flashButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($flashButton)

$dongleButton = New-Object System.Windows.Forms.Button
$dongleButton.Text = "Dongle Mode"
$dongleButton.Location = New-Object System.Drawing.Point(256, 412)
$dongleButton.Size = New-Object System.Drawing.Size(112, 30)
$form.Controls.Add($dongleButton)

$statusButton = New-Object System.Windows.Forms.Button
$statusButton.Text = "Status"
$statusButton.Location = New-Object System.Drawing.Point(378, 412)
$statusButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($statusButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(488, 412)
$stopButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($stopButton)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "Close"
$closeButton.Location = New-Object System.Drawing.Point(588, 412)
$closeButton.Size = New-Object System.Drawing.Size(90, 30)
$form.Controls.Add($closeButton)

try {
    $initialInfo = Get-PreferredIPv4Info
    $serverIpBox.Text = $initialInfo.IPAddress
    $statusBox.Text = "Detected local PC IP $($initialInfo.IPAddress) on $($initialInfo.InterfaceAlias). Click Initialize to lock it as static before flashing WiFi."
} catch {
    $statusBox.Text = "Could not auto-detect local PC IP. Enter it manually or click Initialize after connecting the PC to the router."
}

$initButton.Add_Click({
    try {
        $info = Get-PreferredIPv4Info
        $serverIpBox.Text = $info.IPAddress
        Start-StaticIpAdmin -Info $info
        $statusBox.Text = "Admin static-IP setup requested for $($info.InterfaceAlias): $($info.IPAddress). Approve UAC, then use Flash WiFi to burn this IP into the tracker."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Initialize failed", "OK", "Error") | Out-Null
        $statusBox.Text = "Initialize failed: $($_.Exception.Message)"
    }
})

$bindingsButton.Add_Click({
    try {
        $state = if (Test-Path -LiteralPath $bindingStatePath) {
            Get-Content -LiteralPath $bindingStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        $basePort = $null
        if ($state.binding_mode -eq "Fixed" -and $state.pose_forward_auto_map -match ':(\d+)$') {
            $basePort = [int]$Matches[1]
        }
        $bindings = if (Test-Path -LiteralPath $bindingPath) {
            Get-Content -LiteralPath $bindingPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        }
        $mainSerial = if (Test-Path -LiteralPath $mainTrackerPath) {
            [string](Get-Content -LiteralPath $mainTrackerPath -TotalCount 1 -ErrorAction Stop)
        }
        $entries = if ($bindings) { $bindings.PSObject.Properties | Sort-Object { [int]$_.Value }, Name }
        $rows = if ($bindings) {
            foreach ($entry in $entries) {
                $slot = [int]$entry.Value
                [pscustomobject]@{
                    Slot = $slot
                    TrackerSN = if ($entry.Name -eq $mainSerial) { "$([char]0x2605) $($entry.Name)" } else { $entry.Name }
                    SteamVRUdpPort = if ($null -ne $basePort) { $basePort + $slot - 1 } else { "-" }
                }
            }
        }
        $mode = if ($state.binding_mode) { $state.binding_mode } else { "Unknown" }
        $body = if ($rows) {
            ($rows | Format-Table -AutoSize | Out-String -Width 120).TrimEnd()
        } else {
            "No saved tracker bindings."
        }
        $dialog = New-Object System.Windows.Forms.Form
        $dialog.Text = "Tracker Bindings"
        $dialog.StartPosition = "CenterParent"
        $dialog.ClientSize = New-Object System.Drawing.Size(480, 300)
        try {
            $view = New-Object System.Windows.Forms.TextBox
            $view.Dock = "Fill"
            $view.Multiline = $true
            $view.ReadOnly = $true
            $view.WordWrap = $false
            $view.ScrollBars = "Both"
            $view.Font = New-Object System.Drawing.Font("Consolas", 10)
            $view.Text = "Last recorded service mode: $mode" + [Environment]::NewLine + "Saved fixed slots" + [Environment]::NewLine + $body
            $dialog.Controls.Add($view)
            $mainSelector = New-Object System.Windows.Forms.ComboBox
            $mainSelector.Dock = "Top"
            $mainSelector.DropDownStyle = "DropDownList"
            [void]$mainSelector.Items.Add("No main tracker")
            foreach ($entry in $entries) { [void]$mainSelector.Items.Add($entry.Name) }
            $selected = if ([string]::IsNullOrWhiteSpace($mainSerial)) { 0 } else {
                $mainSelector.Items.IndexOf($mainSerial.Trim())
            }
            $mainSelector.SelectedIndex = [Math]::Max(0, $selected)
            $saveMainButton = New-Object System.Windows.Forms.Button
            $saveMainButton.Dock = "Bottom"
            $saveMainButton.Text = "Save main tracker (local selection)"
            $saveMainButton.Add_Click({
                try {
                    $serial = if ($mainSelector.SelectedIndex -gt 0) { [string]$mainSelector.SelectedItem } else { "" }
                    Set-Content -LiteralPath $mainTrackerPath -Value $serial -Encoding ASCII -ErrorAction Stop
                    $dialog.Close()
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show($dialog, $_.Exception.Message, "Tracker Bindings")
                }
            })
            $dialog.Controls.Add($mainSelector)
            $dialog.Controls.Add($saveMainButton)
            [void]$dialog.ShowDialog($form)
        } finally {
            $dialog.Dispose()
        }
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "Tracker Bindings")
    }
})

$serviceButton.Add_Click({
    $frequencyHz = if ($frequencyBox.SelectedIndex -eq 1) { "60" } else { "50" }
    $argsList = @(
        "-Action", "StartKeepalive",
        "-TrackerCount", ([string][int]$trackerCountBox.Value),
        "-BindingMode", $(if ($bindingModeBox.SelectedIndex -eq 0) { "Fixed" } else { "Legacy" }),
        "-StopViveTrackerServer",
        "-UdpPosePort", "9005",
        "-AckOnConnect:`$true",
        "-ForwardBurstMode", "paced",
        "-PowerFrequencyHz", $frequencyHz,
        "-TrackingLostDelayMs", [string]$trackingDelayBox.Value,
        "-PacedMaxDelayMs", "45",
        "-PoseForwardFormat", "binary",
        "-PoseForwardIncludeZero:`$true",
        "-ControlRefreshPayloads", "ATM21",
        "-ControlRefreshSeconds", "0",
        "-ControlRefreshStartDelaySeconds", "0",
        "-LatencyStatsSeconds", "1"
    )
    if (-not $steamvrCheck.Checked) {
        $argsList += "-AutoRegisterSteamVR:`$false"
    }
    if ($firewallCheck.Checked) {
        $argsList += "-EnsureFirewallRule"
    }
    if (-not $serviceLogCheck.Checked) { $argsList += "-NoServiceLogs" }
    if ($debugModeCheck.Checked) {
        $argsList += @(
            "-Realtime:`$false",
            "-ForwardBurstMode", "all",
            "-PoseForwardFormat", "json",
            "-MinimalPoseJson:`$false",
            "-FullPayloadHex",
            "-PreviewBytes", "4096"
        )
    }

    Start-AppProcess -ExtraArgs $argsList -Visible
    if ($debugModeCheck.Checked) {
        $statusBox.Text = "Debug service start requested at $frequencyHz Hz power frequency. Pose packets are forwarded without pacing for captures."
    } else {
        $statusBox.Text = "Normal service start requested at $frequencyHz Hz power frequency and pose rate. Keep this running first, then let the tracker connect to WiFi."
    }
})

$flashButton.Add_Click({
    if ([string]::IsNullOrWhiteSpace($ssidBox.Text) -or [string]::IsNullOrWhiteSpace($passwordBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please enter hotspot SSID and password.", "Missing info", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($serverIpBox.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Please initialize or enter Local PC IP before flashing WiFi.", "Missing IP", "OK", "Warning") | Out-Null
        return
    }

    $argsList = @(
        "-Action", "ApplyWifi",
        "-Ssid", $ssidBox.Text,
        "-Password", $passwordBox.Text,
        "-ServerIp", $serverIpBox.Text,
        "-Proto", "udp",
        "-Frequency", "0"
    )

    Start-AppProcess -ExtraArgs $argsList -Visible
    $statusBox.Text = "WiFi-only flash requested with ServerIp=$($serverIpBox.Text), UDP props, and full-scan frequency. Use this only when needed."
})

$dongleButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "RestoreDongle") -Visible
    $statusBox.Text = "Dongle mode restore requested. After it finishes, the tracker should be visible to VIVE Hub through the official receiver path."
})

$statusButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Status") -Visible
})

$devicesButton.Add_Click({
    Show-DevicesWindow
})

$stopButton.Add_Click({
    Start-AppProcess -ExtraArgs @("-Action", "Stop") -Visible
    $statusBox.Text = "Stop command sent."
})

$closeButton.Add_Click({
    $form.Close()
})

[void]$form.ShowDialog()
