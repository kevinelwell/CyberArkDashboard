#Requires -Version 5
#Requires -Modules PSWriteHTML
 
<#
.SYNOPSIS
Script that creates a dashboard with the basic health of the CyberArk environment
 
.DESCRIPTION
This script polls each of the 4 PVWA's, CPM and PSM to check the CyberArk services statuses and backup scheduled tasks and
then compiles the information into a .HTML file. Once the .HTML file is generated, this script will copy the index.html file
to each of the 4 PVWA's C:\inetpub\wwwroot\Health directories
 
.NOTES
Name: Get-CyberArkHealth.ps1
Author: Kevin Elwell <elwell1@gmail.com>
DateCreated: 2020-05-22
ModifiedBy: James Ashley <jashley92@gmail.com>
DateUpdated: 2021-02-2
Site: https://cyberarkweb.local/health
Version: 2.0
 
Credit to Jaap Brasser for his Get-ScheduledTask.ps1 script
Link: https://github.com/jaapbrasser/SharedScripts/tree/master/Get-ScheduledTask
 
Credit to evotec for their PSWriteHTML PowerShell modules
Link: https://github.com/EvotecIT/PSWriteHTML
 
.TODO
Create a .ini/.json file to hold the values of the server names and
have the script dymanically run for each server instead of hard coding the
server names into the script
Add logic to dynamically update maintenance message colors
Rewrite output to a different format?
 
 
#>
 
