[CmdletBinding(PositionalBinding=$false)]
Param(
  [string] $configuration = "Debug",
  [string] $solution = "",
  [string] $verbosity = "minimal",
  [switch] $restore,
  [switch] $build,
  [switch] $rebuild,
  [switch] $deploy,
  [switch] $test,
  [switch] $integrationTest,
  [string] $rootsuffix = "",
  [switch] $sign,
  [switch] $pack,
  [switch] $ci,
  [switch] $prepareMachine,
  [switch] $log,
  [switch] $help,
  [Parameter(ValueFromRemainingArguments=$true)][String[]]$properties
)

set-strictmode -version 2.0
$ErrorActionPreference = "Stop"

function Print-Usage() {
    Write-Host "Common settings:"
    Write-Host "  -configuration <value>  Build configuration Debug, Release"
    Write-Host "  -verbosity <value>      Msbuild verbosity (q[uiet], m[inimal], n[ormal], d[etailed], and diag[nostic])"
    Write-Host "  -help                   Print help and exit"
    Write-Host ""

    Write-Host "Actions:"
    Write-Host "  -restore                Restore dependencies"
    Write-Host "  -build                  Build solution"
    Write-Host "  -rebuild                Rebuild solution"
    Write-Host "  -deploy                 Deploy built VSIXes"
    Write-Host "  -test                   Run all unit tests in the solution"
    Write-Host "  -integrationTest        Run all integration tests in the solution"
    Write-Host "  -sign                   Sign build outputs"
    Write-Host "  -pack                   Package build outputs into NuGet packages and Willow components"
    Write-Host ""

    Write-Host "Advanced settings:"
    Write-Host "  -solution <value>       Path to solution to build"
    Write-Host "  -ci                     Set when running on CI server"
    Write-Host "  -log                    Enable logging (by default on CI)"
    Write-Host "  -prepareMachine         Prepare machine for CI run"
    Write-Host ""
    Write-Host "Command line arguments not listed above are passed thru to msbuild."
    Write-Host "The above arguments can be shortened as much as to be unambiguous (e.g. -co for configuration, -t for test, etc.)."
}

if ($help -or (($properties -ne $null) -and ($properties.Contains("/help") -or $properties.Contains("/?")))) {
  Print-Usage
  exit 0
}

function Create-Directory([string[]] $path) {
  if (!(Test-Path $path)) {
    New-Item -path $path -force -itemType "Directory" | Out-Null
  }
}

function GetVersion([string] $name) {
  foreach ($propertyGroup in $VersionsXml.Project.PropertyGroup) {
    if (Get-Member -inputObject $propertyGroup -name $name) {
        return $propertyGroup.$name
    }
  }

  throw "Failed to find $name in Versions.props"
}

function LocateVisualStudio {
  if ($InVSEnvironment) {
    return Join-Path $env:VS150COMNTOOLS "..\.."
  }

  $vswhereVersion = GetVersion("VSWhereVersion")
  $vsWhereDir = Join-Path $ToolsRoot "vswhere\$vswhereVersion"
  $vsWhereExe = Join-Path $vsWhereDir "vswhere.exe"

  if (!(Test-Path $vsWhereExe)) {
    Create-Directory $vsWhereDir
    Write-Host "Downloading vswhere"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "http://github.com/Microsoft/vswhere/releases/download/$vswhereVersion/vswhere.exe" -OutFile $vswhereExe
  }

  $vsInstallDir = & $vsWhereExe -latest -prerelease -property installationPath -requires Microsoft.Component.MSBuild -requires Microsoft.VisualStudio.Component.VSSDK -requires Microsoft.Net.Component.4.6.TargetingPack -requires Microsoft.VisualStudio.Component.Roslyn.Compiler -requires Microsoft.VisualStudio.Component.VSSDK

  if (!(Test-Path $vsInstallDir)) {
    throw "Failed to locate Visual Studio (exit code '$lastExitCode')."
  }

  return $vsInstallDir
}

function InstallToolset {
  if (!(Test-Path $ToolsetBuildProj)) {
    & $MsbuildExe $ToolsetRestoreProj /t:restore /m /nologo /clp:None /warnaserror /v:quiet /p:NuGetPackageRoot=$NuGetPackageRoot /p:BaseIntermediateOutputPath=$ToolsetDir /p:ExcludeRestorePackageImports=true
  }
}

