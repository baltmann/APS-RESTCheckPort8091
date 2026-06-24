$dev     = 1    # 1 = desk PC2 only, 0 = all devices from DB
$devIP   = "192.168.1.108"
$port    = 80
$logFile = if ($dev -eq 1) { "C:\CW_log\PC2_GetBackground.txt" } else { "D:\CW_log\PC2_GetBackground.txt" }
$snapDir = if ($dev -eq 1) { "C:\CW_log\Snapshots" } else { "D:\CW_log\Snapshots" }
$connStr = "Server=AUPDC-CTW01P;Database=CountDb;Trusted_Connection=yes;Encrypt=True;TrustServerCertificate=True;"

function Write-Log ($message, $color = "White") {
    Write-Host $message -ForegroundColor $color
    Add-Content -Path $logFile -Value $message
}

function Add-Captions ($jpgPath, $hostname, $description, $captionDt) {
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
    $descSize = $g.MeasureString($description, $font)
    $g.DrawString($description, $font, $brush, ($bmp.Width - $descSize.Width) / 2, 8)
    $dtSize = $g.MeasureString($captionDt, $font)
    $g.DrawString($captionDt, $font, $brush, $bmp.Width - $dtSize.Width - 8, 8)

    $g.Dispose(); $font.Dispose(); $brush.Dispose(); $ms.Dispose()
    $bmp.Save($jpgPath, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bmp.Dispose()
}

"$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- PC2 Get Background Images ---" | Out-File $logFile -Encoding utf8

if (-not (Test-Path $snapDir)) { New-Item -ItemType Directory -Path $snapDir | Out-Null }

# --- Build device list ---
$devices = @()
if ($dev -eq 1) {
    $devices += [PSCustomObject]@{ Rn = 1; SiteId = "DEV"; ContactCode = "GEO"; IP = $devIP; Hostname = "GEO108"; Description = "Dev Camera" }
} else {
    $conn = New-Object System.Data.SqlClient.SqlConnection($connStr)
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "SELECT row_number() over (order by l.SiteId, IP) rn, l.SiteId, Contact Centre, IP, Description, LEFT(Contact,3) + RIGHT('000' + CAST(PARSENAME(IP,1) AS VARCHAR), 3) Hostname FROM location l join sites s on s.SiteId=l.SiteId WHERE mac LIKE '006e%' AND enabled = 1 --AND l.SiteId = 1
ORDER BY l.SiteId"
    $reader = $cmd.ExecuteReader()
    while ($reader.Read()) {
        $devices += [PSCustomObject]@{
            Rn          = $reader["rn"]
            SiteId      = $reader["SiteId"]
            ContactCode = $reader["Centre"]
            IP          = $reader["IP"]
            Description = $reader["Description"]
            Hostname    = $reader["Hostname"]
        }
    }
    $reader.Close()
    $conn.Close()
}

Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4}" -f "No", "SiteId", "Centre", "IP", "Result")
Write-Log ("{0,-5} {1,-12} {2,-20} {3,-18} {4}" -f "--", "------", "------", "--", "------")

$creds   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:817King!"))
$headers = @{
    "Authorization"    = "Basic $creds"
    "accept"           = "image/jpeg"
    "X-Requested-With" = "XmlHttpRequest"
}

foreach ($device in $devices) {
    $ip     = $device.IP
    $prefix = "{0,-5} {1,-12} {2,-20} {3,-18}" -f $device.Rn, $device.SiteId, $device.ContactCode, $ip

    $tcp = Test-NetConnection -ComputerName $ip -Port $port -WarningAction SilentlyContinue
    if (-not $tcp.TcpTestSucceeded) {
        Write-Log "$prefix FAIL: port $port closed" "Red"
        continue
    }

    $now       = Get-Date
    $timestamp = $now.ToString('yyyyMMdd_HHmmss')
    $captionDt = $now.ToString('yyyy-MM-dd HH:mm')
    $jpgPath   = "$snapDir\$($device.Hostname)_$timestamp.jpg"

    try {
        $uri = "http://$ip/api/v5/singlesensor/view/images/background.jpg?json_int64_workaround=false&tracked_objects=false"
        Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -OutFile $jpgPath -UseBasicParsing
        Add-Captions $jpgPath $device.Hostname $device.Description $captionDt
        Write-Log "$prefix OK: $jpgPath" "Green"
    } catch {
        Write-Log "$prefix FAIL: $_" "Yellow"
    }
}

Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') --- PC2 Get Background Images END ---"
