# CyberArkDashboard

This script polls each of the 4 PVWA's, CPM and PSM to check the CyberArk services statuses and backup scheduled tasks and
then compiles the information into a .HTML file. Once the .HTML file is generated, this script will copy the index.html file 
to each of the 4 PVWA's C:\inetpub\wwwroot\Health directories

<img width="2048" alt="Dashboard" src="https://user-images.githubusercontent.com/16002550/105228870-180d9300-5b31-11eb-9c78-d889bab1e359.png">

Credit to Jaap Brasser for his Get-ScheduledTask.ps1 script
Link: https://github.com/jaapbrasser/SharedScripts/tree/master/Get-ScheduledTask

Credit to evotec for their PSWriteHTML PowerShell modules
Link: https://github.com/EvotecIT/PSWriteHTML
