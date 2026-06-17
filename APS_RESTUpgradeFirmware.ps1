$switch       = "dev"   # "dev" = desk unit only, "prod" = all devices from DB
$devIP        = "192.168.1.105"
$newFwVersion = "2.11.0.230"
$newFwPath    = "C:\Users\Adela\Dropbox\APS\Firmware\2.11\Update-2.11.0.230-APS-RS.tar"
$httpPort     = 9090
$port         = 8091
$logFile      = if ($switch -eq "dev") { "C:\CW_log\APS_RESTUpgradeFirmware.txt" } else { "D:\CW_log\APS_RESTUpgradeFirmware.txt" }
$connStr      = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

function Write-Log ($message, $color = "White") {
    Write-Host $message -ForegroundColor $color
    Add-Content -Path $logFile -Value $message
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Firmware Upgrade to $newFwVersion ---" | Out-File $logFile -Encoding utf8

# --- Serve firmware file via HTTP so APS devices can pull it ---
$localIP   = ([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
              Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
              Select-Object -First 1).IPAddressToString
$packetUrl = "http://${localIP}:${httpPort}/firmware.tar"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:${httpPort}/")
$listener.Start()
Write-Log "HTTP server started: $packetUrl" "Cyan"

$runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$runspace.Open()
$runspace.SessionStateProxy.SetVariable('listener', $listener)
$runspace.SessionStateProxy.SetVariable('newFwPath', $newFwPath)
$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $runspace
[void]$ps.AddScript({
    while ($listener.IsListening) {
        try {
            $ctx   = $listener.GetContext()
            $bytes = [System.IO.File]::ReadAllBytes($newFwPath)
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.ContentType = "application/octet-stream"
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        } catch { }
    }
})
$handle = $ps.BeginInvoke()

# --- Build device list ---
$devices = @()
if ($switch -eq "dev") {
    $devices += [PSCustomObject]@{ Rn = 1; SiteId = "DEV"; Centre = "Desk"; IP = $devIP; DbFw = "0.0.0.0" }
} else {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT row_number() over (order by l.SiteId, l.IP) rn, l.SiteId, Contact Centre, l.IP, l.fw FROM location l JOIN sites s ON s.SiteId = l.SiteId WHERE l.mac LIKE '000b%' AND l.enabled = 1 AND l.fw < '$newFwVersion' ORDER BY l.SiteId"
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
        $devices += [PSCustomObject]@{
            Rn     = $reader["rn"]
            SiteId = $reader["SiteId"]
            Centre = $reader["Centre"]
            IP     = $reader["IP"]
            DbFw   = $reader["fw"]
        }
    }
    $reader.Close()
    $conn.Close()
}

Write-Log "Found $($devices.Count) device(s) with fw < $newFwVersion"
Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4,-12} {5}" -f "No", "SiteId", "Centre", "IP", "Current FW", "Result")
Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4,-12} {5}" -f "--", "------", "------", "--", "----------", "------")

foreach ($device in $devices) {
    $ip     = $device.IP
    $prefix = "{0,-5} {1,-12} {2,-20} {3,-18} {4,-12}" -f $device.Rn, $device.SiteId, $device.Centre, $ip, $device.DbFw

    # Double-check version using [Version] cast (string sort can be unreliable)
    try {
        if ([Version]$device.DbFw -ge [Version]$newFwVersion) {
            Write-Log "$prefix SKIP: already at $($device.DbFw)" "Cyan"
            continue
        }
    } catch {
        Write-Log "$prefix SKIP: could not parse version '$($device.DbFw)'" "Yellow"
        continue
    }

    # --- TCP port check ---
    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Log "$prefix FAIL: port $port closed" "Red"
        continue
    }

    # --- JWT auth ---
    $authUri     = "https://$ip`:$port/auth"
    $authHeaders = @{ "Content-Type" = "application/json;charset=UTF-8" }
    $authBody    = @{ username = "admin"; password = "817King!"; exp = "300" } | ConvertTo-Json -Depth 10

    try {
        $authResp = Invoke-RestMethod -Uri $authUri -Method Post -Headers $authHeaders -Body $authBody -SkipCertificateCheck
        $jwt = $authResp.access_token
    } catch {
        Write-Log "$prefix FAIL: auth failed" "Yellow"
        continue
    }

    # --- PUT firmware upgrade request ---
    $fwUri  = "https://$ip`:$port/apiv2/systemCommand/update"
    $fwBody = @{
        updateType = "UPDATE_FIRMWARE"
        packetUrl  = $packetUrl
        validity   = 48
    } | ConvertTo-Json -Depth 10

    try {
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
        $httpClient = [System.Net.Http.HttpClient]::new($handler)
        $httpClient.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $jwt)
        $content  = [System.Net.Http.StringContent]::new($fwBody, [System.Text.Encoding]::UTF8, "application/json")
        $fwResp   = $httpClient.PutAsync($fwUri, $content).GetAwaiter().GetResult()
        $fwBody2  = $fwResp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($fwResp.IsSuccessStatusCode) {
            Write-Log "$prefix OK: upgrade initiated" "Green"
        } else {
            Write-Log "$prefix FAIL: $($fwResp.StatusCode) $fwBody2" "Yellow"
        }
        $httpClient.Dispose()
        $handler.Dispose()
    } catch {
        Write-Log "$prefix FAIL: $_" "Yellow"
    }
}

# --- Stop HTTP server ---
$listener.Stop()
$ps.EndInvoke($handle)
$ps.Dispose()
$runspace.Close()

Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Firmware Upgrade END ---"
