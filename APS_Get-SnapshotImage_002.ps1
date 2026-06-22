$dev     = 0    # 1 = desk APS only, 0 = all devices from DB
$devIP   = "192.168.1.109"
$port    = 8091
$logFile = if ($dev -eq 1) { "C:\CW_log\APS_GetSnapshotImage.txt" } else { "D:\CW_log\APS_GetSnapshotImage.txt" }
$snapDir = if ($dev -eq 1) { "C:\CW_log\Snapshots" } else { "D:\CW_log\Snapshots" }
$connStr = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

function Write-Log ($message, $color = "White") {
    Write-Host $message -ForegroundColor $color
    Add-Content -Path $logFile -Value $message
}

function Add-Captions ($jpgPath, $hostname, $captionDt) {
    Add-Type -AssemblyName System.Drawing
    $ms  = [System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes($jpgPath))
    $src = [System.Drawing.Bitmap]::new($ms)
    $bmp = [System.Drawing.Bitmap]::new($src.Width, $src.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.DrawImage($src, 0, 0)
    $src.Dispose()

    $total = 0; $count = 0; $step = 10
    for ($y = 0; $y -lt $bmp.Height; $y += $step) {
        for ($x = 0; $x -lt $bmp.Width; $x += $step) {
            $p = $bmp.GetPixel($x, $y)
            $total += 0.299 * $p.R + 0.587 * $p.G + 0.114 * $p.B
            $count++
        }
    }
    $textColor = if (($total / $count) -lt 128) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black }

    $font  = [System.Drawing.Font]::new("Arial", 14, [System.Drawing.FontStyle]::Bold)
    $brush = [System.Drawing.SolidBrush]::new($textColor)

    $g.DrawString($hostname, $font, $brush, 8, 8)
    $dtSize = $g.MeasureString($captionDt, $font)
    $g.DrawString($captionDt, $font, $brush, $bmp.Width - $dtSize.Width - 8, 8)

    $g.Dispose(); $font.Dispose(); $brush.Dispose(); $ms.Dispose()
    $bmp.Save($jpgPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
}


"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Get Snapshot Images ---" | Out-File $logFile -Encoding utf8

if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir | Out-Null }

# --- Build device list ---
$devices = @()
if ($dev -eq 1) {
    $devices += [PSCustomObject]@{ Rn = 1; SiteId = "DEV"; ContactCode = "Desk"; IP = $devIP; Hostname = "APS905B97" }
} else {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT row_number() over (order by l.SiteId, IP) rn, l.SiteId, Contact Centre, IP, LEFT(Contact,3) + RIGHT('000' + CAST(PARSENAME(IP,1) AS VARCHAR), 3) Hostname FROM location l join sites s on s.SiteId=l.SiteId WHERE mac LIKE '000b%' AND enabled = 1 AND l.SiteId = 1 ORDER BY l.SiteId"
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
        $devices += [PSCustomObject]@{
            Rn          = $reader["rn"]
            SiteId      = $reader["SiteId"]
            ContactCode = $reader["Centre"]
            IP          = $reader["IP"]
            Hostname    = $reader["Hostname"]
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

    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Log "$prefix FAIL: port $port closed" "Red"
        continue
    }

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

    $now       = Get-Date
    $timestamp = $now.ToString('yyyyMMdd_HHmmss')
    $captionDt = $now.ToString('yyyy-MM-dd HH:mm')
    $tempDir   = Join-Path $env:TEMP "aps_$($ip -replace '\.','_')_$timestamp"
    $tarFile   = "$tempDir.tar.gz"

    try {
        New-Item -ItemType Directory -Path $tempDir | Out-Null
        $uri     = "https://$ip`:$port/apiv2/systemCommand/imageSnapshots"
        $headers = @{ "Authorization" = "Bearer $jwt" }
        Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -OutFile $tarFile -SkipCertificateCheck -UseBasicParsing

        tar -xzf $tarFile -C $tempDir 2>$null
        $jpgFile = Get-ChildItem -Path $tempDir -Filter "snapshot_rectified_right.jpg" -Recurse | Select-Object -First 1

        if (-not $jpgFile) {
            Write-Log "$prefix FAIL: snapshot_rectified_right.jpg not found in archive" "Yellow"
        } else {
            $jpgPath = "$snapDir\$($device.Hostname)_$timestamp.jpg"
            Copy-Item -Path $jpgFile.FullName -Destination $jpgPath
            Add-Captions $jpgPath $device.Hostname $captionDt
            Write-Log "$prefix OK: $jpgPath" "Green"
        }
    } catch {
        Write-Log "$prefix FAIL: $_" "Yellow"
    } finally {
        Remove-Item -Path $tarFile    -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- APS Get Snapshot Images END ---"
