# Define the URL for JWT retrieval on port 8091
$uri = "https://192.168.1.105:8091/auth"

# Define the headers
$headers = @{
    "Content-Type" = "application/json;charset=UTF-8"
}

# Define the JSON payload
$body = @{
    "username" = "admin"
    "password" = "817King!"
    "exp" = "300"
} | ConvertTo-Json -Depth 10

# Bypass SSL certificate validation (if required)
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertificatesPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate, WebRequest request, int certificateProblem) {
        return true;
    }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertificatesPolicy

# Send the POST request to retrieve JWT
try {
    $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body
    $jwt = $response.access_token
    Write-Host "JWT Token: $jwt"
} catch {
    Write-Host "Failed to retrieve JWT. Error: $_"
    Write-Host $uri
    return
}

######################
<#
# Define the URL for image snapshots
$uri = "https://192.168.1.105:8091/apiv2/systemCommand/imageSnapshots"

# Use the JWT retrieved from port 8091
$headers = @{
    "Authorization" = "Bearer $jwt"
}

# Define the file path to save the image .tar archive
#$outputFilePath = "C:\temp\snapshotImages\snap_2024-12-30.tar.gz"
$outputFilePath = "C:\temp\snapshotImages\snap_2026-05-06.tar.gz"

# Send the GET request
try {
    Invoke-WebRequest -Uri $uri -Method Get -Headers $headers -OutFile $outputFilePath -UseBasicParsing
    Write-Host "Image snapshot saved to: $outputFilePath"
} catch {
    Write-Host "Failed to retrieve image snapshot. Error: $_"
}
#>



# Define the configuration object
$bodyObject = @{
    timer = @{
        month  = 6
        day    = 7
        hour   = 13
        minute = 32
    }
    rec_duration = 900
}

# Convert the object to a JSON string
$jsonBody = $bodyObject | ConvertTo-Json -Depth 5

$headers = @{
    "Authorization" = "Bearer $jwt"
    "Content-Type"  = "application/json"
}

$uri = "https://192.168.1.105:8091/apiv2/systemCommand/setUpVideoRecording"

try {
    # Using Invoke-RestMethod for easier handling of the JSON body
    $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $jsonBody -ContentType "application/json"
    
    Write-Host "Success: Recording scheduled." -ForegroundColor Green
    $response # Displays the sensor's confirmation message
}
catch {
    Write-Error "Failed to send request. Stream Error: $($_.Exception.Message)"
}