function Build {
  if ($ci -or $log) {
    Create-Directory($logDir)
    $logCmd = "/bl:" + (Join-Path $LogDir "Build.binlog")
  } else {
    $logCmd = ""
  }

  $nodeReuse = !$ci
  $useCodecov = $ci -and $env:CODECOV_TOKEN -and ($configuration -eq 'Debug') -and ($env:ghprbPullAuthorLogin -ne 'dotnet-bot')
  $useOpenCover = $useCodecov

  & $MsbuildExe $ToolsetBuildProj /m /nologo /clp:Summary /nodeReuse:$nodeReuse /warnaserror /v:$verbosity $logCmd /p:Configuration=$configuration /p:SolutionPath=$solution /p:Restore=$restore /p:QuietRestore=true /p:Build=$build /p:Rebuild=$rebuild /p:Deploy=$deploy /p:Test=$test /p:IntegrationTest="false" /p:Sign=$sign /p:Pack=$pack /p:UseCodecov=$useCodecov /p:UseOpenCover=$useOpenCover /p:CIBuild=$ci /p:NuGetPackageRoot=$NuGetPackageRoot $properties
  if ((-not $?) -or ($lastExitCode -ne 0)) {
    throw "Aborting after build failure."
  }

  if ($useCodecov) {
    $CodecovProj = Join-Path $PSScriptRoot 'Codecov.proj'
    & $MsbuildExe $CodecovProj /m /nologo /clp:Summary /nodeReuse:$nodeReuse /warnaserror /v:diag /t:Codecov /p:Configuration=$configuration /p:UseCodecov=$useCodecov /p:NuGetPackageRoot=$NuGetPackageRoot $properties
  }
}

function Stop-Processes() {
  Write-Host "Killing running build processes..."
  Get-Process -Name "msbuild" -ErrorAction SilentlyContinue | Stop-Process
  Get-Process -Name "vbcscompiler" -ErrorAction SilentlyContinue | Stop-Process
}

function Clear-NuGetCache() {
  # clean nuget packages -- necessary to avoid mismatching versions of swix microbuild build plugin and VSSDK on Jenkins
  $nugetRoot = (Join-Path $env:USERPROFILE ".nuget\packages")
  if (Test-Path $nugetRoot) {
    Remove-Item $nugetRoot -Recurse -Force
  }
}

function GenerateDependentAssemblyVersionFile() {
  $vsAssemblyName = "Microsoft.VisualStudio.Editors"
  $visualStudioVersion = GetVersion("VisualStudioVersion")
  $projectSystemAssemblyName = "Microsoft.VisualStudio.ProjectSystem.Managed"
  $projectSystemVersion = GetVersion("ProjectSystemVersion")
  $devDivInsertionFiles = Join-Path (Join-Path $ArtifactsDir $configuration) "DevDivInsertionFiles"
  $dependentAssemblyVersionsCsv = Join-Path $devDivInsertionFiles "DependentAssemblyVersions.csv"
  $csv =@"
$vsAssemblyName, $visualStudioVersion.0
$projectSystemAssemblyName, $projectSystemVersion.0
"@
  & mkdir $devDivInsertionFiles
  $csv >> $dependentAssemblyVersionsCsv
}

function RunIntegrationTests{
  
  # Ensure project system is installed to the correct hive
  Write-Host "Installing project system into '$vsInstallDir'"
  $vsixExpInstallerVersion = GetVersion("VSIXExpInstallerVersion")
  $vsixExpInstalleDir = Join-Path $ToolsRoot "VSIXExpInstaller\$vsixExpInstallerVersion"
  
  $vsixExpInstalleExe = Join-Path $vsixExpInstalleDir "tools\VSIXExpInstaller.exe"

  if (!(Test-Path $vsixExpInstalleExe)) {
    Create-Directory $vsixExpInstalleDir
    Write-Host "Downloading VSIXExpInstaller"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://dotnet.myget.org/F/roslyn-tools/api/v2/package/RoslynTools.VSIXExpInstaller/$vsixExpInstallerVersion" -OutFile RoslynTools.VSIXExpInstaller.zip
    Expand-Archive .\RoslynTools.VSIXExpInstaller.zip -DestinationPath $vsixExpInstalleDir
  }
  $ProjectSystemVsix = Join-Path (Join-Path $ArtifactsDir $configuration) "VSSetup\ProjectSystem.vsix"
  $VisualStudioEditorsSetupVsix = Join-Path (Join-Path $ArtifactsDir $configuration) "VSSetup\VisualStudioEditorsSetup.vsix"
  & $vsixExpInstalleExe /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $ProjectSystemVsix
  & $vsixExpInstalleExe /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $VisualStudioEditorsSetupVsix
  
  # Ensure rules files can be found by msbuild
  $VisualStudioXamlRulesDir = Join-Path (Join-Path $ArtifactsDir $configuration) "VSSetup\Rules"
  $env:VisualBasicDesignTimeTargetsPath = Join-Path $VisualStudioXamlRulesDir "Microsoft.VisualBasic.DesignTime.targets"
  $env:FSharpDesignTimeTargetsPath = Join-Path $VisualStudioXamlRulesDir "Microsoft.FSharp.DesignTime.targets"
  $env:CSharpDesignTimeTargetsPath = Join-Path $VisualStudioXamlRulesDir "Microsoft.CSharp.DesignTime.targets"
  $DevEnvExe = Join-Path $vsInstallDir "Common7\IDE\devenv.exe"
  & $VSTestExe /setup
  
  # Run integration tests
  $VSTestExe = Join-Path $vsInstallDir "Common7\IDE\CommonExtensions\Microsoft\TestWindow\vstest.console.exe"
  $IntegrationTestTempDir = Join-Path (Join-Path $ArtifactsDir $configuration) "IntegrationTestTemp"
  $LogFileArgs = "trx;LogFileName=Microsoft.VisualStudio.ProjectSystem.IntegrationTests.trx"
  $TestAssembly = Join-Path (Join-Path $ArtifactsDir $configuration) "bin\IntegrationTests\Microsoft.VisualStudio.ProjectSystem.IntegrationTests.dll"
  
  Write-Host "Using $VSTestExe"
  & $VSTestExe /blame /logger:$LogFileArgs /ResultsDirectory:"$IntegrationTestTempDir" $TestAssembly
  
  # Kill any VS processes left over
  Get-Process -Name "devenv" -ErrorAction SilentlyContinue | Stop-Process
  
  # Convert trx to be an xUnit xml file
  Write-Host "Converting MSTest results"
  $trxUnitVersion = GetVersion("TRXUnitVersion")
  $trxUnitDir = Join-Path $ToolsRoot "TRXUnit\$trxUnitVersion"
  
  $trxUnitExe = Join-Path $trxUnitDir "tools\TRXunit.exe"
  if (!(Test-Path $trxUnitExe)) {
    Create-Directory $trxUnitDir
    Write-Host "Downloading TRXUnit"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://dotnet.myget.org/F/roslyn-tools/api/v2/package/TRXunit/$trxUnitVersion" -OutFile TRXUnit.zip
    Expand-Archive .\TRXUnit.zip -DestinationPath $trxUnitDir
  }
  
  $trxFiles = Get-ChildItem -Path $IntegrationTestTempDir -Recurse -Include *.trx 
  foreach ($trxFile in $trxFiles) {
    & $trxUnitExe $trxFile
  }
  
  
  # Move test results to test results folder
  $TestResultsDir = Join-Path (Join-Path $ArtifactsDir $configuration) "TestResults"
  Copy-Item -Filter *.xml -Path $IntegrationTestTempDir -Recurse -Destination $TestResultsDir
  
  # Uninstall extensions as other test runs could happen on the VM
  # NOTE: it sometimes takes 2 tries for it to succeed
  Write-Host "Uninstalling project system from '$VSTestExe'"
  & $vsixExpInstalleExe /u /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $ProjectSystemVsix
  & $vsixExpInstalleExe /u /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $ProjectSystemVsix
  & $vsixExpInstalleExe /u /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $VisualStudioEditorsSetupVsix
  & $vsixExpInstalleExe /u /rootSuffix:$rootsuffix /vsInstallDir:$vsInstallDir $VisualStudioEditorsSetupVsix
}

