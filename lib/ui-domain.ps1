function Test-QuotaUiDomainRequired {
    return ($PSVersionTable.PSEdition -eq 'Desktop' -and [AppDomain]::CurrentDomain.FriendlyName -ne 'CodexQuotaUi')
}

function Invoke-QuotaUiDomain([string]$ScriptPath,[System.Collections.IDictionary]$Parameters) {
    $root=Split-Path $ScriptPath -Parent
    $source=Join-Path $PSScriptRoot 'ui-domain.cs'
    $config=Join-Path $PSScriptRoot 'ui-domain.config'
    $hash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.Substring(0,16)
    $bin=Join-Path $root 'state\bin';$null=New-Item -ItemType Directory -Path $bin -Force
    $assembly=Join-Path $bin ('QuotaUiDomain-'+$hash+'.dll')
    if(-not(Test-Path -LiteralPath $assembly)){
        $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
        if(-not(Test-Path -LiteralPath $compiler)){$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
        $buildOutput=& $compiler /nologo /target:library ('/out:'+$assembly) ('/reference:'+([Management.Automation.PowerShell].Assembly.Location)) $source
        if($LASTEXITCODE -ne 0){throw ('Unable to build the private DPI configuration host: '+($buildOutput -join "`n"))}
    }
    $setup=New-Object AppDomainSetup
    $setup.ApplicationBase=$PSHOME
    $setup.ConfigurationFile=$config
    $setup.TargetFrameworkName='.NETFramework,Version=v4.8'
    $null=[Reflection.Assembly]::LoadFrom($assembly)
    $domain=[AppDomain]::CreateDomain('CodexQuotaUi',$null,$setup)
    try{
        $ui=$domain.CreateInstanceFromAndUnwrap($assembly,'QuotaUiDomain')
        $arguments=@{}
        foreach($key in $Parameters.Keys){$value=$Parameters[$key];if($value -is [Management.Automation.SwitchParameter]){$value=[bool]$value};$arguments[$key]=$value}
        return $ui.Run($ScriptPath,[Management.Automation.PSSerializer]::Serialize($arguments))
    }finally{[AppDomain]::Unload($domain)}
}
