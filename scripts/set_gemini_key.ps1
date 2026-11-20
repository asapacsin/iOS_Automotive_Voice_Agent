# Asks for the Gemini API key with hidden input and saves it to %USERPROFILE%/.novadrive/eval.env (outside the repo). Never prints the key.
$s = Read-Host -AsSecureString "Paste GEMINI_API_KEY and press Enter (input hidden)"
$k = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)).Trim()
if (-not $k) { Write-Host "Nothing entered; not saved."; exit 1 }
$d = Join-Path $env:USERPROFILE ".novadrive"; New-Item -ItemType Directory -Force $d | Out-Null; $f = Join-Path $d "eval.env"
"# Local keys for PC evals. Outside the repo.`nGEMINI_API_KEY=$k" | Set-Content -Encoding utf8 $f
[Environment]::SetEnvironmentVariable("GEMINI_API_KEY", $k, "User")
Write-Host "Saved ($($k.Length) characters) to %USERPROFILE%/.novadrive/eval.env and the user environment."
