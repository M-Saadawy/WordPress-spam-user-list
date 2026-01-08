#!/bin/bash
# =====================================
# WP User Cleanup Script (Script 1)
# Purpose: Delete users with spam email domains
# Features: 
# - Exact domain matching (prevents false positives)
# - Dynamic whitelist from GitHub (required)
# - Comprehensive logging
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
USERS_LOG="$LOG_DIR/deleted_users_$TIMESTAMP.txt"
DOMAINS_LOG="$LOG_DIR/spam_domains.txt"
DOMAINS_CSV="$LOG_DIR/spam_domains.csv"
DOMAINS_JSON="$LOG_DIR/spam_domains.json"

# Initialize domain tracking
declare -A DOMAIN_MAP

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress User Cleanup (Script 1) ====${NC}"
echo -e "${CYAN}==== Spam Domain User Removal =============${NC}"
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

# Function to check if domain is whitelisted
is_whitelisted() {
    local domain="$1"
    # Remove @ if present
    domain="${domain#@}"
    
    for whitelist in "${WHITELIST_DOMAINS[@]}"; do
        if [[ "$domain" == "$whitelist" ]]; then
            return 0  # Is whitelisted
        fi
    done
    return 1  # Not whitelisted
}

# Escape special characters for SQL
escape_for_sql() {
    echo "$1" | sed "s/'/''/g"
}

# =====================================
# SPAM DOMAIN INPUT
# =====================================
echo
echo -e "${YELLOW}Choose input method for spam domains:${NC}"
echo -e "${WHITE}  1) Fetch spam domain list from GitHub (recommended)${NC}"
echo -e "${WHITE}  2) Enter domain manually${NC}"
echo -ne "${YELLOW}Enter choice 1 or 2: ${NC}"
read CHOICE

SPAM_DOMAINS=()

if [ "$CHOICE" == "1" ]; then
    echo -e "${BLUE}Fetching spam domain list from GitHub...${NC}"
    GITHUB_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/list.txt"
    
    # Download the list
    TEMP_FILE=$(mktemp)
    if curl -s -f "$GITHUB_URL" -o "$TEMP_FILE" 2>/dev/null && [ -s "$TEMP_FILE" ]; then
        SKIPPED_COUNT=0
        # Read domains into array, skipping empty lines and comments
        while IFS= read -r line; do
            # Trim whitespace
            line=$(echo "$line" | xargs)
            # Skip empty lines and comments
            if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                # Add @ if not present
                if [[ ! "$line" =~ ^@ ]]; then
                    line="@$line"
                fi
                
                # Check if domain is whitelisted
                if is_whitelisted "$line"; then
                    echo -e "${YELLOW}⚠ Skipping whitelisted domain: $line${NC}"
                    ((SKIPPED_COUNT++))
                else
                    SPAM_DOMAINS+=("$line")
                fi
            fi
        done < "$TEMP_FILE"
        rm -f "$TEMP_FILE"
        
        echo -e "${GREEN}Successfully loaded ${#SPAM_DOMAINS[@]} spam domains from GitHub${NC}"
        if [ $SKIPPED_COUNT -gt 0 ]; then
            echo -e "${YELLOW}Skipped $SKIPPED_COUNT whitelisted domains for safety${NC}"
        fi
    else
        echo -e "${RED}Failed to download spam list from GitHub.${NC}"
        echo -e "${YELLOW}Falling back to manual entry...${NC}"
        echo -ne "${YELLOW}Enter the email/domain to search for (e.g., @orbitaloffer.online): ${NC}"
        read VALUE
        if [ -z "$VALUE" ]; then
            echo -e "${RED}No value entered. Exiting.${NC}"
            exit 1
        fi
        
        # Add @ if not present
        if [[ ! "$VALUE" =~ ^@ ]]; then
            VALUE="@$VALUE"
        fi
        
        # Check if manually entered domain is whitelisted
        if is_whitelisted "$VALUE"; then
            echo -e "${RED}ERROR: '$VALUE' is a whitelisted domain and cannot be used.${NC}"
            exit 1
        fi
        
        SPAM_DOMAINS=("$VALUE")
    fi
