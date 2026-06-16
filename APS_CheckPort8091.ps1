$port = 8091
$connStr = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

# --- Query APS devices from CountDb ---
$conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "SELECT row_number() over (order by SiteId, IP) rn, SiteId, IP FROM location WHERE mac LIKE '000b%' AND enabled = 1 ORDER BY SiteId"
$reader = $cmd.ExecuteReader()

$devices = @()
while ($reader.Read()) {
    $devices += [PSCustomObject]@{
        Rn     = $reader["rn"]
        SiteId = $reader["SiteId"]
        IP     = $reader["IP"]
    }
}
$reader.Close()
$conn.Close()

Write-Host ("{0,-5} {1,-12} {2,-18} {3}" -f "No", "SiteId", "IP", "Result")
Write-Host ("{0,-5} {1,-12} {2,-18} {3}" -f "--", "------", "--", "------")

foreach ($device in $devices) {
    $ip     = $device.IP
    $prefix = "{0,-5} {1,-12} {2,-18}" -f $device.Rn, $device.SiteId, $ip

    # --- TCP port check ---
    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Host ("$prefix FAIL: port $port closed") -ForegroundColor Red
        continue
    }

    # --- JWT auth check ---
    $uri = "https://$ip`:$port/auth"
    $headers = @{ "Content-Type" = "application/json;charset=UTF-8" }
    $body = @{ username = "admin"; password = "817King!"; exp = "300" } | ConvertTo-Json -Depth 10

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -SkipCertificateCheck
        Write-Host ("$prefix OK") -ForegroundColor Green
    } catch {
        Write-Host ("$prefix FAIL: port open, auth failed") -ForegroundColor Yellow
    }
}
