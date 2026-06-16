# APS device to check
$ip = "192.168.1.105"
$port = 8091

# --- TCP port check ---
$tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    Write-Host "FAIL: Port $port is not reachable on $ip" -ForegroundColor Red
    exit 1
}
Write-Host "OK: Port $port is open on $ip" -ForegroundColor Green

# --- JWT auth check ---
$uri = "https://$ip`:$port/auth"

$headers = @{ "Content-Type" = "application/json;charset=UTF-8" }
$body = @{ username = "admin"; password = "817King!"; exp = "300" } | ConvertTo-Json -Depth 10

try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -SkipCertificateCheck
    $jwt = $response.access_token
    Write-Host "OK: JWT retrieved successfully" -ForegroundColor Green
    Write-Host "Token: $jwt"
} catch {
    Write-Host "FAIL: Port is open but auth failed. Error: $_" -ForegroundColor Red
}
