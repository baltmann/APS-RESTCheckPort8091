$dev     = 1    # 1 = desk APS only, 0 = all devices from DB
$devIP   = "192.168.1.105"
$port    = 8091
$logFile = if ($dev -eq 1) { "C:\CW_log\APS_GetSnapshotImage.txt" } else { "D:\CW_log\APS_GetSnapshotImage.txt" }
$snapDir = if ($dev -eq 1) { "C:\CW_log\Snapshots" } else { "D:\CW_log\Snapshots" }
$connStr = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

function Write-Log ($message, $color = "White") {
    Write-Host $message -ForegroundColor $color
    Add-Content -Path $logFile -Value $message
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Get Snapshot Images ---" | Out-File $logFile -Encoding utf8

if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir | Out-Null }

# --- Build device list ---
$devices = @()
if ($dev -eq 1) {
    $devices += [PSCustomObject]@{ Rn = 1; SiteId = "DEV"; ContactCode = "Desk"; IP = $devIP }
} else {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT row_number() over (order by l.SiteId, IP) rn, l.SiteId, Contact Centre, IP FROM location l join sites s on s.SiteId=l.SiteId WHERE mac LIKE '000b%' AND enabled = 1 ORDER BY l.SiteId"
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
        $devices += [PSCustomObject]@{
            Rn          = $reader["rn"]
            SiteId      = $reader["SiteId"]
            ContactCode = $reader["Centre"]
            IP          = $reader["IP"]
        }
    }
    $reader.Close()
    $conn.Close()
}

Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4}" -f "No", "SiteId", "Centre", "IP", "Result")
Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4}" -f "--", "------", "------", "--", "------")

foreach ($device in $devices) {
    $ip     = $device.IP
    $prefix = "{0,-5} {1,-12} {2,-20} {3,-18}" -f $device.Rn, $device.SiteId, $device.ContactCode, $ip

    # --- TCP port check ---
    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Log "$prefix FAIL: port $port closed" "Red"
        continue
    }

    # --- JWT auth ---
    $uri     = "https://$ip`:$port/auth"
    $headers = @{ "Content-Type" = "application/json;charset=UTF-8" }
    $body    = @{ username = "admin"; password = "817King!"; exp = "300" } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -SkipCertificateCheck
        $jwt = $response.access_token
    } catch {
        Write-Log "$prefix FAIL: auth failed" "Yellow"
        continue
    }

    # --- GET image snapshot ---
    $uri        = "https://$ip`:$port/apiv2/systemCommand/imageSnapshots"
    $headers    = @{ "Authorization" = "Bearer $jwt" }
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outFile    = "$snapDir\$($device.SiteId)_$($ip)_$timestamp.tar.gz"

    try {
        Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -OutFile $outFile -SkipCertificateCheck -UseBasicParsing
        Write-Log "$prefix OK: $outFile" "Green"
    } catch {
        Write-Log "$prefix FAIL: $_" "Yellow"
    }
}

Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Get Snapshot Images END ---"
