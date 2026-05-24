$ErrorActionPreference = "Stop"

function Write-Step($message) {
    Write-Host "[build] $message"
}

Write-Step "Validating local Ollama setup"
& "$PSScriptRoot\setup.ps1"

$appPort = $env:APP_PORT
if ([string]::IsNullOrWhiteSpace($appPort)) {
    $appPort = "8080"
}

Write-Step "Building Spring Boot jar"
Push-Location $PSScriptRoot
try {
    .\mvnw.cmd clean package

    Write-Step "Building Docker image and starting app"
    docker compose up -d --build app

    Write-Step "App is starting at http://localhost:$appPort"
    Write-Step "To view logs: docker compose logs -f app"
    Write-Step "To stop it: docker compose down"
}
finally {
    Pop-Location
}