try {
  $InVSEnvironment = !($env:VS150COMNTOOLS -eq $null) -and (Test-Path $env:VS150COMNTOOLS)
  $RepoRoot = Join-Path $PSScriptRoot "..\"
  $ToolsRoot = Join-Path $RepoRoot ".tools"
  $ToolsetRestoreProj = Join-Path $PSScriptRoot "Toolset.proj"
  $ArtifactsDir = Join-Path $RepoRoot "artifacts"
  $ToolsetDir = Join-Path $ArtifactsDir "toolset"
  $LogDir = Join-Path (Join-Path $ArtifactsDir $configuration) "log"
  $TempDir = Join-Path (Join-Path $ArtifactsDir $configuration) "tmp"
  [xml]$VersionsXml = Get-Content(Join-Path $PSScriptRoot "Versions.props")

  if ($solution -eq "") {
    $solution = @(gci(Join-Path $RepoRoot "*.sln"))[0]
  }

  if ($env:NUGET_PACKAGES -ne $null) {
    $NuGetPackageRoot = $env:NUGET_PACKAGES.TrimEnd("\") + "\"
  } else {
    $NuGetPackageRoot = Join-Path $env:UserProfile ".nuget\packages\"
  }

  $ToolsetVersion = GetVersion("RoslynToolsRepoToolsetVersion")
  $ToolsetBuildProj = Join-Path $NuGetPackageRoot "RoslynTools.RepoToolset\$ToolsetVersion\tools\Build.proj"

  $vsInstallDir = LocateVisualStudio
  $MsbuildExe = Join-Path $vsInstallDir "MSBuild\15.0\Bin\msbuild.exe"

  if ($ci) {
    Create-Directory $TempDir
    $env:TEMP = $TempDir
    $env:TMP = $TempDir

    Write-Host "Using $MsbuildExe"
  }

  if (!$InVSEnvironment) {
    $env:VS150COMNTOOLS = Join-Path $vsInstallDir "Common7\Tools\"
    $env:VSSDK150Install = Join-Path $vsInstallDir "VSSDK\"
    $env:VSSDKInstall = Join-Path $vsInstallDir "VSSDK\"
  }

  # Preparation of a CI machine
  if ($prepareMachine) {
    Clear-NuGetCache
  }

  if ($restore) {
    InstallToolset
  }

  Build
  
  if ($pack) {
    GenerateDependentAssemblyVersionFile
  }
  
  if($integrationTest){
    RunIntegrationTests
  }
  
  exit $lastExitCode
}
catch {
  Write-Host $_
  Write-Host $_.Exception
  Write-Host $_.ScriptStackTrace
  exit 1
}
finally {
  Pop-Location
  if ($ci -and $prepareMachine) {
    Stop-Processes
  }
}
