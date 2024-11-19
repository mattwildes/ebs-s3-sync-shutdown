 # Ensure we're running with administrator privileges
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))  
{  
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
    Break
}

# Install the Group Policy Management feature if it's not already installed
if (!(Get-WindowsFeature -Name GPMC).Installed) {
    Install-WindowsFeature -Name GPMC
}

# Define the path for the shutdown script
$scriptPath = "C:\Windows\System32\GroupPolicy\Machine\Scripts\Shutdown"

# Create the directory if it doesn't exist
if (!(Test-Path $scriptPath)) {
    New-Item -Path $scriptPath -ItemType Directory -Force
}

# Define the content of the shutdown script
$shutdownScriptContent = @"
param (
    [Parameter(Mandatory=`$true)]
    [string]`$bucketName,

    [Parameter(Mandatory=`$true)]
    [string]`$localDirectory
)

# Function to check if AWS CLI is installed and install if not
function Ensure-AwsCliInstalled {
    if (!(Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Host "AWS CLI is not installed. Installing now..."
        
        # Download the AWS CLI MSI installer
        `$installerPath = "`$env:TEMP\AWSCLIV2.msi"
        Invoke-WebRequest -Uri "https://awscli.amazonaws.com/AWSCLIV2.msi" -OutFile `$installerPath

        # Install AWS CLI
        Start-Process msiexec.exe -Wait -ArgumentList "/i `$installerPath /qn"

        # Clean up the installer
        Remove-Item `$installerPath

        # Refresh environment variables
        `$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

        if (Get-Command aws -ErrorAction SilentlyContinue) {
            Write-Host "AWS CLI has been successfully installed."
        } else {
            Write-Host "Failed to install AWS CLI. Please install it manually."
            exit 1
        }
    } else {
        Write-Host "AWS CLI is already installed."
    }
}

# Function to check if AWS Tools for PowerShell is installed and install if not
function Ensure-AwsToolsForPowerShellInstalled {
    if (!(Get-Module -ListAvailable -Name AWS.Tools.Common)) {
        Write-Host "AWS Tools for PowerShell is not installed. Installing now..."

        # Install AWS Tools for PowerShell
        Install-Module -Name AWS.Tools.Common -Scope CurrentUser -Force

        if (Get-Module -ListAvailable -Name AWS.Tools.Common) {
            Write-Host "AWS Tools for PowerShell has been successfully installed."
        } else {
            Write-Host "Failed to install AWS Tools for PowerShell. Please install it manually."
            exit 1
        }
    } else {
        Write-Host "AWS Tools for PowerShell is already installed."
    }
}

# Ensure AWS CLI and AWS Tools for PowerShell are installed
Ensure-AwsCliInstalled
# Ensure-AwsToolsForPowerShellInstalled

# Function to create partition structure and sync files
function Sync-ToS3WithPartition {
    param (
        [string]`$sourceFile,
        [string]`$bucketName
    )

    # Get the file's last write time
    `$fileDate = (Get-Item `$sourceFile).LastWriteTime

    # Create the partition key
    `$partitionKey = `$fileDate.ToString("yyyy/MM/dd")

    # Construct the S3 destination path
    `$s3DestinationPath = "s3://`$bucketName/`$partitionKey/"

    # Create the partition structure if it doesn't exist
    `$checkPartitionCmd = "aws s3 ls `$s3DestinationPath"
    `$partitionExists = Invoke-Expression `$checkPartitionCmd

    if (-not `$partitionExists) {
        `$createPartitionCmd = "aws s3api put-object --bucket `$bucketName --key `$(`$partitionKey)/"
        Invoke-Expression `$createPartitionCmd
    }

    # Sync the file to S3
    `$syncCmd = "aws s3 cp ```"`$sourceFile```" ```"`$s3DestinationPath`$(`$sourceFile.Name)```""
    Invoke-Expression `$syncCmd
}

# Validate the local directory exists
if (!(Test-Path -Path `$localDirectory)) {
    Write-Host "Error: The specified local directory does not exist."
    exit 1
}

# Get all files in the local directory
`$files = Get-ChildItem -Path `$localDirectory -File -Recurse

# Sync each file to S3 with the appropriate partition structure
foreach (`$file in `$files) {
    Sync-ToS3WithPartition -sourceFile `$file.FullName -bucketName `$bucketName
}

Write-Host "Sync completed successfully."
"@

# Create the shutdown script
$shutdownScriptContent | Out-File "$scriptPath\ShutdownScript.ps1" -Encoding utf8

# Define the paths for Group Policy scripts configuration
$gptIniPath = "C:\Windows\System32\GroupPolicy\gpt.ini"
$scriptsIniPath = "C:\Windows\System32\GroupPolicy\Machine\Scripts\scripts.ini"

# Update or create gpt.ini
$gptIniContent = @"
[General]
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1
"@
$gptIniContent | Out-File $gptIniPath -Encoding ascii

# Update or create scripts.ini
$scriptsIniContent = @"
[Shutdown]
0CmdLine=powershell.exe
0Parameters=-ExecutionPolicy Bypass -File C:\Windows\System32\GroupPolicy\Machine\Scripts\Shutdown\ShutdownScript.ps1 -bucketName "wildesmj" -localDirectory "C:\Sync"
"@
Set-Content -Path $scriptsIniPath -Value $scriptsIniContent -Encoding Unicode

# Force a Group Policy update
gpupdate /force

Write-Host "Shutdown script has been set up successfully."
Write-Host "The script will run on system shutdown and log to C:\shutdown_log.txt"
 
