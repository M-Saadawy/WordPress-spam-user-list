#!/bin/bash
# =====================================
# WP User & Comment Cleanup Script (FIXED)
# CRITICAL FIX: Uses exact domain matching to prevent false positives
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

# Use fixed filenames (no timestamp) - will append to same files
DOMAINS_LOG="$LOG_DIR/spam_domains.txt"
DOMAINS_CSV="$LOG_DIR/spam_domains.csv"
DOMAINS_JSON="$LOG_DIR/spam_domains.json"
COMMENTS_LOG="$LOG_DIR/deleted_comments_$TIMESTAMP.txt"

# Initialize domain tracking
declare -A DOMAIN_MAP

# WHITELIST - Legitimate domains that should NEVER be deleted
WHITELIST_DOMAINS=(
    "gmail.com"
    "yahoo.com"
    "outlook.com"
    "hotmail.com"
    "icloud.com"
    "protonmail.com"
    "aol.com"
    "zoho.com"
    "mail.com"
    "yandex.com"
    "live.com"
    "msn.com"
)

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress User & Comment Cleanup ====${NC}"
echo -e "${CYAN}==== (FIXED - Exact Domain Matching) ====${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

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

# =====================================
# STEP 1: CLEANUP MODE SELECTION
# =====================================
echo -e "${YELLOW}What would you like to clean up?${NC}"
echo -e "${WHITE}  1) Users only (based on spam domains)${NC}"
echo -e "${WHITE}  2) Comments only (based on keywords)${NC}"
echo -e "${WHITE}  3) Both users and comments${NC}"
read -p "$(echo -e ${YELLOW}Enter choice 1, 2, or 3: ${NC})" CLEANUP_MODE

if [[ ! "$CLEANUP_MODE" =~ ^[1-3]$ ]]; then
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