$fail = $False
 
 
#region Get-ScheduledTask Function
Function Get-ScheduledTask {
 
    <#  
.SYNOPSIS  
Script that returns scheduled tasks on a computer
   
.DESCRIPTION
This script uses the Schedule.Service COM-object to query the local or a remote computer in order to gather a formatted list including the Author, UserId and description of the task. This information is parsed from the XML attributed to provide a more human readable format

.PARAMETER Computername
The computer that will be queried by this script, local administrative permissions are required to query this information
 
.NOTES  
Name: Get-ScheduledTask.ps1
Author: Jaap Brasser
DateCreated: 2012-05-23
DateUpdated: 2015-08-17
Site: http://www.jaapbrasser.com
Version: 1.3.2
 
.LINK
http://www.jaapbrasser.com
 
.EXAMPLE
    .\Get-ScheduledTask.ps1 -ComputerName server01
 
Description
-----------
This command query mycomputer1 and display a formatted list of all scheduled tasks on that computer
 
.EXAMPLE
    .\Get-ScheduledTask.ps1
 
Description
-----------
This command query localhost and display a formatted list of all scheduled tasks on the local computer
 
.EXAMPLE
    .\Get-ScheduledTask.ps1 -ComputerName server01 | Select-Object -Property Name,Trigger
 
Description
-----------
This command query server01 for scheduled tasks and display only the TaskName and the assigned trigger(s)
 
.EXAMPLE
    .\Get-ScheduledTask.ps1 | Where-Object {$_.Name -eq 'TaskName') | Select-Object -ExpandProperty Trigger
 
Description
-----------
This command queries the local system for a scheduled task named 'TaskName' and display the expanded view of the assisgned trigger(s)
 
.EXAMPLE
    Get-Content C:\Servers.txt | ForEach-Object { .\Get-ScheduledTask.ps1 -ComputerName $_ }
 
Description
-----------
Reads the contents of C:\Servers.txt and pipes the output to Get-ScheduledTask.ps1 and outputs the results to the console
 
 
#>
    param(
        [string]$ComputerName = $env:COMPUTERNAME,
        [switch]$RootFolder
    )
 
 
 
    #region Functions
    function Get-AllTaskSubFolders {
        [cmdletbinding()]
        param (
            # Set to use $Schedule as default parameter so it automatically list all files
            # For current schedule object if it exists.
            $FolderRef = $Schedule.getfolder("\")
        )
        if ($FolderRef.Path -eq '\') {
            $FolderRef
        }
        if (-not $RootFolder) {
            $ArrFolders = @()
            if (($Folders = $folderRef.getfolders(1))) {
                $Folders | ForEach-Object {
                    $ArrFolders += $_
                    if ($_.getfolders(1)) {
                        Get-AllTaskSubFolders -FolderRef $_
                    }
                }
            }
            $ArrFolders
        }
    }
 
    function Get-TaskTrigger {
        [cmdletbinding()]
        param (
            $Task
        )
        $Triggers = ([xml]$Task.xml).task.Triggers
        if ($Triggers) {
            $Triggers | Get-Member -MemberType Property | ForEach-Object {
                $Triggers.($_.Name)
            }
        }
    }
    #endregion Functions
 
 
    try {
        $Schedule = New-Object -ComObject 'Schedule.Service'
    }
    catch {
        Write-Warning "Schedule.Service COM Object not found, this script requires this object"
        return
    }
 
    $Schedule.connect($ComputerName)
    $AllFolders = Get-AllTaskSubFolders
 
    foreach ($Folder in $AllFolders) {
        if (($Tasks = $Folder.GetTasks(1))) {
            $Tasks | Foreach-Object {
                New-Object -TypeName PSCustomObject -Property @{
                    'Name'               = $_.name
                    'Path'               = $_.path
                    'State'              = switch ($_.State) {
                        0 { 'Unknown' }
                        1 { 'Disabled' }
                        2 { 'Queued' }
                        3 { 'Ready' }
                        4 { 'Running' }
                        Default { 'Unknown' }
                    }
                    'Enabled'            = $_.enabled
                    'LastRunTime'        = $_.lastruntime
                    'LastTaskResult'     = $_.lasttaskresult
                    'NumberOfMissedRuns' = $_.numberofmissedruns
                    'NextRunTime'        = $_.nextruntime
                    'Author'             = ([xml]$_.xml).Task.RegistrationInfo.Author
                    'UserId'             = ([xml]$_.xml).Task.Principals.Principal.UserID
                    'Description'        = ([xml]$_.xml).Task.RegistrationInfo.Description
                    'Trigger'            = Get-TaskTrigger -Task $_
                    'ComputerName'       = $Schedule.TargetServer
                }
            }
        }
    }
 
 
}
#endregion Get-ScheduledTask Function
 
 
#region Get-CAService Function
# Function for querying a service on a remote machine
Function Get-CAServices {
 
 
    param (
        [parameter(Mandatory = $False)]
        [string]$CAServerName)
 
    $CAserviceshealth = $null
    $CAservices = @(
        "IISAdmin",
        "W3Svc",
        "CyberArk Central Policy Manager Scanner",
        "CyberArk Password Manager",
        "CyberArk Scheduled Tasks",
        "CyberArk Application Password Provider",
        "Cyber-Ark Privileged Session Manager"
    )
       
    try {
        $servicestates = @(Get-WmiObject -ComputerName $CAServerName -Class Win32_Service -ErrorAction STOP | Where-Object { $CAservices -icontains $_.Name } | Select-Object name, state, startmode)
    }
    catch {
        #if ($Log) {Write-LogFile $_.Exception.Message}
        Write-Warning $_.Exception.Message
        $CAserviceshealth = "Fail"
        $fail = $True
    } 
 
    #Return $servicestates.Name, $servicestates.StartMode, $servicestates.State, $servicestates.Status
    Return $servicestates
 
}
#endregion Get-CAService Function
 
#region Get-CAComponentStatus Function
function Get-CAComponentStatus {
    param (
        [parameter(Mandatory = $true)]
        [array]$Servers
    )

    $ServiceStatus = New-Object System.Collections.ArrayList
    $Messages = New-Object System.Collections.ArrayList
    
    $ComponentStatus = $null
    
    $ServerStatus = $null
    $ServerStatusArray = New-Object System.Collections.ArrayList

    foreach ($Machine in $Servers) {

        $s = Get-CAServices -CAServerName $Machine
    
        foreach ($Item in $s) {
            $ServiceObj = [PSCustomObject]@{
                Server      = $Machine
                ServiceName = $Item.Name
                State       = $Item.state
                StartMode   = $Item.StartMode
            }
            [void]($ServiceStatus.Add($ServiceObj))
    
            Remove-Variable ServiceObj -ErrorAction SilentlyContinue
        }
    
        $sm = $s.StartMode
        $st = $s.State
        If ($sm -icontains "Disabled") {
            $mess = "ALL ENABLED SERVICES ARE RUNNING"
            $ServerStatus = "Good"
        }
        If ($sm -inotcontains "Disabled" -and $st -ieq "Running") {
            $mess = "ALL SERVICES ARE RUNNING"
            $ServerStatus = "Good"
        }
        If ($st -icontains "Stopped" -and $sm -inotcontains "Disabled") {
            $mess = "ONE OR MORE SERVICES APPEAR TO BE DOWN!"
            $ServerStatus = "Bad"
        }
        If ($st -icontains "Stopped" -and $sm -inotcontains "Disabled" -and $s.Name -eq "Cyber-Ark Privileged Session Manager") {
            $mess = "All SERVICES ARE RUNNING OR WAITING TO BE STARTED"
            $ServerStatus = "Bad"
        }
        
        $MessageObj = [PSCustomObject]@{
            Server  = $Machine
            Message = $mess
        }
        [void]($ServerStatusArray.Add($ServerStatus))
        [void]($Messages.Add($MessageObj))
    
        Remove-Variable MessageObj -ErrorAction SilentlyContinue
    
    }

    if ($ServerStatusArray -contains 'Bad') {
        $ComponentStatus = 'Bad'
    }
    else {
        $ComponentStatus = 'Good'
    }

    return $ServiceStatus, $Messages, $ComponentStatus

}
#endregion Get-CAComponentStatus Function

# Set Variable to hold the maintenance message
$MaintMessage = "NO SCHEDULED MAINTENANCE AT THIS TIME"
 
 
# ============================================================

$PVWAServers = @('PVWA1','PVWA2')
$PVWAServiceStatus = New-Object System.Collections.ArrayList
$PVWAMessages = New-Object System.Collections.ArrayList
$PVWAComponentStatus = $null

$CCPServers = @('CCP1,CCP2')
$CCPServiceStatus = New-Object System.Collections.ArrayList
$CCPMessages = New-Object System.Collections.ArrayList
$CCPComponentStatus = $null

$CPMServers = @('CPM1')
$CPMServiceStatus = New-Object System.Collections.ArrayList
$CPMMessages = New-Object System.Collections.ArrayList
$CPMComponentStatus = $null

$PSMServers = @('PSM1','PSM2')
$PSMServiceStatus = New-Object System.Collections.ArrayList
$PSMMessages = New-Object System.Collections.ArrayList
$PSMComponentStatus = $null

#PVWA

$PVWAServiceStatus, $PVWAMessages, $PVWAComponentStatus = Get-CAComponentStatus $PVWAServers

#CPM
$CPMServiceStatus, $CPMMessages, $CPMComponentStatus = Get-CAComponentStatus $CPMServers

# Check the scheduled tasks that perform the incremental and full backups
$CASchedTask1 = "CyberArkFullBackup"
$CASchedTask1Upper = $CASchedTask1.TrimStart("CyberArk ").ToUpper()
$CASchedTask2 = "CyberArkIncrementalBackup"
$CASchedTask2Upper = $CASchedTask2.TrimStart("CyberArk ").ToUpper()
$CASchedTask1Result = Get-ScheduledTask | Where-Object { $_.Name -eq $CASchedTask1 } | Select-Object -Property *
$CASchedTask2Result = Get-ScheduledTask | Where-Object { $_.Name -eq $CASchedTask2 } | Select-Object -Property *
#$CASchedTask1Result = Get-ScheduledTask -ComputerName $CPM1 | Where-Object {$_.Name -eq $CASchedTask1} | Select-Object -Property *
#$CASchedTask2Result = Get-ScheduledTask -ComputerName $CPM1 | Where-Object {$_.Name -eq $CASchedTask2} | Select-Object -Property *

$task1Result = $CASchedTask1Result.LastTaskResult
$task1LastRuntime = $CASchedTask1Result.LastRunTime
$task1NextRuntime = $CASchedTask1Result.NextRunTime
$task1Enabled = $CASchedTask1Result.Enabled
 
$task2Result = $CASchedTask2Result.LastTaskResult
$task2LastRuntime = $CASchedTask2Result.LastRunTime
$task2NextRuntime = $CASchedTask2Result.NextRunTime
$task2Enabled = $CASchedTask2Result.Enabled
 
#PSM
$PSMServiceStatus, $PSMMessages, $PSMComponentStatus = Get-CAComponentStatus $PSMServers

#CCP
$CCPServiceStatus, $CCPMessages, $CCPComponentStatus = Get-CAComponentStatus $CCPServers
# ============================================================
 
Import-Module -Name PSWriteHTML -Force
 
New-HTML -AutoRefresh 120 -FavIcon "https://cyberark.local/PasswordVault/v10/favicon.ico" -TitleText "CyberArk Service Status" -Online {
           
    New-HTMLContent -CanCollapse {
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                New-HTMLHeading -Heading h1 -HeadingText 'MAINTENANCE' -Color Black
                   
                New-HTMLToast -TextHeader 'SCHEDULED MAINTENANCE' -Text $MaintMessage -TextColor Black -BarColorLeft Green -BarColorRight Green -IconRegular check-circle -IconColor Green
            }
        }
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                New-HTMLHeading -Heading h1 -HeadingText 'LAST STATUS CHECK' -Color Black
                   
                New-HTMLToast -TextHeader 'DATE / TIME' -Text (Get-Date) -TextColor Black -BarColorLeft Cyan -BarColorRight Cyan -IconRegular clock -IconColor Black
            }
        }
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                New-HTMLHeading -Heading h1 -HeadingText 'BACKUPS STATUS CHECK' -Color Black
                If ($task1Result -eq 0) {
                    $task1ResultColor = "Green"
                    $task1ResultIcon = "thumbs-up"
                }
                else {
                    $task1ResultColor = "Red"
                    $task1ResultIcon = "thumbs-down"
                }
 
                If ($task2Result -eq 0) {
                    $task2ResultColor = "Green"
                    $task2ResultIcon = "thumbs-up"
                }
                else {
                    $task2ResultColor = "Red"
                    $task2ResultIcon = "thumbs-down"
                }
                New-HTMLToast -Text "$CASchedTask1Upper - LAST RUN TIME: $task1LastRuntime" -TextColor Black -BarColorLeft $task1ResultColor -BarColorRight $task1ResultColor -IconSolid $task1ResultIcon -IconColor $task1ResultColor
                New-HTMLToast -Text "$CASchedTask2Upper - LAST RUN TIME: $task2LastRuntime" -TextColor Black -BarColorLeft $task2ResultColor -BarColorRight $task2ResultColor -IconSolid $task2ResultIcon -IconColor $task2ResultColor
            }
        }
    }
 
    #region PVWAHTML
    if ($PVWAComponentStatus -eq 'Good') {
        $PVWAStatusColor = 'Green'
    }
    else {
        $PVWAStatusColor = 'Red'
    }
    New-HTMLContent -CanCollapse -HeaderText "PVWA" -HeaderBackGroundColor $PVWAStatusColor {
        foreach ($Server in $PVWAServers) {
            $Message = ($PVWAMessages | Where-Object { $_.Server -eq $Server }).Message
            $ComponentServiceStatus = $PVWAServiceStatus | Where-Object { $_.Server -eq $Server }

            New-HTMLContainer {
                New-HTMLPanel -Invisible {
                    If (!($fail) -and $Message -ne "ONE OR MORE SERVICES APPEAR TO BE DOWN!") {
                        New-HTMLToast -TextHeader "PVWA STATUS - $Server" -Text $Message -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green
                       
                    }
                    else {
     
                        New-HTMLToast -TextHeader "ERROR - $Server" -Text $Message -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                    }
                   
                }

                New-HTMLPanel -Invisible {
                    New-HTMLStatus {
                        foreach ($Status in $ComponentServiceStatus) {
                            If ($Status.State -ieq "Running") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular check-circle
                            }
                            elseif ($Status.State -ine "Running" -and $Status.startmode -ieq "Disabled") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.StartMode -IconRegular pause-circle -BackgroundColor Yellow
                            }
                            elseif ($Status.State -ne $null) {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular times-circle -BackgroundColor Red
                            }

                        }
                    }
                }
            }
        }
    }
            
    #endregion PVWAHTML
    
    #region CCPHTML
 
    if ($CCPComponentStatus -eq 'Good') {
        $CCPStatusColor = 'Green'
    }
    else {
        $CCPStatusColor = 'Red'
    }
    New-HTMLContent -CanCollapse -HeaderText "CCP" -HeaderBackGroundColor $CCPStatusColor {
        foreach ($Server in $CCPServers) {
            $Message = ($CCPMessages | Where-Object { $_.Server -eq $Server }).Message
            $ComponentServiceStatus = $CCPServiceStatus | Where-Object { $_.Server -eq $Server }

            New-HTMLContainer {
                New-HTMLPanel -Invisible {
                    If (!($fail) -and $Message -ne "ONE OR MORE SERVICES APPEAR TO BE DOWN!") {
                        New-HTMLToast -TextHeader "CCP STATUS - $Server" -Text $Message -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green
                       
                    }
                    else {
     
                        New-HTMLToast -TextHeader "ERROR - $Server" -Text $Message -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                    }
                   
                }

                New-HTMLPanel -Invisible {
                    New-HTMLStatus {
                        foreach ($Status in $ComponentServiceStatus) {
                            If ($Status.State -ieq "Running") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular check-circle
                            }
                            elseif ($Status.State -ine "Running" -and $Status.startmode -ieq "Disabled") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.StartMode -IconRegular pause-circle -BackgroundColor Yellow
                            }
                            elseif ($Status.State -ne $null) {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular times-circle -BackgroundColor Red
                            }

                        }
                    }
                }
            }
        }
    }
    #endregion CCP HTML   

    #region CPM HTML
    if ($CPMComponentStatus -eq 'Good') {
        $CPMStatusColor = 'Green'
    }
    else {
        $CPMStatusColor = 'Red'
    }
    New-HTMLContent -CanCollapse -HeaderText "CPM" -HeaderBackGroundColor $CPMStatusColor {
        foreach ($Server in $CPMServers) {
            $Message = ($CPMMessages | Where-Object { $_.Server -eq $Server }).Message
            $ComponentServiceStatus = $CPMServiceStatus | Where-Object { $_.Server -eq $Server }

            New-HTMLContainer {
                New-HTMLPanel -Invisible {
                    If (!($fail) -and $Message -ne "ONE OR MORE SERVICES APPEAR TO BE DOWN!") {
                        New-HTMLToast -TextHeader "CPM STATUS - $Server" -Text $Message -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green
                       
                    }
                    else {
     
                        New-HTMLToast -TextHeader "ERROR - $Server" -Text $Message -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                    }
                   
                }

                New-HTMLPanel -Invisible {
                    New-HTMLStatus {
                        foreach ($Status in $ComponentServiceStatus) {
                            If ($Status.State -ieq "Running") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular check-circle
                            }
                            elseif ($Status.State -ine "Running" -and $Status.startmode -ieq "Disabled") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.StartMode -IconRegular pause-circle -BackgroundColor Yellow
                            }
                            elseif ($Status.State -ne $null) {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular times-circle -BackgroundColor Red
                            }

                        }
                    }
                }
            }
        }
    }
    #endregion CPM HTML

    #region PSM HTML
    if ($PSMComponentStatus -eq 'Good') {
        $PSMStatusColor = 'Green'
    }
    else {
        $PSMStatusColor = 'Red'
    }
    New-HTMLContent -CanCollapse -HeaderText "PSM" -HeaderBackGroundColor $PSMStatusColor {
        foreach ($Server in $PSMServers) {
            $Message = ($PSMMessages | Where-Object { $_.Server -eq $Server }).Message
            $ComponentServiceStatus = $PSMServiceStatus | Where-Object { $_.Server -eq $Server }

            New-HTMLContainer {
                New-HTMLPanel -Invisible {
                    If (!($fail) -and $Message -ne "ONE OR MORE SERVICES APPEAR TO BE DOWN!") {
                        New-HTMLToast -TextHeader "PSM STATUS - $Server" -Text $Message -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green
                       
                    }
                    else {
     
                        New-HTMLToast -TextHeader "ERROR - $Server" -Text $Message -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                    }
                   
                }

                New-HTMLPanel -Invisible {
                    New-HTMLStatus {
                        foreach ($Status in $ComponentServiceStatus) {
                            If ($Status.State -ieq "Running") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular check-circle
                            }
                            elseif ($Status.State -ine "Running" -and $Status.startmode -ieq "Disabled") {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.StartMode -IconRegular pause-circle -BackgroundColor Yellow
                            }
                            elseif ($Status.State -ne $null) {
                                New-HTMLStatusItem -Name $Status.ServiceName -Status $Status.State -IconRegular times-circle -BackgroundColor Red
                            }

                        }
                    }
                }
            }
        }
    }
    #endregion PSM HTML
} -FilePath "D:\CyberArkAutomation\HealthDashboard\index.html" #-ShowHTML
 
 
#===========================================================

# Add logic here to copy the index.html to each of the PVWA's
# C:\inetpub\wwwroot\Health directories

Foreach ($p in $PVWAServers) {
    write-Host "pvwa name is " $p
 
 
 
    Try {
        $fc = If (!(Test-Path -LiteralPath "\\$p\C$\inetpub\wwwroot\Health")) {
            New-Item -ItemType "directory" -Path "\\$p\C$\inetpub\wwwroot\Health" -Force
        }
 
        $cpresult = Copy-Item -Path "D:\CyberArkAutomation\HealthDashboard\index.html" -Destination "\\$p\C$\inetpub\wwwroot\Health" -Force
        $cpresult
    }
    Catch {
 
        Write-Warning $_.Exception.Message
    }
 
}
 
Remove-Item -Path "D:\CyberArkAutomation\HealthDashboard\index.html"

#===========================================================
 