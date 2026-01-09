#!/bin/bash
# =====================================
# WP Unusual Email Finder (Script 2)
# Purpose: Find and list unusual email domains for review
# Features: 
# - Compares against whitelist
# - Groups results by domain
# - Outputs in @domain format for easy blacklist addition
# - No deletion - review only
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

# Log files
UNUSUAL_DOMAINS_LOG="$LOG_DIR/unusual_domains_$TIMESTAMP.txt"
UNUSUAL_DOMAINS_BLACKLIST="$LOG_DIR/unusual_domains_blacklist_ready_$TIMESTAMP.txt"
UNUSUAL_DOMAINS_REPORT="$LOG_DIR/unusual_domains_report_$TIMESTAMP.txt"

# Associative arrays for tracking
declare -A DOMAIN_COUNT
declare -A DOMAIN_SAMPLE_USERS

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress Unusual Email Finder ========${NC}"
echo -e "${CYAN}==== Domain Analysis & Review ==============${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# =====================================
# FETCH WHITELIST FROM GITHUB (REQUIRED)
# =====================================
echo -e "${BLUE}Fetching whitelist from GitHub...${NC}"
WHITELIST_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/whitelist.txt"
TEMP_WHITELIST=$(mktemp)

WHITELIST_DOMAINS=()

