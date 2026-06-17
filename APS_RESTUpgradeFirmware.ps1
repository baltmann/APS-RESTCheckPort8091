$switch       = "dev"   # "dev" = desk unit only, "prod" = all devices from DB
$devIP        = "192.168.1.105"
$newFwVersion = "2.11.0.230"
$packetUrl    = "https://hubpro.xovis.cloud/ps/downloads/aps-rs/aps-rs-firmware/2.11/Update-2.11.0.230-APS-RS.tar"
$port         = 8091
$logFile      = "D:\CW_log\APS_RESTUpgradeFirmware.txt"
$connStr      = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

function Write-Log ($message, $color = "White") {
    Write-Host $message -ForegroundColor $color
    Add-Content -Path $logFile -Value $message
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Firmware Upgrade to $newFwVersion ---" | Out-File $logFile -Encoding utf8

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
    $fwUri     = "https://$ip`:$port/apiv2/systemCommand/updateFirmware"
    $fwHeaders = @{
        "Authorization" = "Bearer $jwt"
        "Content-Type"  = "application/json"
    }
    $fwBody = @{
        requestData = @{
            updateType = "UPDATE_FIRMWARE"
            packetUrl  = $packetUrl
            validity   = 48
        }
    } | ConvertTo-Json -Depth 10

    try {
        $fwResp = Invoke-RestMethod -Uri $fwUri -Method Put -Headers $fwHeaders -Body $fwBody -SkipCertificateCheck
        Write-Log "$prefix OK: upgrade initiated" "Green"
    } catch {
        Write-Log "$prefix FAIL: $_" "Yellow"
    }
}

Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Firmware Upgrade END ---"
