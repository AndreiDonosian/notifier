#!/bin/bash

# Get the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# Load configuration
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Error: Config file not found at $CONFIG_FILE"
    exit 1
fi

send_email() {
    local subject="$1"
    local body="$2"
    
    # Using curl to send email via SMTP (more reliable/portable than 'mail' command these days)
    # Requires SMTP_SERVER, SMTP_PORT, SMTP_USER, SMTP_PASS from config
    
    curl --url "smtp://$SMTP_SERVER:$SMTP_PORT" \
         --ssl-reqd \
         --mail-from "$SMTP_USER" \
         --mail-rcpt "$EMAIL_TO" \
         --user "$SMTP_USER:$SMTP_PASS" \
         --upload-file - <<EOF
From: $EMAIL_FROM
To: $EMAIL_TO
Subject: $subject

$body
EOF

    if [ $? -eq 0 ]; then
        echo "Alert sent: $subject"
    else
        echo "Failed to send alert: $subject"
    fi
}

check_cpu() {
    local os=$(uname)
    local cpu_usage=0

    if [ "$os" == "Darwin" ]; then
        # macOS CPU usage (user + sys)
        cpu_usage=$(top -l 1 | grep "CPU usage" | awk '{print $3 + $5}' | cut -d. -f1)
    elif command -v mpstat &> /dev/null; then
        # Linux using mpstat
        local cpu_idle=$(mpstat 1 1 | awk '/Average:/ {print $NF}')
        cpu_usage=$(echo "100 - $cpu_idle" | bc | cut -d. -f1)
    elif [ -f /proc/stat ]; then
        # Linux fallback using /proc/stat
        # Read /proc/stat file (first line)
        read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        # Calculate total cpu time 1
        total1=$((user + nice + system + idle + iowait + irq + softirq + steal))
        idle1=$((idle + iowait))
        # Wait a second
        sleep 1
        # Read again
        read cpu user nice system idle iowait irq softirq steal guest < /proc/stat
        total2=$((user + nice + system + idle + iowait + irq + softirq + steal))
        idle2=$((idle + iowait))
        
        # Calculate diffs
        total_diff=$((total2 - total1))
        idle_diff=$((idle2 - idle1))
        
        # Calculate usage percentage
        if [ "$total_diff" -gt 0 ]; then
            cpu_usage=$(( (total_diff - idle_diff) * 100 / total_diff ))
        else
            cpu_usage=0
        fi
    else
        echo "Warning: Could not determine CPU usage."
        return
    fi
     
    # Comparisons
    if [ "${cpu_usage}" -ge "$CPU_ALERT_THRESHOLD" ]; then
        send_email "WARNING: High CPU Usage" "CPU usage is at ${cpu_usage}% (Threshold: ${CPU_ALERT_THRESHOLD}%)"
    fi
}

check_ram() {
    local os=$(uname)
    local ram_usage=0
    
    if [ "$os" == "Darwin" ]; then
        # macOS memory usage is not straightforward (wired + active + compressed)
        # Using a simplified check based on 'memory pressure' or just pass for now as it's complex in bash
        # Alternative: use 'top'
        # Taking 'PhysMem: 10G used' vs total
        local used=$(top -l 1 | grep PhysMem: | awk '{print $2}' | sed 's/M//')
        # This is very rough on macOS, often skipping
        echo "Info: RAM check check on macOS is approximate."
        return 
    elif command -v free &> /dev/null; then
        # Linux
        local total_mem=$(free | grep Mem: | awk '{print $2}')
        local used_mem=$(free | grep Mem: | awk '{print $3}')
        ram_usage=$(( 100 * used_mem / total_mem ))
        
        if [ "$ram_usage" -ge "$RAM_ALERT_THRESHOLD" ]; then
            send_email "WARNING: High RAM Usage" "RAM usage is at ${ram_usage}% (Threshold: ${RAM_ALERT_THRESHOLD}%)"
        fi
    else 
        echo "Skipping RAM check: 'free' command not found."
    fi
}

check_disk() {
    # Check disk usage for specific mount point
    # Use -P for POSIX portability (avoids line wrapping problems)
    if [ -z "$DISK_POINT" ]; then DISK_POINT="/"; fi
    
    local disk_usage=$(df -P "$DISK_POINT" | tail -1 | awk '{print $5}' | sed 's/%//')
    
    if [ "$disk_usage" -ge "$DISK_ALERT_THRESHOLD" ]; then
        send_email "WARNING: Low Disk Space" "Disk usage on $DISK_POINT is at ${disk_usage}% (Threshold: ${DISK_ALERT_THRESHOLD}%)"
    fi
}

check_website() {
    local url="$1"
    local keyword="$2"
    
    # Check HTTP Status
    status_code=$(curl -L -s -o /dev/null -w "%{http_code}" "$url")
    
    if [ "$status_code" != "200" ]; then
        send_email "CRITICAL: Website Down ($url)" "Website returned status code: $status_code"
        return
    fi
    
    # Check Keyword if provided
    if [ -n "$keyword" ]; then
        content=$(curl -L -s "$url")
        if ! echo "$content" | grep -q "$keyword"; then
           send_email "WARNING: Content Missing ($url)" "Keyword '$keyword' not found on page."
        fi
    fi
}

check_ssl() {
    local url="$1"
    # Extract domain from URL
    domain=$(echo "$url" | awk -F/ '{print $3}')
    
    if [ -z "$domain" ]; then return; fi

    # Get expiration date
    expiration_date=$(echo | openssl s_client -servername "$domain" -connect "$domain":443 2>/dev/null | openssl x509 -noout -enddate | cut -d= -f2)
    
    if [ -n "$expiration_date" ]; then
        expiration_epoch=$(date -d "$expiration_date" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiration_date" +%s) # Linux vs Mac date
        current_epoch=$(date +%s)
        days_left=$(( (expiration_epoch - current_epoch) / 86400 ))
        
        if [ "$days_left" -lt "$SSL_WARNING_DAYS" ]; then
            send_email "WARNING: SSL Expiring Soon ($domain)" "SSL certificate for $domain expires in $days_left days."
        fi
    fi
}

# --- Main Execution ---

echo "Starting Server Monitor..."

# System Checks
check_disk
check_ram
check_cpu

# Website Checks
for site in "${WEBSITES[@]}"; do
    # Split by pipe
    url="${site%%|*}"
    keyword="${site##*|}"
    
    # If no keyword implies pipe wasn't there or was at end
    if [ "$url" == "$keyword" ]; then
        keyword=""
    fi
    
    echo "Checking $url..."
    check_website "$url" "$keyword"
    check_ssl "$url"
done

echo "Monitoring complete."