if curl -s -f "$WHITELIST_URL" -o "$TEMP_WHITELIST" 2>/dev/null && [ -s "$TEMP_WHITELIST" ]; then
    echo -e "${GREEN}✓ Successfully downloaded whitelist from GitHub${NC}"
    
    # Load whitelist from file
    while IFS= read -r line; do
        # Trim whitespace
        line=$(echo "$line" | xargs)
        # Skip empty lines and comments
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            # Remove @ if present
            line="${line#@}"
            WHITELIST_DOMAINS+=("$line")
        fi
    done < "$TEMP_WHITELIST"
    
    echo -e "${GREEN}  Loaded ${#WHITELIST_DOMAINS[@]} whitelisted domains${NC}"
    if [ ${#WHITELIST_DOMAINS[@]} -gt 3 ]; then
        echo -e "${GRAY}  Sample: ${WHITELIST_DOMAINS[0]}, ${WHITELIST_DOMAINS[1]}, ${WHITELIST_DOMAINS[2]}...${NC}"
    fi
else
    echo -e "${RED}✗ ERROR: Could not fetch whitelist from GitHub${NC}"
    echo -e "${RED}  URL: $WHITELIST_URL${NC}"
    echo -e "${RED}  The whitelist is required for safe operation. Exiting.${NC}"
    rm -f "$TEMP_WHITELIST"
    exit 1
fi
rm -f "$TEMP_WHITELIST"

# Verify we have domains loaded
if [ ${#WHITELIST_DOMAINS[@]} -eq 0 ]; then
    echo -e "${RED}✗ ERROR: Whitelist is empty. Cannot proceed safely. Exiting.${NC}"
    exit 1
fi

# Convert whitelist to associative array for faster lookup
declare -A WHITELIST_MAP
for domain in "${WHITELIST_DOMAINS[@]}"; do
    WHITELIST_MAP["$domain"]=1
done

# Function to check if domain is whitelisted
is_whitelisted() {
    local domain="$1"
    # Remove @ if present
    domain="${domain#@}"
    
    # Check if exists in map (much faster than looping)
    [[ -n "${WHITELIST_MAP[$domain]}" ]]
}

# =====================================
# FETCH EXISTING BLACKLIST (OPTIONAL)
# =====================================
echo
echo -e "${BLUE}Fetching existing blacklist from GitHub...${NC}"
BLACKLIST_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/list.txt"
TEMP_BLACKLIST=$(mktemp)

declare -A BLACKLIST_MAP

if curl -s -f "$BLACKLIST_URL" -o "$TEMP_BLACKLIST" 2>/dev/null && [ -s "$TEMP_BLACKLIST" ]; then
    echo -e "${GREEN}✓ Successfully downloaded blacklist from GitHub${NC}"
    
    # Load blacklist from file
    BLACKLIST_COUNT=0
    while IFS= read -r line; do
        # Trim whitespace
        line=$(echo "$line" | xargs)
        # Skip empty lines and comments
        if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
            # Remove @ if present
            line="${line#@}"
            BLACKLIST_MAP["$line"]=1
            ((BLACKLIST_COUNT++))
        fi
    done < "$TEMP_BLACKLIST"
    
    echo -e "${GREEN}  Loaded $BLACKLIST_COUNT blacklisted domains${NC}"
    echo -e "${GRAY}  (These will be excluded from unusual domain results)${NC}"
else
    echo -e "${YELLOW}⚠ Could not fetch blacklist (this is optional)${NC}"
    echo -e "${GRAY}  Continuing without blacklist filter...${NC}"
fi
rm -f "$TEMP_BLACKLIST"

# Function to check if domain is blacklisted
is_blacklisted() {
    local domain="$1"
    # Remove @ if present
    domain="${domain#@}"
    
    # Check if exists in map
    [[ -n "${BLACKLIST_MAP[$domain]}" ]]
}

# =====================================
# CONFIGURATION
# =====================================
echo
echo -e "${YELLOW}Configuration:${NC}"
echo -e "${WHITE}  This script will scan all WordPress users and find unusual email domains.${NC}"
echo -e "${WHITE}  Domains will be excluded if they are:${NC}"
echo -e "${CYAN}    - Whitelisted (safe domains like gmail.com, yahoo.com, etc.)${NC}"
echo -e "${CYAN}    - Already blacklisted (already known spam domains)${NC}"
echo
echo -e "${YELLOW}Minimum user count filter (optional):${NC}"
echo -e "${GRAY}  Only show domains with at least X users (helps find patterns)${NC}"
echo -e "${GRAY}  Enter 1 to see all domains, or higher number to filter (e.g., 5, 10)${NC}"
echo -ne "${YELLOW}Enter minimum user count (default: 1): ${NC}"
read MIN_USER_COUNT

# Default to 1 if empty or non-numeric
if ! [[ "$MIN_USER_COUNT" =~ ^[0-9]+$ ]]; then
    MIN_USER_COUNT=1
fi

echo -e "${GREEN}  → Will show domains with at least $MIN_USER_COUNT user(s)${NC}"

echo
echo -ne "${YELLOW}Do you want to proceed? Type 'yes' to continue: ${NC}"
read PROCEED
if [ "$PROCEED" != "yes" ]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
fi

# =====================================
# SCAN FOR UNUSUAL DOMAINS
# =====================================
echo
echo -e "${BLUE}Scanning all WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}This may take a while depending on the number of users...${NC}"
echo

TOTAL_SITES=0
TOTAL_USERS_SCANNED=0

for SITE_PATH in $BASE_DIR/*/public_html; do
    if [ -f "$SITE_PATH/wp-config.php" ]; then
        ((TOTAL_SITES++))
        echo -e "${MAGENTA}-------------------------------------------${NC}"
        echo -e "${WHITE}Site $TOTAL_SITES: ${CYAN}$SITE_PATH${NC}"

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
            echo -e "${RED}  ✗ Could not extract database credentials${NC}"
            continue
        fi

        echo -e "${GRAY}  Database: $DB_NAME, Prefix: $PREFIX${NC}"

        # Get all user emails
        USER_EMAILS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT user_login, user_email 
        FROM ${PREFIX}users 
        WHERE user_email != '' 
        ORDER BY user_email;
        " 2>&1)

        if [[ "$USER_EMAILS" =~ ^ERROR ]]; then
            echo -e "${RED}  ✗ Database error: $USER_EMAILS${NC}"
            continue
        fi

        # Count users
        SITE_USER_COUNT=$(echo "$USER_EMAILS" | wc -l)
        if [ -z "$USER_EMAILS" ]; then
            SITE_USER_COUNT=0
        fi
        
        echo -e "${GREEN}  ✓ Found $SITE_USER_COUNT users${NC}"
        TOTAL_USERS_SCANNED=$((TOTAL_USERS_SCANNED + SITE_USER_COUNT))

        # Process each user email
        while IFS=$'\t' read -r USER_LOGIN USER_EMAIL; do
            # Extract domain from email
            if [[ "$USER_EMAIL" =~ @(.+)$ ]]; then
                DOMAIN="${BASH_REMATCH[1]}"
                
                # Skip if whitelisted
                if is_whitelisted "$DOMAIN"; then
                    continue
                fi
                
                # Skip if already blacklisted
                if is_blacklisted "$DOMAIN"; then
                    continue
                fi
                
                # Track this domain
                if [[ -z "${DOMAIN_COUNT[$DOMAIN]}" ]]; then
                    DOMAIN_COUNT["$DOMAIN"]=1
                    DOMAIN_SAMPLE_USERS["$DOMAIN"]="$USER_LOGIN ($USER_EMAIL)"
                else
                    DOMAIN_COUNT["$DOMAIN"]=$((DOMAIN_COUNT["$DOMAIN"] + 1))
                    # Keep first 3 sample users
                    SAMPLE_COUNT=$(echo "${DOMAIN_SAMPLE_USERS[$DOMAIN]}" | grep -o "|" | wc -l)
                    if [ "$SAMPLE_COUNT" -lt 2 ]; then
                        DOMAIN_SAMPLE_USERS["$DOMAIN"]="${DOMAIN_SAMPLE_USERS[$DOMAIN]} | $USER_LOGIN ($USER_EMAIL)"
                    fi
                fi
            fi
        done <<< "$USER_EMAILS"
        
        echo -e "${GRAY}  Processed. Unique unusual domains so far: ${#DOMAIN_COUNT[@]}${NC}"
    fi
done

# =====================================
# GENERATE REPORTS
# =====================================
echo
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Analysis Complete =====================${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ ${#DOMAIN_COUNT[@]} -eq 0 ]; then
    echo -e "${GREEN}No unusual domains found!${NC}"
    echo -e "${GRAY}All user emails are either whitelisted or already blacklisted.${NC}"
    exit 0
fi

echo -e "${GREEN}Scan Summary:${NC}"
echo -e "${CYAN}  Total sites scanned: $TOTAL_SITES${NC}"
echo -e "${CYAN}  Total users scanned: $TOTAL_USERS_SCANNED${NC}"
echo -e "${CYAN}  Unusual domains found: ${#DOMAIN_COUNT[@]}${NC}"
echo

# Sort domains by count (descending)
SORTED_DOMAINS=$(for domain in "${!DOMAIN_COUNT[@]}"; do
    echo "${DOMAIN_COUNT[$domain]} $domain"
done | sort -rn)

# Filter by minimum count and generate reports
echo -e "${YELLOW}Generating reports...${NC}"

# Full report with details
echo "========================================" > "$UNUSUAL_DOMAINS_REPORT"
echo "Unusual Email Domains Report" >> "$UNUSUAL_DOMAINS_REPORT"
echo "Generated: $(date)" >> "$UNUSUAL_DOMAINS_REPORT"
echo "========================================" >> "$UNUSUAL_DOMAINS_REPORT"
echo "" >> "$UNUSUAL_DOMAINS_REPORT"
echo "Total sites scanned: $TOTAL_SITES" >> "$UNUSUAL_DOMAINS_REPORT"
echo "Total users scanned: $TOTAL_USERS_SCANNED" >> "$UNUSUAL_DOMAINS_REPORT"
echo "Unusual domains found: ${#DOMAIN_COUNT[@]}" >> "$UNUSUAL_DOMAINS_REPORT"
echo "Minimum user count filter: $MIN_USER_COUNT" >> "$UNUSUAL_DOMAINS_REPORT"
echo "" >> "$UNUSUAL_DOMAINS_REPORT"
echo "========================================" >> "$UNUSUAL_DOMAINS_REPORT"
echo "DOMAINS (sorted by user count)" >> "$UNUSUAL_DOMAINS_REPORT"
echo "========================================" >> "$UNUSUAL_DOMAINS_REPORT"
echo "" >> "$UNUSUAL_DOMAINS_REPORT"

# Simple domain list (for adding to blacklist)
echo "# Unusual domains found on $(date)" > "$UNUSUAL_DOMAINS_BLACKLIST"
echo "# Ready to add to blacklist" >> "$UNUSUAL_DOMAINS_BLACKLIST"
echo "# Format: @domain (one per line)" >> "$UNUSUAL_DOMAINS_BLACKLIST"
echo "" >> "$UNUSUAL_DOMAINS_BLACKLIST"

# All domains list (unfiltered)
echo "# All unusual domains (unfiltered)" > "$UNUSUAL_DOMAINS_LOG"
echo "# Generated: $(date)" >> "$UNUSUAL_DOMAINS_LOG"
echo "" >> "$UNUSUAL_DOMAINS_LOG"

FILTERED_COUNT=0
DISPLAYED_COUNT=0

echo -e "${YELLOW}Top Unusual Domains (filtered by min count: $MIN_USER_COUNT):${NC}"
echo

while IFS=' ' read -r COUNT DOMAIN; do
    # Add to unfiltered log
    echo "@$DOMAIN" >> "$UNUSUAL_DOMAINS_LOG"
    
    # Add to detailed report
    printf "Domain: @%-40s Users: %5d\n" "$DOMAIN" "$COUNT" >> "$UNUSUAL_DOMAINS_REPORT"
    echo "  Sample users: ${DOMAIN_SAMPLE_USERS[$DOMAIN]}" >> "$UNUSUAL_DOMAINS_REPORT"
    echo "" >> "$UNUSUAL_DOMAINS_REPORT"
    
    # Filter by minimum count
    if [ "$COUNT" -ge "$MIN_USER_COUNT" ]; then
        ((FILTERED_COUNT++))
        
        # Add to blacklist-ready file
        echo "@$DOMAIN" >> "$UNUSUAL_DOMAINS_BLACKLIST"
        
        # Display top 50 on screen
        if [ $DISPLAYED_COUNT -lt 50 ]; then
            printf "${CYAN}  @%-40s ${YELLOW}%5d users${NC}\n" "$DOMAIN" "$COUNT"
            ((DISPLAYED_COUNT++))
        fi
    fi
done <<< "$SORTED_DOMAINS"

if [ $DISPLAYED_COUNT -eq 50 ] && [ $FILTERED_COUNT -gt 50 ]; then
    echo
    echo -e "${GRAY}  ... and $((FILTERED_COUNT - 50)) more (see report files)${NC}"
fi

# =====================================
# FINAL SUMMARY
# =====================================
echo
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Reports Generated =====================${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

echo -e "${GREEN}Summary:${NC}"
echo -e "${CYAN}  Total unusual domains found: ${#DOMAIN_COUNT[@]}${NC}"
echo -e "${CYAN}  Domains meeting filter (≥$MIN_USER_COUNT users): $FILTERED_COUNT${NC}"
echo

echo -e "${YELLOW}Report files saved:${NC}"
echo -e "${WHITE}  1. Blacklist-ready file (filtered):${NC}"
echo -e "${CYAN}     $UNUSUAL_DOMAINS_BLACKLIST${NC}"
echo -e "${GRAY}     → Use this to add domains to your blacklist${NC}"
echo

echo -e "${WHITE}  2. Detailed report:${NC}"
echo -e "${CYAN}     $UNUSUAL_DOMAINS_REPORT${NC}"
echo -e "${GRAY}     → Full analysis with user counts and samples${NC}"
echo

echo -e "${WHITE}  3. All domains (unfiltered):${NC}"
echo -e "${CYAN}     $UNUSUAL_DOMAINS_LOG${NC}"
echo -e "${GRAY}     → Complete list regardless of user count${NC}"
echo

echo -e "${YELLOW}Next steps:${NC}"
echo -e "${WHITE}  1. Review the blacklist-ready file: ${CYAN}$UNUSUAL_DOMAINS_BLACKLIST${NC}"
echo -e "${WHITE}  2. Copy legitimate domains to whitelist, spam domains to blacklist${NC}"
echo -e "${WHITE}  3. Run the cleanup script (Script 1) to delete spam users${NC}"
echo

echo -e "${CYAN}Thank you for using WordPress Unusual Email Finder!${NC}"
