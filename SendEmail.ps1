    
    #####################################################################################################################################
    #####################################################################################################################################
    # IMPORTANT: The machine running this from must have the ability to send email for the email notifications to work correctly.
    #####################################################################################################################################
    #####################################################################################################################################

    # Get date/time for notification and logging
    $now = Get-Date -UFormat "%m/%d/%Y - %H:%M:%S"

    # Define variables for email from StationSuspendedTool.ini
    [string]$SMTPServer = "YOUR SMTP SERVER"
    [string]$SMTPFrom = "SMTP FROM EMAIL ADDRESS"
    [string]$SMTPTo = "SMTP TO EMAIL ADDRESS"

    # Define the subject of the email
    $messageSubject = "$ENV:COMPUTERNAME CYBERARK PVWA SERVICE STOPPED"

    # Define the body of the message
    $body = "`r`n`r`nTHE CYBERARK PVWA SERVICE STOPPED ON $ENV:COMPUTERNAME AT $now.`r`n`r`r`n`r"
        
    # Send the email message
    send-mailmessage -from "$smtpFrom" -to $smtpTo -subject "$messageSubject" -body "$body" -smtpServer "$smtpserver"
        
    # Display error dialog popup
    $message = "THE CYBERARK PVWA SERVICE STOPPED ON $ENV:COMPUTERNAME. PLEASE CHECK THE CYBERARK SERVICES ON $ENV:COMPUTERNAME NOW. "
    $caption = "CYBERARK PVWA SERVICE STOPPED"

    
