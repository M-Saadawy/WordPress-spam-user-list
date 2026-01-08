#!/bin/bash
# =====================================
# WP Unusual Email Finder Script (Script 3)
# Purpose: Find users with uncommon email providers
# Features: 
# - Uses GitHub whitelist as "common providers"
# - Lists all unusual email domains
# - Export to CSV, TXT, and JSON
# - Statistics and analysis
# =====================================

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

BASE_DIR="/var/www/domains"
LOG_DIR="$HOME/wp-cleanup-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Output files
UNUSUAL_EMAILS_TXT="$LOG_DIR/unusual_emails_$TIMESTAMP.txt"
UNUSUAL_EMAILS_CSV="$LOG_DIR/unusual_emails_$TIMESTAMP.csv"
UNUSUAL_EMAILS_JSON="$LOG_DIR/unusual_emails_$TIMESTAMP.json"
DOMAIN_STATS_TXT="$LOG_DIR/domain_statistics_$TIMESTAMP.txt"

# Arrays for tracking
declare -A DOMAIN_COUNT
declare -A DOMAIN_USERS
declare -A COMMON_PROVIDERS

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress Unusual Email Finder =======
${NC}"
echo -e "${CYAN}==== Find Uncommon Email Providers ========${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# =====================================
# FETCH COMMON PROVIDERS (WHITELIST) FROM GITHUB
# =====================================
echo -e "${BLUE}Fetching list of common email providers from GitHub...${NC}"
WHITELIST_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/whitelist.txt"
TEMP_WHITELIST=$(mktemp)

COMMON_PROVIDER_LIST=()

