$port = 8091
$connStr = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

# --- Query APS devices from CountDb ---
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT SiteId, IP FROM location WHERE mac LIKE '000b%' AND enabled = 1"
$reader = $cmd.ExecuteReader()

$devices = @()
while ($reader.Read()) {
    $devices += [PSCustomObject]@{
        SiteId = $reader["SiteId"]
        IP     = $reader["IP"]
    }
}
$reader.Close()
$conn.Close()

Write-Host ("{0,-12} {1,-18} {2}" -f "SiteId", "IP", "Result")
Write-Host ("{0,-12} {1,-18} {2}" -f "------", "--", "------")

foreach ($device in $devices) {
    $ip = $device.IP

    # --- TCP port check ---
    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Host ("{0,-12} {1,-18} {2}" -f $device.SiteId, $ip, "FAIL: port $port closed") -ForegroundColor Red
        continue
    }

    # --- JWT auth check ---
    $uri = "https://$ip`:$port/auth"
    $headers = @{ "Content-Type" = "application/json;charset=UTF-8" }
    $body = @{ username = "admin"; password = "817King!"; exp = "300" } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -SkipCertificateCheck
        Write-Host ("{0,-12} {1,-18} {2}" -f $device.SiteId, $ip, "OK") -ForegroundColor Green
    } catch {
        Write-Host ("{0,-12} {1,-18} {2}" -f $device.SiteId, $ip, "FAIL: port open, auth failed") -ForegroundColor Yellow
    }
}
