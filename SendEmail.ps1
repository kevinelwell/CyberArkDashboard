    #####################################################################################################################################
    #####################################################################################################################################
    # IMPORTANT: The machine running this from must have the ability to send email for the email notifications to work correctly.
    #####################################################################################################################################
    #####################################################################################################################################
    
   # Get date/time for notification and logging
    $now = Get-Date -UFormat "%m/%d/%Y - %H:%M:%S"

    # Define variables for email from StationSuspendedTool.ini
    [string]$SMTPServer = $FileContent["Email"]["SMTPServer"]
    [string]$SMTPFrom = $FileContent["Email"]["SMTPFrom"]
    [string]$SMTPTo = $FileContent["Email"]["SMTPTo"]

    # Define the subject of the email
    $messageSubject = "$ENV:COMPUTERNAME CYBERARK PVWA SERVICE STOPPED"

    # Define the body of the message
    $body = "`r`n`r`nTHE CYBERARK PVWA SERVICE STOPPED ON $ENV:COMPUTERNAME AT $now.`r`n`r`r`n`r"
       
    # Send the email message
    # Uncomment the line below to enable emails being sent for unauthorized attempts to execute this utility.
    #send-mailmessage -from "$smtpFrom" -to $smtpTo -subject "$messageSubject" -body "$body" -smtpServer "$smtpserver"
        
    # Display error dialog popup
    $message = "THE CYBERARK PVWA SERVICE STOPPED ON $ENV:COMPUTERNAME. PLEASE CHECK THE CYBERARK SERVICES ON $ENV:COMPUTERNAME NOW. "
    $caption = "CYBERARK PVWA SERVICE STOPPED"
    $buttons = [System.Windows.Forms.MessageBoxButtons]::OK
    $icon = [System.Windows.Forms.MessageBoxIcon]::Warning
    $msgbox2 = [System.Windows.Forms.MessageBox]::Show($message,$caption,$buttons,$icon)