if curl -s -f "$WHITELIST_URL" -o "$TEMP_WHITELIST" 2>/dev/null && [ -s "$TEMP_WHITELIST" ]; then
    echo -e "${GREEN}✓ Successfully downloaded common providers list from GitHub${NC}"
    
    # Load common providers from file
    while IFS= read -r line; do
        # Trim whitespace
        line=$(echo "$line" | xargs)
        # Skip empty lines and comments
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            # Remove @ if present
            line="${line#@}"
            COMMON_PROVIDER_LIST+=("$line")
            COMMON_PROVIDERS["$line"]=1
        fi
    done < "$TEMP_WHITELIST"
    
    echo -e "${GREEN}  Loaded ${#COMMON_PROVIDER_LIST[@]} common email providers${NC}"
    if [ ${#COMMON_PROVIDER_LIST[@]} -gt 3 ]; then
        echo -e "${GRAY}  Sample: ${COMMON_PROVIDER_LIST[0]}, ${COMMON_PROVIDER_LIST[1]}, ${COMMON_PROVIDER_LIST[2]}...${NC}"
    fi
else
    echo -e "${RED}✗ ERROR: Could not fetch common providers list from GitHub${NC}"
    echo -e "${RED}  URL: $WHITELIST_URL${NC}"
    echo -e "${RED}  This list is required for operation. Exiting.${NC}"
    rm -f "$TEMP_WHITELIST"
    exit 1
fi
rm -f "$TEMP_WHITELIST"

# Verify we have providers loaded
if [ ${#COMMON_PROVIDER_LIST[@]} -eq 0 ]; then
    echo -e "${RED}✗ ERROR: Common providers list is empty. Cannot proceed. Exiting.${NC}"
    exit 1
fi

# Function to check if domain is a common provider
is_common_provider() {
    local domain="$1"
    # Remove @ if present
    domain="${domain#@}"
    
    if [[ -n "${COMMON_PROVIDERS[$domain]}" ]]; then
        return 0  # Is common provider
    fi
    return 1  # Not common provider (unusual)
}

# =====================================
# SCAN ALL WORDPRESS SITES
# =====================================
echo
echo -e "${BLUE}Scanning all WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}This may take a moment...${NC}"
echo

TOTAL_USERS=0
TOTAL_UNUSUAL_USERS=0
TOTAL_COMMON_USERS=0
TOTAL_SITES=0

for SITE_PATH in $BASE_DIR/*/public_html; do
    if [ -f "$SITE_PATH/wp-config.php" ]; then
        SITE_NAME=$(basename $(dirname $(dirname "$SITE_PATH")))
        echo -e "${MAGENTA}Scanning: ${CYAN}$SITE_NAME${NC}"

        # Extract database credentials from wp-config.php
        DB_NAME=$(grep "DB_NAME" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_USER=$(grep "DB_USER" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_PASS=$(grep "DB_PASSWORD" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_HOST=$(grep "DB_HOST" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        PREFIX=$(grep "\$table_prefix" "$SITE_PATH/wp-config.php" | cut -d"'" -f2)

        if [ -z "$PREFIX" ]; then
            PREFIX="wp_"
        fi

        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
            echo -e "${RED}  Error: Could not extract database credentials${NC}"
            continue
        fi

        # Get all users with their emails
        USER_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT ID, user_login, user_email, user_registered 
        FROM ${PREFIX}users
        ORDER BY user_registered DESC;
        " 2>/dev/null)

        if [ -z "$USER_DATA" ]; then
            echo -e "${GRAY}  No users found${NC}"
            continue
        fi

        SITE_USERS=0
        SITE_UNUSUAL=0
        
        while IFS=$'\t' read -r USER_ID USER_LOGIN USER_EMAIL USER_REGISTERED; do
            TOTAL_USERS=$((TOTAL_USERS + 1))
            SITE_USERS=$((SITE_USERS + 1))
            
            # Extract domain from email
            DOMAIN=$(echo "$USER_EMAIL" | grep -oP '@\K.*')
            
            if [ -n "$DOMAIN" ]; then
                # Check if it's a common provider
                if ! is_common_provider "$DOMAIN"; then
                    # Unusual email found
                    TOTAL_UNUSUAL_USERS=$((TOTAL_UNUSUAL_USERS + 1))
                    SITE_UNUSUAL=$((SITE_UNUSUAL + 1))
                    
                    # Track domain count
                    if [[ -n "${DOMAIN_COUNT[$DOMAIN]}" ]]; then
                        DOMAIN_COUNT[$DOMAIN]=$((${DOMAIN_COUNT[$DOMAIN]} + 1))
                    else
                        DOMAIN_COUNT[$DOMAIN]=1
                    fi
                    
                    # Store user details for this domain
                    USER_DETAILS="$SITE_NAME|$USER_ID|$USER_LOGIN|$USER_EMAIL|$USER_REGISTERED"
                    if [[ -n "${DOMAIN_USERS[$DOMAIN]}" ]]; then
                        DOMAIN_USERS[$DOMAIN]="${DOMAIN_USERS[$DOMAIN]}::$USER_DETAILS"
                    else
                        DOMAIN_USERS[$DOMAIN]="$USER_DETAILS"
                    fi
                else
                    TOTAL_COMMON_USERS=$((TOTAL_COMMON_USERS + 1))
                fi
            fi
        done <<< "$USER_DATA"
        
        echo -e "${GRAY}  Users: $SITE_USERS | Unusual: $SITE_UNUSUAL${NC}"
        TOTAL_SITES=$((TOTAL_SITES + 1))
    fi
done

# =====================================
# GENERATE REPORTS
# =====================================
echo
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Generating Reports ====================${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ ${#DOMAIN_COUNT[@]} -eq 0 ]; then
    echo -e "${GREEN}Great news! No unusual email domains found.${NC}"
    echo -e "${GRAY}All users are using common email providers.${NC}"
    exit 0
fi

# =====================================
# TXT REPORT
# =====================================
echo "WordPress Unusual Email Domains Report" > "$UNUSUAL_EMAILS_TXT"
echo "======================================" >> "$UNUSUAL_EMAILS_TXT"
echo "Generated: $(date)" >> "$UNUSUAL_EMAILS_TXT"
echo "Total Sites Scanned: $TOTAL_SITES" >> "$UNUSUAL_EMAILS_TXT"
echo "Total Users: $TOTAL_USERS" >> "$UNUSUAL_EMAILS_TXT"
echo "Common Provider Users: $TOTAL_COMMON_USERS" >> "$UNUSUAL_EMAILS_TXT"
echo "Unusual Provider Users: $TOTAL_UNUSUAL_USERS" >> "$UNUSUAL_EMAILS_TXT"
echo "Unique Unusual Domains: ${#DOMAIN_COUNT[@]}" >> "$UNUSUAL_EMAILS_TXT"
echo "" >> "$UNUSUAL_EMAILS_TXT"
echo "======================================" >> "$UNUSUAL_EMAILS_TXT"
echo "" >> "$UNUSUAL_EMAILS_TXT"

# Sort domains by count (most common first)
for domain in $(for d in "${!DOMAIN_COUNT[@]}"; do echo "${DOMAIN_COUNT[$d]} $d"; done | sort -rn | cut -d' ' -f2); do
    COUNT=${DOMAIN_COUNT[$domain]}
    echo "Domain: $domain ($COUNT user(s))" >> "$UNUSUAL_EMAILS_TXT"
    echo "----------------------------------------" >> "$UNUSUAL_EMAILS_TXT"
    
    # Get all users for this domain
    IFS='::' read -ra USERS <<< "${DOMAIN_USERS[$domain]}"
    for user_info in "${USERS[@]}"; do
        IFS='|' read -r SITE USER_ID USER_LOGIN USER_EMAIL USER_REGISTERED <<< "$user_info"
        echo "  Site: $SITE" >> "$UNUSUAL_EMAILS_TXT"
        echo "  User ID: $USER_ID" >> "$UNUSUAL_EMAILS_TXT"
        echo "  Login: $USER_LOGIN" >> "$UNUSUAL_EMAILS_TXT"
        echo "  Email: $USER_EMAIL" >> "$UNUSUAL_EMAILS_TXT"
        echo "  Registered: $USER_REGISTERED" >> "$UNUSUAL_EMAILS_TXT"
        echo "" >> "$UNUSUAL_EMAILS_TXT"
    done
    echo "" >> "$UNUSUAL_EMAILS_TXT"
done

# =====================================
# CSV REPORT
# =====================================
echo "domain,user_count,site,user_id,user_login,user_email,user_registered" > "$UNUSUAL_EMAILS_CSV"

for domain in $(for d in "${!DOMAIN_COUNT[@]}"; do echo "${DOMAIN_COUNT[$d]} $d"; done | sort -rn | cut -d' ' -f2); do
    COUNT=${DOMAIN_COUNT[$domain]}
    
    # Get all users for this domain
    IFS='::' read -ra USERS <<< "${DOMAIN_USERS[$domain]}"
    for user_info in "${USERS[@]}"; do
        IFS='|' read -r SITE USER_ID USER_LOGIN USER_EMAIL USER_REGISTERED <<< "$user_info"
        echo "$domain,$COUNT,\"$SITE\",$USER_ID,\"$USER_LOGIN\",\"$USER_EMAIL\",\"$USER_REGISTERED\"" >> "$UNUSUAL_EMAILS_CSV"
    done
done

# =====================================
# JSON REPORT
# =====================================
echo "{" > "$UNUSUAL_EMAILS_JSON"
echo "  \"generated\": \"$(date -Iseconds)\"," >> "$UNUSUAL_EMAILS_JSON"
echo "  \"summary\": {" >> "$UNUSUAL_EMAILS_JSON"
echo "    \"total_sites_scanned\": $TOTAL_SITES," >> "$UNUSUAL_EMAILS_JSON"
echo "    \"total_users\": $TOTAL_USERS," >> "$UNUSUAL_EMAILS_JSON"
echo "    \"common_provider_users\": $TOTAL_COMMON_USERS," >> "$UNUSUAL_EMAILS_JSON"
echo "    \"unusual_provider_users\": $TOTAL_UNUSUAL_USERS," >> "$UNUSUAL_EMAILS_JSON"
echo "    \"unique_unusual_domains\": ${#DOMAIN_COUNT[@]}" >> "$UNUSUAL_EMAILS_JSON"
echo "  }," >> "$UNUSUAL_EMAILS_JSON"
echo "  \"unusual_domains\": [" >> "$UNUSUAL_EMAILS_JSON"

FIRST_DOMAIN=true
for domain in $(for d in "${!DOMAIN_COUNT[@]}"; do echo "${DOMAIN_COUNT[$d]} $d"; done | sort -rn | cut -d' ' -f2); do
    if [ "$FIRST_DOMAIN" = true ]; then
        FIRST_DOMAIN=false
    else
        echo "," >> "$UNUSUAL_EMAILS_JSON"
    fi
    
    COUNT=${DOMAIN_COUNT[$domain]}
    echo "    {" >> "$UNUSUAL_EMAILS_JSON"
    echo "      \"domain\": \"$domain\"," >> "$UNUSUAL_EMAILS_JSON"
    echo "      \"user_count\": $COUNT," >> "$UNUSUAL_EMAILS_JSON"
    echo "      \"users\": [" >> "$UNUSUAL_EMAILS_JSON"
    
    # Get all users for this domain
    IFS='::' read -ra USERS <<< "${DOMAIN_USERS[$domain]}"
    FIRST_USER=true
    for user_info in "${USERS[@]}"; do
        if [ "$FIRST_USER" = true ]; then
            FIRST_USER=false
        else
            echo "," >> "$UNUSUAL_EMAILS_JSON"
        fi
        
        IFS='|' read -r SITE USER_ID USER_LOGIN USER_EMAIL USER_REGISTERED <<< "$user_info"
        echo "        {" >> "$UNUSUAL_EMAILS_JSON"
        echo "          \"site\": \"$SITE\"," >> "$UNUSUAL_EMAILS_JSON"
        echo "          \"user_id\": $USER_ID," >> "$UNUSUAL_EMAILS_JSON"
        echo "          \"user_login\": \"$USER_LOGIN\"," >> "$UNUSUAL_EMAILS_JSON"
        echo "          \"user_email\": \"$USER_EMAIL\"," >> "$UNUSUAL_EMAILS_JSON"
        echo "          \"user_registered\": \"$USER_REGISTERED\"" >> "$UNUSUAL_EMAILS_JSON"
        echo -n "        }" >> "$UNUSUAL_EMAILS_JSON"
    done
    
    echo "" >> "$UNUSUAL_EMAILS_JSON"
    echo "      ]" >> "$UNUSUAL_EMAILS_JSON"
    echo -n "    }" >> "$UNUSUAL_EMAILS_JSON"
done

echo "" >> "$UNUSUAL_EMAILS_JSON"
echo "  ]" >> "$UNUSUAL_EMAILS_JSON"
echo "}" >> "$UNUSUAL_EMAILS_JSON"

# =====================================
# DOMAIN STATISTICS
# =====================================
echo "Domain Statistics (Top Unusual Providers)" > "$DOMAIN_STATS_TXT"
echo "=========================================" >> "$DOMAIN_STATS_TXT"
echo "Generated: $(date)" >> "$DOMAIN_STATS_TXT"
echo "" >> "$DOMAIN_STATS_TXT"
printf "%-5s %-40s %s\n" "Rank" "Domain" "Users" >> "$DOMAIN_STATS_TXT"
echo "-------------------------------------------------------------" >> "$DOMAIN_STATS_TXT"

RANK=1
for domain in $(for d in "${!DOMAIN_COUNT[@]}"; do echo "${DOMAIN_COUNT[$d]} $d"; done | sort -rn | cut -d' ' -f2); do
    COUNT=${DOMAIN_COUNT[$domain]}
    printf "%-5s %-40s %s\n" "$RANK" "$domain" "$COUNT" >> "$DOMAIN_STATS_TXT"
    RANK=$((RANK + 1))
done

# =====================================
# DISPLAY SUMMARY
# =====================================
echo -e "${GREEN}Summary:${NC}"
echo -e "${CYAN}  Total sites scanned: $TOTAL_SITES${NC}"
echo -e "${CYAN}  Total users found: $TOTAL_USERS${NC}"
echo -e "${WHITE}  ├─ Common providers: $TOTAL_COMMON_USERS${NC}"
echo -e "${YELLOW}  └─ Unusual providers: $TOTAL_UNUSUAL_USERS${NC}"
echo -e "${YELLOW}  Unique unusual domains: ${#DOMAIN_COUNT[@]}${NC}"
echo

echo -e "${YELLOW}Top 10 Unusual Email Domains:${NC}"
TOP_COUNT=0
for domain in $(for d in "${!DOMAIN_COUNT[@]}"; do echo "${DOMAIN_COUNT[$d]} $d"; done | sort -rn | cut -d' ' -f2); do
    if [ $TOP_COUNT -ge 10 ]; then
        break
    fi
    COUNT=${DOMAIN_COUNT[$domain]}
    echo -e "${CYAN}  $((TOP_COUNT + 1)). $domain ${GRAY}($COUNT user(s))${NC}"
    TOP_COUNT=$((TOP_COUNT + 1))
done

if [ ${#DOMAIN_COUNT[@]} -gt 10 ]; then
    echo -e "${GRAY}  ... and $((${#DOMAIN_COUNT[@]} - 10)) more (see reports for full list)${NC}"
fi

echo
echo -e "${YELLOW}Reports saved to:${NC}"
echo -e "${CYAN}  TXT Report: $UNUSUAL_EMAILS_TXT${NC}"
echo -e "${CYAN}  CSV Report: $UNUSUAL_EMAILS_CSV${NC}"
echo -e "${CYAN}  JSON Report: $UNUSUAL_EMAILS_JSON${NC}"
echo -e "${CYAN}  Statistics: $DOMAIN_STATS_TXT${NC}"

echo
echo -e "${CYAN}=============================================${NC}"
echo -e "${GREEN}Scan complete! Review the reports to identify potentially suspicious registrations.${NC}"
echo -e "${CYAN}=============================================${NC}"
