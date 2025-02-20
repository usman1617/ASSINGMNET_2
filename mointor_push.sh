#!/bin/bash
# Load Configuration
if [[ ! -f "config.cfg" ]]; then
    echo "Error: config.cfg not found!"
    exit 1
fi
source config.cfg

# Validate required variables
required_vars=(
    "REPO_PATH"
    "MONITOR_PATH"
    "GIT_REMOTE"
    "GIT_BRANCH"
    "SMTP_SERVER"
    "SMTP_PORT"
    "ZOHO_USER"
    "ZOHO_PASSWORD"
    "COLLABORATORS"
)

for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "Error: $var is not set in config.cfg"
        exit 1
    fi
done

# Variables
LAST_HASH=""
LOCK_FILE="/tmp/file_monitor.lock"

# Cleanup function
cleanup() {
    rm -f "$LOCK_FILE"
    exit 0
}
trap cleanup SIGINT SIGTERM

# Ensure only one instance is running
if [[ -f "$LOCK_FILE" ]]; then
    echo "Error: Script is already running!"
    exit 1
fi
touch "$LOCK_FILE"

# Convert paths to Windows format for Git
REPO_PATH_GIT=$(echo "$REPO_PATH" | sed 's/\//\\/g')
MONITOR_PATH_GIT=$(echo "$MONITOR_PATH" | sed 's/\//\\/g')

# Check if repository exists
if [[ ! -d "${REPO_PATH}/.git" ]]; then
    echo "Error: ${REPO_PATH} is not a Git repository!"
    rm -f "$LOCK_FILE"
    exit 1
fi

# Function to send email notification using PowerShell (Zoho SMTP)
send_email() {
    local email_body="Changes were detected in ${MONITOR_PATH} and have been committed to Git."
    local email_subject="File Monitor: Changes Detected"

    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "
        try {
            \$SMTPServer = '$SMTP_SERVER'
            \$SMTPPort = $SMTP_PORT
            \$Username = '$ZOHO_USER'
            \$Password = ConvertTo-SecureString -String '$ZOHO_PASSWORD' -AsPlainText -Force
            \$Credential = New-Object System.Management.Automation.PSCredential (\$Username, \$Password)
            \$To = '$COLLABORATORS' -split ','
            \$From = '$ZOHO_USER'
            \$Subject = '$email_subject'
            \$Body = '$email_body'

            Send-MailMessage -SmtpServer \$SMTPServer \`
                -Port \$SMTPPort \`
                -UseSsl \`
                -Credential \$Credential \`
                -From \$From \`
                -To \$To \`
                -Subject \$Subject \`
                -Body \$Body

            Write-Output 'Email sent successfully'
        } catch {
            Write-Output \"Error sending email: \$_\"
            exit 1
        }
    "
}

# Check if monitor path exists
if [[ ! -f "${MONITOR_PATH}" ]]; then
    echo "Error: ${MONITOR_PATH} does not exist!"
    rm -f "$LOCK_FILE"
    exit 1
fi

# Monitor file for changes
echo "Starting file monitor for ${MONITOR_PATH}..."
while true; do
    if [[ ! -f "${MONITOR_PATH}" ]]; then
        echo "Error: ${MONITOR_PATH} no longer exists!"
        rm -f "$LOCK_FILE"
        exit 1
    fi
    
    NEW_HASH=$(sha256sum "${MONITOR_PATH}" | awk '{print $1}')
    if [[ "$NEW_HASH" != "$LAST_HASH" ]]; then
        echo "Change detected in ${MONITOR_PATH}..."
        # Stage, commit, and push changes
        if ! cd "${REPO_PATH}"; then
            echo "Error: Unable to change to repository directory!"
            rm -f "$LOCK_FILE"
            exit 1
        fi
        
        # Add the changed file using relative path
        RELATIVE_PATH=$(realpath --relative-to="${REPO_PATH}" "${MONITOR_PATH}")
        
        if git add "${RELATIVE_PATH}" && \
           git add "config.cfg" && \
           git add "monitor_and_push.sh" && \
           git commit -m "Auto-commit: Changes detected in ${MONITOR_PATH}" && \
           git push "${GIT_REMOTE}" "${GIT_BRANCH}"; then
            echo "Changes pushed successfully."
            send_email
        else
            echo "Error: Git operations failed!"
            rm -f "$LOCK_FILE"
            exit 1
        fi
        
        # Update hash
        LAST_HASH="$NEW_HASH"
    fi
    
    # Wait for 5 seconds before checking again
    sleep 5
done