# =====================================
# STEP 2: USER CLEANUP CONFIGURATION
# =====================================
SPAM_DOMAINS=()
if [[ "$CLEANUP_MODE" == "1" || "$CLEANUP_MODE" == "3" ]]; then
    echo
    echo -e "${YELLOW}Choose input method for user cleanup:${NC}"
    echo -e "${WHITE}  1) Fetch spam domains from GitHub (recommended)${NC}"
    echo -e "${WHITE}  2) Enter domain manually${NC}"
    read -p "$(echo -e ${YELLOW}Enter choice 1 or 2: ${NC})" CHOICE

    if [ "$CHOICE" == "1" ]; then
        echo -e "${BLUE}Fetching spam domain list from GitHub...${NC}"
        GITHUB_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/list.txt"
        
        # Download the list
        TEMP_FILE=$(mktemp)
        if curl -s -f "$GITHUB_URL" -o "$TEMP_FILE"; then
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
            read -p "$(echo -e ${YELLOW}Enter the email/domain to search for e.g., @orbitaloffer.online: ${NC})" VALUE
            if [ -z "$VALUE" ]; then
                echo -e "${RED}No value entered. Exiting.${NC}"
                exit 1
            fi
            
            # Check if manually entered domain is whitelisted
            if is_whitelisted "$VALUE"; then
                echo -e "${RED}ERROR: '$VALUE' is a whitelisted domain and cannot be used.${NC}"
                echo -e "${YELLOW}Whitelisted domains: ${WHITELIST_DOMAINS[*]}${NC}"
                exit 1
            fi
            
            SPAM_DOMAINS=("$VALUE")
        fi
    elif [ "$CHOICE" == "2" ]; then
        read -p "$(echo -e ${YELLOW}Enter the email/domain to search for e.g., @orbitaloffer.online: ${NC})" VALUE
        if [ -z "$VALUE" ]; then
            echo -e "${RED}No value entered. Exiting.${NC}"
            exit 1
        fi
        
        # Check if manually entered domain is whitelisted
        if is_whitelisted "$VALUE"; then
            echo -e "${RED}ERROR: '$VALUE' is a whitelisted domain and cannot be used.${NC}"
            echo -e "${YELLOW}Whitelisted domains: ${WHITELIST_DOMAINS[*]}${NC}"
            exit 1
        fi
        
        SPAM_DOMAINS=("$VALUE")
    else
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        exit 1
    fi
    
    # Show preview before proceeding
    if [ ${#SPAM_DOMAINS[@]} -gt 0 ]; then
        echo
        echo -e "${YELLOW}The following ${#SPAM_DOMAINS[@]} domains will be searched for deletion:${NC}"
        for domain in "${SPAM_DOMAINS[@]}"; do
            echo -e "${CYAN}  - $domain${NC}"
        done
        echo
        read -p "$(echo -e ${YELLOW}Do you want to proceed with these domains? Type 'yes' to continue: ${NC})" PROCEED
        if [ "$PROCEED" != "yes" ]; then
            echo -e "${RED}Aborted by user.${NC}"
            exit 1
        fi
    fi
fi

# =====================================
# STEP 3: COMMENT CLEANUP CONFIGURATION
# =====================================
SPAM_KEYWORDS=()
if [[ "$CLEANUP_MODE" == "2" || "$CLEANUP_MODE" == "3" ]]; then
    echo
    echo -e "${YELLOW}Configure comment keyword search:${NC}"
    echo -e "${WHITE}  1) Fetch spam keywords from GitHub (recommended)${NC}"
    echo -e "${WHITE}  2) Enter custom keywords${NC}"
    read -p "$(echo -e ${YELLOW}Enter choice 1 or 2: ${NC})" KEYWORD_CHOICE

    if [ "$KEYWORD_CHOICE" == "1" ]; then
        echo -e "${BLUE}Fetching spam keyword list from GitHub...${NC}"
        GITHUB_KEYWORDS_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/comments.txt"
        
        # Download the keywords list
        TEMP_KEYWORDS_FILE=$(mktemp)
        if curl -s -f "$GITHUB_KEYWORDS_URL" -o "$TEMP_KEYWORDS_FILE"; then
            # Read keywords into array, skipping empty lines and comments
            while IFS= read -r line; do
                # Trim whitespace
                line=$(echo "$line" | xargs)
                # Skip empty lines and comments
                if [ -n "$line" ] && [[ ! "$line" =~ ^# ]]; then
                    SPAM_KEYWORDS+=("$line")
                fi
            done < "$TEMP_KEYWORDS_FILE"
            rm -f "$TEMP_KEYWORDS_FILE"
            
            if [ ${#SPAM_KEYWORDS[@]} -gt 0 ]; then
                echo -e "${GREEN}Successfully loaded ${#SPAM_KEYWORDS[@]} spam keywords from GitHub${NC}"
                echo -e "${GRAY}Sample keywords: ${SPAM_KEYWORDS[0]}, ${SPAM_KEYWORDS[1]}, ${SPAM_KEYWORDS[2]}...${NC}"
            else
                echo -e "${YELLOW}Warning: No keywords loaded from GitHub. Using fallback keywords.${NC}"
                SPAM_KEYWORDS=("BINANCE" "BTC" "CRYPTO" "BITCOIN" "ETHEREUM" "USDT" "WALLET")
                echo -e "${GREEN}Using fallback keywords: ${SPAM_KEYWORDS[*]}${NC}"
            fi
        else
            echo -e "${RED}Failed to download spam keyword list from GitHub.${NC}"
            echo -e "${YELLOW}Using fallback keywords...${NC}"
            SPAM_KEYWORDS=("BINANCE" "BTC" "CRYPTO" "BITCOIN" "ETHEREUM" "USDT" "WALLET")
            echo -e "${GREEN}Using fallback keywords: ${SPAM_KEYWORDS[*]}${NC}"
        fi
    elif [ "$KEYWORD_CHOICE" == "2" ]; then
        echo -e "${YELLOW}Enter keywords separated by commas (e.g., BINANCE,CRYPTO,BITCOIN):${NC}"
        read -p "Keywords: " KEYWORD_INPUT
        if [ -z "$KEYWORD_INPUT" ]; then
            echo -e "${RED}No keywords entered. Exiting.${NC}"
            exit 1
        fi
        IFS=',' read -ra SPAM_KEYWORDS <<< "$KEYWORD_INPUT"
        # Trim whitespace from each keyword
        for i in "${!SPAM_KEYWORDS[@]}"; do
            SPAM_KEYWORDS[$i]=$(echo "${SPAM_KEYWORDS[$i]}" | xargs)
        done
        echo -e "${GREEN}Using custom keywords: ${SPAM_KEYWORDS[*]}${NC}"
    else
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        exit 1
    fi
fi

# Escape special characters for SQL
escape_for_sql() {
    echo "$1" | sed "s/'/''/g"
}

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

        # =====================================
        # USER CLEANUP - WITH EXACT DOMAIN MATCHING
        # =====================================
        if [[ "$CLEANUP_MODE" == "1" || "$CLEANUP_MODE" == "3" ]]; then
            echo -e "${GRAY}  Searching for ${#SPAM_DOMAINS[@]} spam domain(s)...${NC}"

            # CRITICAL FIX: Use SUBSTRING_INDEX to extract exact domain after @
            # This prevents @gmail.com.ph from matching @gmail.com
            
            WHERE_CLAUSE=""
            
            # Build WHERE clause with exact domain matching
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
            
            # Also search in username/login for spam keywords (optional)
            SPAM_USER_KEYWORDS=("BINANCE" "BYBIT" "BTC" "BITCOIN" "CRYPTO" "MINING" "WALLET" "ETHEREUM" "USDT")
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
                echo "$USER_DATA" | while IFS=$'\t' read -r USER_ID USER_LOGIN USER_EMAIL; do
                    # Extract and store domain
                    DOMAIN=$(echo "$USER_EMAIL" | grep -oP '@\K.*')
                    DOMAIN_MAP["$DOMAIN"]=1
                    echo -e "${YELLOW}  - ID: $USER_ID, Login: $USER_LOGIN, Email: $USER_EMAIL${NC}"
                done
                
                read -p "$(echo -e ${RED}Do you want to DELETE these users? Type 'yes' to confirm: ${NC})" CONFIRM
                
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
        fi

        # =====================================
        # COMMENT CLEANUP
        # =====================================
        if [[ "$CLEANUP_MODE" == "2" || "$CLEANUP_MODE" == "3" ]]; then
            echo
            echo -e "${GRAY}  Searching for comments with spam keywords...${NC}"

            # Build SQL WHERE clause for keywords (search in multiple fields)
            declare -A UNIQUE_WORDS
            for keyword in "${SPAM_KEYWORDS[@]}"; do
                # Split phrase into individual words
                IFS=' ' read -ra WORDS <<< "$keyword"
                for word in "${WORDS[@]}"; do
                    # Only add words that are 3+ characters
                    if [ ${#word} -ge 3 ]; then
                        UNIQUE_WORDS["$word"]=1
                    fi
                done
            done
            
            COMMENT_WHERE=""
            for word in "${!UNIQUE_WORDS[@]}"; do
                word_escaped=$(escape_for_sql "$word")
                if [ -z "$COMMENT_WHERE" ]; then
                    COMMENT_WHERE="(comment_content LIKE '%$word_escaped%' OR comment_author LIKE '%$word_escaped%' OR comment_author_email LIKE '%$word_escaped%' OR comment_author_url LIKE '%$word_escaped%')"
                else
                    COMMENT_WHERE="$COMMENT_WHERE OR (comment_content LIKE '%$word_escaped%' OR comment_author LIKE '%$word_escaped%' OR comment_author_email LIKE '%$word_escaped%' OR comment_author_url LIKE '%$word_escaped%')"
                fi
            done
            
            echo -e "${GRAY}  Searching for ${#UNIQUE_WORDS[@]} unique spam keywords...${NC}"

            # Get matching comments BEFORE deletion
            COMMENT_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
            SELECT comment_ID, comment_author, comment_author_email, LEFT(comment_content, 100)
            FROM ${PREFIX}comments
            WHERE $COMMENT_WHERE;
            " 2>/dev/null)

            # Count matching comments
            if [ -z "$COMMENT_DATA" ]; then
                COMMENT_COUNT=0
            else
                COMMENT_COUNT=$(echo "$COMMENT_DATA" | wc -l)
            fi

            if [ "$COMMENT_COUNT" -gt 0 ]; then
                echo -e "${GREEN}Found $COMMENT_COUNT spam comment(s):${NC}"
                
                # Save to log file
                echo "=== Spam Comments Found in $SITE_PATH ===" >> "$COMMENTS_LOG"
                echo "Timestamp: $(date)" >> "$COMMENTS_LOG"
                echo "Database: $DB_NAME" >> "$COMMENTS_LOG"
                echo "" >> "$COMMENTS_LOG"
                
                echo "$COMMENT_DATA" | while IFS=$'\t' read -r COMMENT_ID AUTHOR EMAIL CONTENT; do
                    echo -e "${YELLOW}  - ID: $COMMENT_ID${NC}"
                    echo -e "${GRAY}    Author: $AUTHOR${NC}"
                    echo -e "${GRAY}    Email: $EMAIL${NC}"
                    echo -e "${GRAY}    Content: ${CONTENT:0:80}...${NC}"
                    
                    # Log to file
                    echo "Comment ID: $COMMENT_ID" >> "$COMMENTS_LOG"
                    echo "  Author: $AUTHOR" >> "$COMMENTS_LOG"
                    echo "  Email: $EMAIL" >> "$COMMENTS_LOG"
                    echo "  Content: $CONTENT" >> "$COMMENTS_LOG"
                    echo "" >> "$COMMENTS_LOG"
                done
                
                read -p "$(echo -e ${RED}Do you want to DELETE these comments? Type 'yes' to confirm: ${NC})" CONFIRM_COMMENTS
                
                if [ "$CONFIRM_COMMENTS" == "yes" ]; then
                    # Delete comment meta first, then comments
                    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                    DELETE FROM ${PREFIX}commentmeta
                    WHERE comment_id IN (
                        SELECT comment_ID FROM (SELECT comment_ID FROM ${PREFIX}comments WHERE $COMMENT_WHERE) AS temp
                    );
                    " 2>/dev/null

                    mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                    DELETE FROM ${PREFIX}comments
                    WHERE $COMMENT_WHERE;
                    " 2>/dev/null
                    
                    echo -e "${GREEN}✓ Deleted $COMMENT_COUNT comment(s)${NC}"
                    TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + COMMENT_COUNT))
                else
                    echo -e "${GRAY}Skipped comment deletion${NC}"
                fi
            else
                echo -e "${GRAY}No spam comments found${NC}"
            fi
        fi
        echo
    fi
done

# Write unique spam domains to log files
if [[ "$CLEANUP_MODE" == "1" || "$CLEANUP_MODE" == "3" ]] && [ ${#DOMAIN_MAP[@]} -gt 0 ]; then
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
echo -e "${CYAN}==== Cleanup script finished =============${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

if [ "$TOTAL_DELETED_USERS" -gt 0 ] || [ "$TOTAL_DELETED_COMMENTS" -gt 0 ]; then
    echo -e "${GREEN}Summary:${NC}"
    if [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
        echo -e "${GREEN}  Total users deleted: $TOTAL_DELETED_USERS${NC}"
        echo -e "${GREEN}  Unique spam domains: ${#DOMAIN_MAP[@]}${NC}"
    fi
    if [ "$TOTAL_DELETED_COMMENTS" -gt 0 ]; then
        echo -e "${GREEN}  Total comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    fi
    echo
    
    if [[ "$CLEANUP_MODE" == "1" || "$CLEANUP_MODE" == "3" ]]; then
        echo -e "${YELLOW}Spam domain logs saved to:${NC}"
        echo -e "${CYAN}  TXT:  $DOMAINS_LOG${NC}"
        echo -e "${CYAN}  CSV:  $DOMAINS_CSV${NC}"
        echo -e "${CYAN}  JSON: $DOMAINS_JSON${NC}"
        echo
    fi
    
    if [[ "$CLEANUP_MODE" == "2" || "$CLEANUP_MODE" == "3" ]]; then
        echo -e "${YELLOW}Deleted comments log saved to:${NC}"
        echo -e "${CYAN}  $COMMENTS_LOG${NC}"
        echo
    fi
else
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "${YELLOW}  No items were deleted${NC}"
fi
