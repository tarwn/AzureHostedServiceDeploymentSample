param(
    [string] $publishSettingsPath,
    [string] $subscriptionName,
    [string] $storageAccountName,
    [string] $packagePath,
    [string] $configPath,
    [string] $containerName,
    [string] $targetPackageName,
    [string] $serviceName
)

#$fullTargetName = "$($targetPackageName)_$(get-date -f yyyyMMdd_hhmmss)"
$fullTargetName = "build_20140524_105402"
$fullTargetDeploymentName = "build-$(get-date -f "yyyyMMdd-hhmmss")"
$fullTargetPackageName = "$($fullTargetName).cspkg"

$instancePollRate = 3
$instancePollLimit = 900

$statusReady = "ReadyRole"
$statusStopped = "StoppedVM"

function Get-AllInstancesAreStatus($instances, $targetStatus){
    foreach ($instance in $instances)
    {
        if ($instance.InstanceStatus -ne $targetStatus)
        {
            return $false
        }
    }
    return $true
}

function Get-AllInstancesAreStatusCount($instances, $targetStatus){
    $count = 0
    foreach ($instance in $instances)
    {
        if ($instance.InstanceStatus -eq $targetStatus)
        {
            $count++
        }
    }
    return $count
}

function Get-AllInstanceStatusesAsString($instances){
    $stringBuilder = New-Object System.Text.StringBuilder
    [void]$stringBuilder.Append("$($instances.Count) instances: ")
    foreach ($instance in $instances)
    {
        [void]$stringBuilder.Append("[$($instance.InstanceName) $($instance.InstanceStatus)] ");
    }
    return $stringBuilder.ToString()
}

try{
    $ErrorActionPreference = "Stop";

    Write-Host "Preparing to deploy package"

        Import-Module "C:\Program Files (x86)\Microsoft SDKs\Windows Azure\PowerShell\ServiceManagement\Azure\Azure.psd1"

        # Use publish settings to set subscription
        Import-AzurePublishSettingsFile $publishSettingsPath
 
        Set-AzureSubscription $subscriptionName -CurrentStorageAccount $storageAccountName
 
        Select-AzureSubscription $subscriptionName

        # Upload package
#        Write-Host "- Uploading package to $fullTargetPackageName"
#
#        $container = Get-AzureStorageContainer -Name $containerName -ErrorAction SilentlyContinue
#        if(!$container){
#            Write-Host "- $containerName storage container does not exist, creating it"
#            New-AzureStorageContainer -Name $containerName
#        }
#
#        Set-AzureStorageBlobContent -File $packagePath -Container $containerName -Blob $fullTargetPackageName -Force
        $blobInfo = Get-AzureStorageBlob  -Container $containerName -blob $fullTargetPackageName
        $packageUri = $blobInfo.ICloudBlob.Uri

        Write-Host "- Package is ready to deploy: $packageUri"

    Write-Host "Deploying package to staging slot of hosted service"
        
        #Create deployment
        $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot Staging -ErrorAction SilentlyContinue 
        if($deployment.name -eq $null){
            Write-Host "- No deployment currently in Staging slot, ready to continue"
        }
        else{
            Write-Host "- Removing current Staging Deployment: name='$($deployment.Name)', status='$($deployment.Status)', id='$($deployment.DeploymentId)'"
            Remove-AzureDeployment -ServiceName $serviceName -Slot Staging -Force
        }

        Write-Host "- Starting deployment to staging slot with name '$fullTargetDeploymentName'"

        New-AzureDeployment -ServiceName $serviceName -Slot Staging -Package $packageUri -Configuration $configPath -Name $fullTargetDeploymentName -TreatWarningsAsError
        $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot Staging

        Write-Host "- Package deployed to staging slot: name='$($deployment.Name)', status='$($deployment.Status)', id='$($deployment.DeploymentId)'"
        
        # Wait for instances to be ready
        Write-Host "- Waiting for all instances to be ready"

        $waitTime = [System.Diagnostics.Stopwatch]::StartNew()
        $lastRunningCount = 0;
        while ((Get-AllInstancesAreStatus $deployment.RoleInstanceList $statusReady) -eq $false)
        {
            $allStatuses = Get-AllInstanceStatusesAsString $deployment.RoleInstanceList
            $runningCount = Get-AllInstancesAreStatusCount $deployment.RoleInstanceList $statusReady
            Write-Progress -Activity "$runningCount of $($deployment.RoleInstanceList.Count) instances ready" -Status $allStatuses -PercentComplete ($runningCount/$deployment.RoleInstanceList.Count)

            if($lastRunningCount -ne $runningCount){
                Write-Host "- $runningCount of $($deployment.RoleInstanceList.Count) instances ready"
            }

            if($waitTime.Elapsed.TotalSeconds -gt $instancePollLimit){
                Throw "$instancePollLimit seconds elapsed without all the instances reaching 'ReadyRun' - statuses: $allStatuses"
            }

            Start-Sleep -Seconds $instancePollRate

            $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot Staging
        }
        Write-Progress -Activity "Starting instances" -Completed
        Write-Host "- All instances are ready - $([Math]::floor($waitTime.Elapsed.TotalMinutes))m $($waitTime.Elapsed.Seconds)s elapsed"

        # Swap + shutdown old deployment
        Write-Host "- VIP Swap starting"

        Move-AzureDeployment -ServiceName $serviceName
        $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot Production

        Write-Host "- VIP Swap complete, new package deployed to production slot: $($deployment.DeploymentName) is in production"

        $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot Staging -ErrorAction SilentlyContinue
        if($deployment.DeploymentName -ne $null){
            Write-Host "- Stopping older deployment (staging slot): $($deployment.DeploymentName)"

            Set-AzureDeployment -Status -ServiceName $serviceName -Slot Staging -NewStatus Suspended
        }
        else{
            Write-Host "- No older deployment present, no need to stop staging"
        }

        Write-Host "- Done"
        Exit 0
}
catch [System.Exception]{
    Write-Host $_.Exception.ToString()
    exit 1
}