elif [ "$CHOICE" == "2" ]; then
    echo -ne "${YELLOW}Enter the email/domain to search for (e.g., @orbitaloffer.online): ${NC}"
    read VALUE
    if [ -z "$VALUE" ]; then
        echo -e "${RED}No value entered. Exiting.${NC}"
        exit 1
    fi
    
    # Add @ if not present
    if [[ ! "$VALUE" =~ ^@ ]]; then
        VALUE="@$VALUE"
    fi
    
    # Check if manually entered domain is whitelisted
    if is_whitelisted "$VALUE"; then
        echo -e "${RED}ERROR: '$VALUE' is a whitelisted domain and cannot be used.${NC}"
        exit 1
    fi
    
    SPAM_DOMAINS=("$VALUE")
else
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

# Verify we have spam domains to search for
if [ ${#SPAM_DOMAINS[@]} -eq 0 ]; then
    echo -e "${RED}No spam domains to search for. Exiting.${NC}"
    exit 1
fi

# Show preview before proceeding
echo
if [ "$CHOICE" == "2" ]; then
    # Manual entry - show the specific domain
    echo -e "${YELLOW}Domain to search for deletion:${NC}"
    for domain in "${SPAM_DOMAINS[@]}"; do
        echo -e "${CYAN}  - $domain${NC}"
    done
else
    # GitHub list - show summary only
    echo -e "${GREEN}Ready to search for spam users across all WordPress sites${NC}"
    echo -e "${CYAN}  → Total spam domains to search: ${#SPAM_DOMAINS[@]}${NC}"
    if [ ${#SPAM_DOMAINS[@]} -le 5 ]; then
        echo -e "${CYAN}  → Domains: ${SPAM_DOMAINS[*]}${NC}"
    else
        echo -e "${CYAN}  → Sample domains: ${SPAM_DOMAINS[0]}, ${SPAM_DOMAINS[1]}, ${SPAM_DOMAINS[2]}...${NC}"
    fi
fi
echo
echo -ne "${YELLOW}Do you want to proceed? Type 'yes' to continue: ${NC}"
read PROCEED
if [ "$PROCEED" != "yes" ]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
fi

# =====================================
# SCAN AND DELETE SPAM USERS
# =====================================
echo
echo -e "${BLUE}Searching all WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log files will be saved to: $LOG_DIR${NC}"
echo

TOTAL_DELETED_USERS=0
TOTAL_DELETED_COMMENTS=0

for SITE_PATH in $BASE_DIR/*/public_html; do
    if [ -f "$SITE_PATH/wp-config.php" ]; then
        echo -e "${MAGENTA}-------------------------------------------${NC}"
        echo -e "${WHITE}Site detected: ${CYAN}$SITE_PATH${NC}"

        # Extract database credentials from wp-config.php
        DB_NAME=$(grep "DB_NAME" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_USER=$(grep "DB_USER" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_PASS=$(grep "DB_PASSWORD" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        DB_HOST=$(grep "DB_HOST" "$SITE_PATH/wp-config.php" | cut -d"'" -f4)
        PREFIX=$(grep "\$table_prefix" "$SITE_PATH/wp-config.php" | cut -d"'" -f2)

        if [ -z "$PREFIX" ]; then
            PREFIX="wp_"
            echo -e "${YELLOW}Warning: Could not detect prefix, using default: $PREFIX${NC}"
        fi

        if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
            echo -e "${RED}Error: Could not extract database credentials from wp-config.php${NC}"
            continue
        fi

        echo -e "${GRAY}  Database: $DB_NAME, Prefix: $PREFIX${NC}"
        echo -e "${GRAY}  Searching for ${#SPAM_DOMAINS[@]} spam domain(s)...${NC}"

        # Build WHERE clause with exact domain matching using SUBSTRING_INDEX
        WHERE_CLAUSE=""
        
        for domain in "${SPAM_DOMAINS[@]}"; do
            domain_escaped=$(escape_for_sql "$domain")
            # Remove @ from domain for matching
            domain_no_at="${domain_escaped#@}"
            
            if [ -z "$WHERE_CLAUSE" ]; then
                # EXACT match: SUBSTRING_INDEX(user_email, '@', -1) gets everything after @
                WHERE_CLAUSE="SUBSTRING_INDEX(user_email, '@', -1) = '$domain_no_at'"
            else
                WHERE_CLAUSE="$WHERE_CLAUSE OR SUBSTRING_INDEX(user_email, '@', -1) = '$domain_no_at'"
            fi
        done
        
        # Also search in username/login for spam keywords (optional but helpful)
        SPAM_USER_KEYWORDS=("BINANCE" "BYBIT" "BTC" "BITCOIN" "CRYPTO" "MINING" "WALLET" "ETHEREUM" "USDT" "FOREX" "TRADING")
        for keyword in "${SPAM_USER_KEYWORDS[@]}"; do
            keyword_escaped=$(escape_for_sql "$keyword")
            WHERE_CLAUSE="$WHERE_CLAUSE OR user_login LIKE '%$keyword_escaped%'"
        done

        # Get matching users details BEFORE deletion
        USER_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT ID, user_login, user_email 
        FROM ${PREFIX}users
        WHERE $WHERE_CLAUSE;
        " 2>/dev/null)

        # Count matching users
        if [ -z "$USER_DATA" ]; then
            USER_COUNT=0
        else
            USER_COUNT=$(echo "$USER_DATA" | wc -l)
        fi

        if [ "$USER_COUNT" -gt 0 ]; then
            echo -e "${GREEN}Found $USER_COUNT user(s) with spam domains:${NC}"
            
            # Log to file
            echo "=== Spam Users Found in $SITE_PATH ===" >> "$USERS_LOG"
            echo "Timestamp: $(date)" >> "$USERS_LOG"
            echo "Database: $DB_NAME" >> "$USERS_LOG"
            echo "" >> "$USERS_LOG"
            
            echo "$USER_DATA" | while IFS=$'\t' read -r USER_ID USER_LOGIN USER_EMAIL; do
                # Extract and store domain for logging
                DOMAIN=$(echo "$USER_EMAIL" | grep -oP '@\K.*')
                DOMAIN_MAP["$DOMAIN"]=1
                
                echo -e "${YELLOW}  - ID: $USER_ID, Login: $USER_LOGIN, Email: $USER_EMAIL${NC}"
                
                # Log to file
                echo "User ID: $USER_ID" >> "$USERS_LOG"
                echo "  Login: $USER_LOGIN" >> "$USERS_LOG"
                echo "  Email: $USER_EMAIL" >> "$USERS_LOG"
                echo "" >> "$USERS_LOG"
            done
            
            echo
            echo -ne "${RED}Do you want to DELETE these users? Type 'yes' to confirm: ${NC}"
            read CONFIRM
            
            if [ "$CONFIRM" == "yes" ]; then
                # Get user IDs for comment deletion
                USER_IDS=$(echo "$USER_DATA" | cut -f1 | tr '\n' ',' | sed 's/,$//')
                
                # Count comments by these users
                COMMENT_COUNT_BY_USERS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id IN ($USER_IDS);
                " 2>/dev/null)
                
                # Default to 0 if query returns empty/null
                COMMENT_COUNT_BY_USERS=${COMMENT_COUNT_BY_USERS:-0}
                
                if [ "$COMMENT_COUNT_BY_USERS" -gt 0 ]; then
                    echo -e "${YELLOW}  → These users have $COMMENT_COUNT_BY_USERS comment(s) that will also be deleted${NC}"
                fi
                
                # Perform deletion - delete comments first, then commentmeta, then usermeta, then users
                
                # Delete commentmeta for comments by these users
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}commentmeta
                WHERE comment_id IN (
                    SELECT comment_ID FROM (SELECT comment_ID FROM ${PREFIX}comments WHERE user_id IN ($USER_IDS)) AS temp
                );
                " 2>/dev/null
                
                # Delete comments by these users
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}comments WHERE user_id IN ($USER_IDS);
                " 2>/dev/null
                
                # Delete usermeta
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}usermeta
                WHERE user_id IN (
                    SELECT ID FROM (SELECT ID FROM ${PREFIX}users WHERE $WHERE_CLAUSE) AS temp
                );
                " 2>/dev/null

                # Delete users
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}users
                WHERE $WHERE_CLAUSE;
                " 2>/dev/null
                
                echo -e "${GREEN}✓ Deleted $USER_COUNT user(s)${NC}"
                if [ "$COMMENT_COUNT_BY_USERS" -gt 0 ]; then
                    echo -e "${GREEN}✓ Deleted $COMMENT_COUNT_BY_USERS comment(s) by those users${NC}"
                    TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + COMMENT_COUNT_BY_USERS))
                fi
                TOTAL_DELETED_USERS=$((TOTAL_DELETED_USERS + USER_COUNT))
            else
                echo -e "${GRAY}Skipped user deletion${NC}"
            fi
        else
            echo -e "${GRAY}No spam users found${NC}"
        fi
        echo
    fi
done

# =====================================
# SAVE SPAM DOMAINS TO LOG FILES
# =====================================
if [ ${#DOMAIN_MAP[@]} -gt 0 ]; then
    # Read existing domains from files to avoid duplicates
    declare -A EXISTING_DOMAINS
    
    if [ -f "$DOMAINS_LOG" ]; then
        while IFS= read -r line; do
            if [[ ! "$line" =~ ^# ]] && [ -n "$line" ]; then
                EXISTING_DOMAINS["$line"]=1
            fi
        done < "$DOMAINS_LOG"
    fi
    
    # Merge new domains with existing
    for domain in "${!DOMAIN_MAP[@]}"; do
        EXISTING_DOMAINS["$domain"]=1
    done
    
    # TXT format
    echo "# Spam Domains Log" > "$DOMAINS_LOG"
    echo "# Last updated: $(date)" >> "$DOMAINS_LOG"
    echo "# Total unique domains: ${#EXISTING_DOMAINS[@]}" >> "$DOMAINS_LOG"
    echo "# ================================" >> "$DOMAINS_LOG"
    for domain in "${!EXISTING_DOMAINS[@]}"; do
        echo "$domain"
    done | sort >> "$DOMAINS_LOG"

    # CSV format
    echo "domain" > "$DOMAINS_CSV"
    for domain in "${!EXISTING_DOMAINS[@]}"; do
        echo "$domain"
    done | sort >> "$DOMAINS_CSV"

    # JSON format
    echo "{" > "$DOMAINS_JSON"
    echo "  \"last_updated\": \"$(date -Iseconds)\"," >> "$DOMAINS_JSON"
    echo "  \"total_domains\": ${#EXISTING_DOMAINS[@]}," >> "$DOMAINS_JSON"
    echo "  \"domains\": [" >> "$DOMAINS_JSON"
    
    FIRST=true
    for domain in $(for d in "${!EXISTING_DOMAINS[@]}"; do echo "$d"; done | sort); do
        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            echo "," >> "$DOMAINS_JSON"
        fi
        echo -n "    \"$domain\"" >> "$DOMAINS_JSON"
    done
    
    echo "" >> "$DOMAINS_JSON"
    echo "  ]" >> "$DOMAINS_JSON"
    echo "}" >> "$DOMAINS_JSON"
fi

# =====================================
# FINAL SUMMARY
# =====================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== User Cleanup Script Finished =========${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
    echo -e "${GREEN}Summary:${NC}"
    echo -e "${GREEN}  Total users deleted: $TOTAL_DELETED_USERS${NC}"
    echo -e "${GREEN}  Total comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo -e "${GREEN}  Unique spam domains logged: ${#DOMAIN_MAP[@]}${NC}"
    echo
    
    echo -e "${YELLOW}Logs saved to:${NC}"
    echo -e "${CYAN}  Users Log: $USERS_LOG${NC}"
    echo -e "${CYAN}  Domains (TXT): $DOMAINS_LOG${NC}"
    echo -e "${CYAN}  Domains (CSV): $DOMAINS_CSV${NC}"
    echo -e "${CYAN}  Domains (JSON): $DOMAINS_JSON${NC}"
else
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "${YELLOW}  No users were deleted${NC}"
fi

echo
echo -e "${CYAN}Thank you for using WordPress User Cleanup Script!${NC}"
