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
Site: https://cyberarkweb.local/health
Version: 1.5.2

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
This script uses the Schedule.Service COM-object to query the local or a remote computer in order to gather	a formatted list including the Author, UserId and description of the task. This information is parsed from the XML attributed to provide a more human readable format
 
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
        if(($Folders = $folderRef.getfolders(1))) {
            $Folders | ForEach-Object {
                $ArrFolders += $_
                if($_.getfolders(1)) {
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
} catch {
	Write-Warning "Schedule.Service COM Object not found, this script requires this object"
	return
}

$Schedule.connect($ComputerName) 
$AllFolders = Get-AllTaskSubFolders

foreach ($Folder in $AllFolders) {
    if (($Tasks = $Folder.GetTasks(1))) {
        $Tasks | Foreach-Object {
	        New-Object -TypeName PSCustomObject -Property @{
	            'Name' = $_.name
                'Path' = $_.path
                'State' = switch ($_.State) {
                    0 {'Unknown'}
                    1 {'Disabled'}
                    2 {'Queued'}
                    3 {'Ready'}
                    4 {'Running'}
                    Default {'Unknown'}
                }
                'Enabled' = $_.enabled
                'LastRunTime' = $_.lastruntime
                'LastTaskResult' = $_.lasttaskresult
                'NumberOfMissedRuns' = $_.numberofmissedruns
                'NextRunTime' = $_.nextruntime
                'Author' =  ([xml]$_.xml).Task.RegistrationInfo.Author
                'UserId' = ([xml]$_.xml).Task.Principals.Principal.UserID
                'Description' = ([xml]$_.xml).Task.RegistrationInfo.Description
                'Trigger' = Get-TaskTrigger -Task $_
                'ComputerName' = $Schedule.TargetServer
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
        [parameter(Mandatory=$False)]
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
        $servicestates = @(Get-WmiObject -ComputerName $CAServerName -Class Win32_Service -ErrorAction STOP | Where-Object {$CAservices -icontains $_.Name} | Select-Object name,state,startmode)
    }
    catch
    {
        #if ($Log) {Write-LogFile $_.Exception.Message}
        Write-Warning $_.Exception.Message
        $CAserviceshealth = "Fail"
        $Fail = $True
    }  

#Return $servicestates.Name, $servicestates.StartMode, $servicestates.State, $servicestates.Status
Return $servicestates

}
#endregion Get-CAService Function


# Set Variable to hold the maintenance message
$MaintMessage = "NO SCHEDULED MAINTENANCE AT THIS TIME"


# ============================================================
# DEFINE THE PVWA'S AND EXECUTE THE GET-CASERVICES FUNCTIONS
# PVWA #1 at the <INSERT LOCATION HERE>
$PVWA1 = "<SET THE FIRST PVWA SERVER NAME HERE>"
$s = Get-CAServices -CAServerName $PVWA1
$sm = $s.StartMode
$st = $s.State
If($sm -icontains "Disabled") {
$mess = "ALL ENABLED SERVICES ARE RUNNING" }

If($st -icontains "Stopped" -and $sm -inotcontains "Disabled") {
$mess = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }

# PVWA #2 at the <INSERT LOCATION HERE>
$PVWA2 = "<SET THE SECOND PVWA SERVER NAME HERE>"
$s1 = Get-CAServices -CAServerName $PVWA2
$sm1 = $s1.StartMode
$st1 = $s1.State
If($sm1 -icontains "Disabled") {
$mess1 = "ALL ENABLED SERVICES ARE RUNNING" }

If($sm1 -inotcontains "Disabled" -and $st1 -ieq "Running") {
$mess1 = "ALL SERVICES ARE RUNNING" }

If($st1 -icontains "Stopped" -and $sm1 -inotcontains "Disabled") {
$mess1 = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }

#$s1[3].Name
#$s1[3].State
#$s1[3].Status
#$s1[3].startmode
#$fail

# PVWA #1 at the <INSERT LOCATION HERE>
$PVWA3 = "<SET THE THIRD PVWA SERVER NAME HERE>"
$s2 = Get-CAServices -CAServerName $PVWA3
$sm2 = $s2.StartMode
$st2 = $s2.State
If($sm2 -icontains "Disabled") {
$mess2 = "ALL ENABLED SERVICES ARE RUNNING" }

If($sm2 -inotcontains "Disabled" -and $st2 -ieq "Running") {
$mess2 = "ALL SERVICES ARE RUNNING" }

If($st2 -icontains "Stopped" -and $sm2 -inotcontains "Disabled") {
$mess2 = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }

#$s2[3].Name
#$s2[3].State
#$s2[3].Status
#$s2[3].startmode
#$fail

# PVWA #2 at the <INSERT LOCATION HERE>
$PVWA4 = "<SET THE FOURTH PVWA SERVER NAME HERE>"
$s3 = Get-CAServices -CAServerName $PVWA4
$sm3 = $s3.StartMode
$st3 = $s3.State
If($sm3 -icontains "Disabled") {
$mess3 = "ALL ENABLED SERVICES ARE RUNNING" }

If($sm3 -inotcontains "Disabled" -and $st3 -ieq "Running") {
$mess3 = "ALL SERVICES ARE RUNNING" }

If($st3 -icontains "Stopped" -and $sm3 -inotcontains "Disabled") {
$mess3 = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }

#$s3[3].Name
#$s3[3].State
#$s3[3].Status
#$s3[3].startmode
#$fail

# CPM #1 at the <INSERT LOCATION HERE>
$CPM1 = "127.0.0.1"
$s4 = Get-CAServices -CAServerName $CPM1
$sm4 = $s4.StartMode
$st4 = $s4.State
If($sm4 -icontains "Disabled") {
$mess4 = "ALL ENABLED SERVICES ARE RUNNING" }

If($sm4 -inotcontains "Disabled" -and $st4 -ieq "Running") {
$mess4 = "ALL SERVICES ARE RUNNING" }

If($st4 -icontains "Stopped" -and $sm4 -inotcontains "Disabled") {
$mess4 = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }

#$s4[3].Name
#$s4[3].State
#$s4[3].Status
#$s4[3].startmode
#$fail

# Check the scheduled tasks that perform the incremental and full backups
$CASchedTask1 = "CyberArk Full Backup"
$CASchedTask1Upper = $CASchedTask1.TrimStart("CyberArk ").ToUpper()
$CASchedTask2 = "CyberArk Incremental Backup"
$CASchedTask2Upper = $CASchedTask2.TrimStart("CyberArk ").ToUpper()
$CASchedTask1Result = Get-ScheduledTask | Where-Object {$_.Name -eq $CASchedTask1} | Select-Object -Property *
$CASchedTask2Result = Get-ScheduledTask | Where-Object {$_.Name -eq $CASchedTask2} | Select-Object -Property *
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


# PSM #1 at the <INSERT LOCATION HERE>
$PSM1 = "<SET THE FIRST PSM SERVER NAME HERE>"
$s5 = Get-CAServices -CAServerName $PSM1
$sm5 = $s5.StartMode
$st5 = $s5.State
If($sm5 -icontains "Disabled") {
$mess5 = "ALL ENABLED SERVICES ARE RUNNING" }

If($sm5 -inotcontains "Disabled" -and $st5 -ieq "Running") {
$mess5 = "ALL SERVICES ARE RUNNING" }

If($st5 -icontains "Stopped" -and $sm5 -inotcontains "Disabled") {
$mess5 = "ONE OR MORE SERVICES APPEAR TO BE DOWN!" }
If($st5 -icontains "Stopped" -and $sm5 -inotcontains "Disabled" -and $s5.Name -eq "Cyber-Ark Privileged Session Manager") {
$mess5 = "All SERVICES ARE RUNNING OR WAITING TO BE STARTED" }
#$s5

#Write-host "0" $sm5[0]#.Name
#Write-host "1" $sm5[1]#.Name
#Write-host "2" $sm5[2]#.Name
#Write-host "3" $sm5[3]#.Name
#Write-host "4" $sm5[4]#.Name
#Write-host "5" $sm5[5]#.Name
#Write-host "6" $sm5[6]#.Name
#$s5[6].Status
#$s5[6].startmode
#$fail

# ============================================================

Import-Module -Name PSWriteHTML -Force

New-HTML -AutoRefresh 120 -FavIcon "https://cyberarkweb.local/PasswordVault/v10/favicon.ico" -TitleText "<INSERT YOUR COMPANY NAME HERE> CYBERARK SERVICE STATUSES" -Online {
            
            New-HTMLContent {
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
                    If($task1Result -eq 0) {
                        $task1ResultColor = "Green"
                        $task1ResultIcon = "thumbs-up"
                    }else{
                        $task1ResultColor = "Red"
                        $task1ResultIcon = "thumbs-down"
                    }

                    If($task2Result -eq 0) {
                        $task2ResultColor = "Green"
                        $task2ResultIcon = "thumbs-up"
                    }else{
                        $task2ResultColor = "Red"
                        $task2ResultIcon = "thumbs-down"
                    }
                    New-HTMLToast -Text "$CASchedTask1Upper - LAST RUN TIME: $task1LastRuntime" -TextColor Black -BarColorLeft $task1ResultColor -BarColorRight $task1ResultColor -IconSolid $task1ResultIcon -IconColor $task1ResultColor
                    New-HTMLToast -Text "$CASchedTask2Upper - LAST RUN TIME: $task2LastRuntime" -TextColor Black -BarColorLeft $task2ResultColor -BarColorRight $task2ResultColor -IconSolid $task2ResultIcon -IconColor $task2ResultColor
                    }
            }
}
    New-HTMLContent  {
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                If(!($fail)) {
                New-HTMLToast -TextHeader 'PVWA STATUS' -Text $mess -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
                
            }

            New-HTMLHeading -Heading h1 -HeadingText '<INSERT PVWA NAME HERE> - PVWA #1 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[0].Name -ServiceStatus $s[0].State -Icon Good -Percentage '100%'
                    }elseif($s[0].State -ine "Running" -and $s[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[0].Name -ServiceStatus $s[0].StartMode -Percentage '0%' -Icon Bad
                    }
                    If($s[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[1].Name -ServiceStatus $s[1].State -Icon Good -Percentage '100%'
                    }elseif($s[1].State -ine "Running" -and $s[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[1].Name -ServiceStatus $s[1].StartMode -Percentage '0%' -Icon Bad
                    }
                    If($s[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[2].Name -ServiceStatus $s[2].State -Icon Good -Percentage '100%'
                    }elseif($s[2].State -ine "Running" -and $s[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[2].Name -ServiceStatus $s[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[3].Name -ServiceStatus $s[3].State -Icon Good -Percentage '100%'
                    }elseif($s[3].State -ine "Running" -and $s[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[3].Name -ServiceStatus $s[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[4].Name -ServiceStatus $s[4].State -Icon Good -Percentage '100%'
                    }elseif($s[4].State -ine "Running" -and $s[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[4].Name -ServiceStatus $s[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s[5].Name -ServiceStatus $s[5].State -Icon Good -Percentage '100%'
                    }elseif($s[5].State -ine "Running" -and $s[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s[5].Name -ServiceStatus $s[5].StartMode -Icon Bad -Percentage '0%'
                    }
                }
            }

        }
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
               If(!($fail)) {
                New-HTMLToast -TextHeader 'PVWA STATUS' -Text $mess1 -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess1 -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
            }
        
            New-HTMLHeading -Heading h1 -HeadingText '<INSERT PVWA NAME HERE> - PVWA #2 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s1[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[0].Name -ServiceStatus $s1[0].State -Icon Good -Percentage '100%'
                    }elseif($s1[0].State -ine "Running" -and $s1[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[0].Name -ServiceStatus $s1[0].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s1[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[1].Name -ServiceStatus $s1[1].State -Icon Good -Percentage '100%'
                    }elseif($s1[1].State -ine "Running" -and $s1[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[1].Name -ServiceStatus $s1[1].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s1[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[2].Name -ServiceStatus $s1[2].State -Icon Good -Percentage '100%'
                    }elseif($s1[2].State -ine "Running" -and $s1[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[2].Name -ServiceStatus $s1[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s1[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[3].Name -ServiceStatus $s1[3].State -Icon Good -Percentage '100%'
                    }elseif($s1[3].State -ine "Running" -and $s1[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[3].Name -ServiceStatus $s1[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s1[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[4].Name -ServiceStatus $s1[4].State -Icon Good -Percentage '100%'
                    }elseif($s1[4].State -ine "Running" -and $s1[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[4].Name -ServiceStatus $s1[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s1[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s1[5].Name -ServiceStatus $s1[5].State -Icon Good -Percentage '100%'
                    }elseif($s1[5].State -ine "Running" -and $s1[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s1[5].Name -ServiceStatus $s1[5].StartMode -Icon Bad -Percentage '0%'
                    }
            }
          }
            
        }
        
    }
        
    New-HTMLContent {
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                If(!($fail)) {
                New-HTMLToast -TextHeader 'PVWA STATUS' -Text $mess2 -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess2 -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
                
            }

            New-HTMLHeading -Heading h1 -HeadingText '<INSERT PVWA NAME HERE> - PVWA #1 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s2[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[0].Name -ServiceStatus $s2[0].State -Icon Good -Percentage '100%'
                    }elseif($s2[0].State -ine "Running" -and $s2[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[0].Name -ServiceStatus $s2[0].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s2[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[1].Name -ServiceStatus $s2[1].State -Icon Good -Percentage '100%'
                    }elseif($s2[1].State -ine "Running" -and $s2[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[1].Name -ServiceStatus $s2[1].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s2[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[2].Name -ServiceStatus $s2[2].State -Icon Good -Percentage '100%'
                    }elseif($s2[2].State -ine "Running" -and $s2[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[2].Name -ServiceStatus $s2[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s2[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[3].Name -ServiceStatus $s2[3].State -Icon Good -Percentage '100%'
                    }elseif($s2[3].State -ine "Running" -and $s2[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[3].Name -ServiceStatus $s2[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s2[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[4].Name -ServiceStatus $s2[4].State -Icon Good -Percentage '100%'
                    }elseif($s2[4].State -ine "Running" -and $s2[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[4].Name -ServiceStatus $s2[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s2[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s2[5].Name -ServiceStatus $s2[5].State -Icon Good -Percentage '100%'
                    }elseif($s2[5].State -ine "Running" -and $s2[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s2[5].Name -ServiceStatus $s2[5].StartMode -Icon Bad -Percentage '0%'
                    }
                }
            }

         } 
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                If(!($fail)) {
                New-HTMLToast -TextHeader 'PVWA STATUS' -Text $mess3 -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess3 -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
                
            }

            New-HTMLHeading -Heading h1 -HeadingText '<INSERT PVWA NAME HERE> - PVWA #2 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s3[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[0].Name -ServiceStatus $s3[0].State -Icon Good -Percentage '100%'
                    }elseif($s3[0].State -ine "Running" -and $s3[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[0].Name -ServiceStatus $s3[0].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s3[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[1].Name -ServiceStatus $s3[1].State -Icon Good -Percentage '100%'
                    }elseif($s3[1].State -ine "Running" -and $s3[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[1].Name -ServiceStatus $s3[1].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s3[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[2].Name -ServiceStatus $s3[2].State -Icon Good -Percentage '100%'
                    }elseif($s3[2].State -ine "Running" -and $s3[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[2].Name -ServiceStatus $s3[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s3[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[3].Name -ServiceStatus $s3[3].State -Icon Good -Percentage '100%'
                    }elseif($s3[3].State -ine "Running" -and $s3[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[3].Name -ServiceStatus $s3[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s3[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[4].Name -ServiceStatus $s3[4].State -Icon Good -Percentage '100%'
                    }elseif($s3[4].State -ine "Running" -and $s3[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[4].Name -ServiceStatus $s3[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s3[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s3[5].Name -ServiceStatus $s3[5].State -Icon Good -Percentage '100%'
                    }elseif($s3[5].State -ine "Running" -and $s3[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s3[5].Name -ServiceStatus $s3[5].StartMode -Icon Bad -Percentage '0%'
                    }
                }
            }


          } 


        }

    New-HTMLContent {
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                If(!($fail)) {
                New-HTMLToast -TextHeader 'CPM STATUS' -Text $mess4 -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess4 -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
                
            }

            New-HTMLHeading -Heading h1 -HeadingText '<INSERT CPM NAME HERE> - CPM #1 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s4[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[0].Name -ServiceStatus $s4[0].State -Icon Good -Percentage '100%'
                    }elseif($s4[0].State -ine "Running" -and $s4[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[0].Name -ServiceStatus $s4[0].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s4[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[1].Name -ServiceStatus $s4[1].State -Icon Good -Percentage '100%'
                    }elseif($s4[1].State -ine "Running" -and $s4[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[1].Name -ServiceStatus $s4[1].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s4[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[2].Name -ServiceStatus $s4[2].State -Icon Good -Percentage '100%'
                    }elseif($s4[2].State -ine "Running" -and $s4[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[2].Name -ServiceStatus $s4[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s4[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[3].Name -ServiceStatus $s4[3].State -Icon Good -Percentage '100%'
                    }elseif($s4[3].State -ine "Running" -and $s4[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[3].Name -ServiceStatus $s4[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s4[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[4].Name -ServiceStatus $s4[4].State -Icon Good -Percentage '100%'
                    }elseif($s4[4].State -ine "Running" -and $s4[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[4].Name -ServiceStatus $s4[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s4[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s4[5].Name -ServiceStatus $s4[5].State -Icon Good -Percentage '100%'
                    }elseif($s4[5].State -ine "Running" -and $s4[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s4[5].Name -ServiceStatus $s4[5].StartMode -Icon Bad -Percentage '0%'
                    }
                }
            }

         } 
        New-HTMLContainer {
            New-HTMLPanel -Invisible {
                If(!($fail)) {
                New-HTMLToast -TextHeader 'PSM STATUS' -Text $mess5 -TextColor Green -BarColorLeft Green -TextHeaderColor Green -BarColorRight Green -IconSolid thumbs-up -IconColor Green

                }else{

                New-HTMLToast -TextHeader 'ERROR' -Text $mess5 -BarColorLeft Red -TextHeaderColor Red -BarColorRight Red -TextColor Red -IconSolid thumbs-down -IconColor Red
                }
                
            }

            New-HTMLHeading -Heading h1 -HeadingText '<INSERT PSM NAME HERE> - PSM #1 ' -Color Black

            New-HTMLPanel -Invisible {
                New-HTMLStatus {
                    If($s5[0].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[0].Name -ServiceStatus $s5[0].State -Icon Good -Percentage '100%'
                    }elseif($s5[0].State -ine "Running" -and $s5[0].startmode -ine "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[0].Name -ServiceStatus $s5[0].State -Icon Good -Percentage '100%'
                    }elseif($s5[0].State -ine "Running" -and $s5[0].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[0].Name -ServiceStatus $s5[0].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[1].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[1].Name -ServiceStatus $s5[1].State -Icon Good -Percentage '100%'
                    }elseif($s5[1].State -ine "Running" -and $s5[1].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[1].Name -ServiceStatus $s5[1].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[2].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[2].Name -ServiceStatus $s5[2].State -Icon Good -Percentage '100%'
                    }elseif($s5[2].State -ine "Running" -and $s5[2].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[2].Name -ServiceStatus $s5[2].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[3].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[3].Name -ServiceStatus $s5[3].State -Icon Good -Percentage '100%'
                    }elseif($s5[3].State -ine "Running" -and $s5[3].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[3].Name -ServiceStatus $s5[3].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[4].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[4].Name -ServiceStatus $s5[4].State -Icon Good -Percentage '100%'
                    }elseif($s5[4].State -ine "Running" -and $s5[4].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[4].Name -ServiceStatus $s5[4].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[5].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[5].Name -ServiceStatus $s5[5].State -Icon Good -Percentage '100%'
                    }elseif($s5[5].State -ine "Running" -and $s5[5].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[5].Name -ServiceStatus $s5[5].StartMode -Icon Bad -Percentage '0%'
                    }
                    If($s5[6].State -ieq "Running") {
                        New-HTMLStatusItem -ServiceName $s5[6].Name -ServiceStatus $s5[6].State -Icon Good -Percentage '100%'
                    }elseif($s5[6].State -ine "Running" -and $s5[6].startmode -ieq "Disabled") {
                        New-HTMLStatusItem -ServiceName $s5[6].Name -ServiceStatus $s5[6].StartMode -Icon Bad -Percentage '0%'
                    }
                }
            }


          } 


        }
} -FilePath "D:\CyberArkAutomation\HealthDashboard\index.html" #-ShowHTML


#===========================================================

# Add logic here to copy the index.html to each of the PVWA's
# C:\inetpub\wwwroot\Health directories
$PVWAS = @(
    "$PVWA1",
    "$PVWA2",
    "$PVWA3",
    "$PVWA4"
           )


Foreach($p in $PVWAS) {
#write-Host "pvwa name is " $p



Try {
    $fc = If(!(Test-Path -LiteralPath "\\$p\C$\inetpub\wwwroot\Health")) {
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





