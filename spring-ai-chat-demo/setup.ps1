$ErrorActionPreference = "Stop"

$model = $env:OLLAMA_MODEL
if ([string]::IsNullOrWhiteSpace($model)) {
    $model = "llama3.2:1b"
}

function Write-Step($message) {
    Write-Host "[setup] $message"
}

function Test-Command($name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        throw "Command '$name' was not found. Install it before continuing."
    }
}

Write-Step "Checking Docker CLI"
Test-Command "docker"
docker version | Out-Null

Write-Step "Checking existing Ollama container"
$containerName = docker ps --filter "name=^/ollama$" --format "{{.Names}}"
if ($containerName -ne "ollama") {
    throw "Container 'ollama' is not running. Start your existing Ollama container before continuing."
}

Write-Step "Checking Ollama volume"
$volumeName = docker volume ls --filter "name=^ollama$" --format "{{.Name}}"
if ($volumeName -ne "ollama") {
    Write-Warning "Docker volume 'ollama' was not found. Continuing because the running container may use another storage configuration."
}

Write-Step "Checking Ollama HTTP endpoint"
$tagsResponse = Invoke-RestMethod -Uri "http://localhost:11434/api/tags" -Method Get

$models = @()
if ($tagsResponse.models) {
    $models = @($tagsResponse.models | ForEach-Object { $_.name })
}

if ($models -contains $model) {
    Write-Step "Model '$model' already exists"
}
else {
    Write-Step "Model '$model' not found. Pulling it into the existing Ollama container"
    docker exec ollama ollama pull $model
}

Write-Step "Setup complete"
