#!/bin/bash
# =====================================
# WP User Keyword Cleanup Script (Script 4)
# Purpose: Delete users with spam keywords in account info
# Features: 
# - Search keywords in username, email, display name, etc.
# - Uses GitHub spam keywords list
# - Comprehensive logging
# - Safe deletion with confirmation
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
USERS_LOG="$LOG_DIR/deleted_keyword_users_$TIMESTAMP.txt"
SUMMARY_LOG="$LOG_DIR/keyword_cleanup_summary_$TIMESTAMP.txt"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress User Keyword Cleanup =======
${NC}"
echo -e "${CYAN}==== Remove Users with Spam Keywords ======${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# Escape special characters for SQL
escape_for_sql() {
    echo "$1" | sed "s/'/''/g"
}

# =====================================
# SPAM KEYWORD INPUT
# =====================================
echo -e "${YELLOW}Choose input method for spam keywords:${NC}"
echo -e "${WHITE}  1) Fetch spam keyword list from GitHub (recommended)${NC}"
echo -e "${WHITE}  2) Enter custom keywords manually${NC}"
echo -ne "${YELLOW}Enter choice 1 or 2: ${NC}"
read KEYWORD_CHOICE

SPAM_KEYWORDS=()

if [ "$KEYWORD_CHOICE" == "1" ]; then
    echo -e "${BLUE}Fetching spam keyword list from GitHub...${NC}"
    GITHUB_KEYWORDS_URL="https://raw.githubusercontent.com/M-Saadawy/WordPress-spam-user-list/main/comments.txt"
    
    # Download the keywords list
    TEMP_KEYWORDS_FILE=$(mktemp)
    if curl -s -f "$GITHUB_KEYWORDS_URL" -o "$TEMP_KEYWORDS_FILE" 2>/dev/null && [ -s "$TEMP_KEYWORDS_FILE" ]; then
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
            if [ ${#SPAM_KEYWORDS[@]} -le 5 ]; then
                echo -e "${GRAY}Keywords: ${SPAM_KEYWORDS[*]}${NC}"
            else
                echo -e "${GRAY}Sample keywords: ${SPAM_KEYWORDS[0]}, ${SPAM_KEYWORDS[1]}, ${SPAM_KEYWORDS[2]}...${NC}"
            fi
        else
            echo -e "${RED}ERROR: No keywords loaded from GitHub.${NC}"
            exit 1
        fi
    else
        echo -e "${RED}Failed to download spam keyword list from GitHub.${NC}"
        echo -e "${YELLOW}Falling back to manual entry...${NC}"
        echo -ne "${YELLOW}Enter keywords separated by commas (e.g., BINANCE,CRYPTO,BITCOIN): ${NC}"
        read KEYWORD_INPUT
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
    fi
elif [ "$KEYWORD_CHOICE" == "2" ]; then
    echo -ne "${YELLOW}Enter keywords separated by commas (e.g., BINANCE,CRYPTO,BITCOIN): ${NC}"
    read KEYWORD_INPUT
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

# Verify we have keywords
if [ ${#SPAM_KEYWORDS[@]} -eq 0 ]; then
    echo -e "${RED}No keywords to search for. Exiting.${NC}"
    exit 1
fi

# Show summary before proceeding
echo
echo -e "${GREEN}Ready to search for spam keywords in user accounts${NC}"
echo -e "${CYAN}  → Total keywords to search: ${#SPAM_KEYWORDS[@]}${NC}"
if [ ${#SPAM_KEYWORDS[@]} -le 5 ]; then
    echo -e "${CYAN}  → Keywords: ${SPAM_KEYWORDS[*]}${NC}"
else
    echo -e "${CYAN}  → Sample keywords: ${SPAM_KEYWORDS[0]}, ${SPAM_KEYWORDS[1]}, ${SPAM_KEYWORDS[2]}...${NC}"
fi
echo
echo -e "${YELLOW}Will search in:${NC}"
echo -e "${GRAY}  - Username (user_login)${NC}"
echo -e "${GRAY}  - Email address (user_email)${NC}"
echo -e "${GRAY}  - Display name (display_name)${NC}"
echo -e "${GRAY}  - Nickname (user metadata)${NC}"
echo -e "${GRAY}  - First name (user metadata)${NC}"
echo -e "${GRAY}  - Last name (user metadata)${NC}"
echo
echo -e "${GREEN}SAFETY: Only subscribers and contributors will be deleted.${NC}"
echo -e "${GREEN}Administrators, editors, and authors are protected.${NC}"
echo
echo -ne "${YELLOW}Do you want to proceed? Type 'yes' to continue: ${NC}"
read PROCEED
if [ "$PROCEED" != "yes" ]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
fi

# =====================================
# SCAN AND DELETE USERS WITH KEYWORDS
# =====================================
echo
echo -e "${BLUE}Searching all WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log files will be saved to: $LOG_DIR${NC}"
echo

TOTAL_DELETED_USERS=0
TOTAL_DELETED_COMMENTS=0
TOTAL_SITES_PROCESSED=0

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
        echo -e "${GRAY}  Searching for spam keywords in user accounts...${NC}"

        # Build SQL WHERE clause for keywords
        # Search in: user_login, user_email, display_name, and user meta (nickname, first_name, last_name)
        # IMPORTANT: Match EXACT keywords/phrases, not individual words
        
        # Build WHERE clause for users table - exact phrase matching
        USER_WHERE=""
        for keyword in "${SPAM_KEYWORDS[@]}"; do
            keyword_escaped=$(escape_for_sql "$keyword")
            if [ -z "$USER_WHERE" ]; then
                USER_WHERE="(user_login LIKE '%$keyword_escaped%' OR user_email LIKE '%$keyword_escaped%' OR display_name LIKE '%$keyword_escaped%')"
            else
                USER_WHERE="$USER_WHERE OR (user_login LIKE '%$keyword_escaped%' OR user_email LIKE '%$keyword_escaped%' OR display_name LIKE '%$keyword_escaped%')"
            fi
        done

        # CRITICAL SAFETY CHECK: Get matching users BUT ONLY if they are subscribers or contributors
        # This protects administrators, editors, and authors
        USER_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT u.ID, u.user_login, u.user_email, u.display_name, u.user_registered
        FROM ${PREFIX}users u
        INNER JOIN ${PREFIX}usermeta um ON u.ID = um.user_id
        WHERE ($USER_WHERE)
        AND um.meta_key = '${PREFIX}capabilities'
        AND (um.meta_value LIKE '%subscriber%' OR um.meta_value LIKE '%contributor%')
        AND um.meta_value NOT LIKE '%administrator%'
        AND um.meta_value NOT LIKE '%editor%'
        AND um.meta_value NOT LIKE '%author%';
        " 2>/dev/null)

        # Also check usermeta for nickname, first_name, last_name
        # CRITICAL SAFETY: Only for subscribers and contributors
        # EXACT phrase matching
        META_WHERE=""
        for keyword in "${SPAM_KEYWORDS[@]}"; do
            keyword_escaped=$(escape_for_sql "$keyword")
            if [ -z "$META_WHERE" ]; then
                META_WHERE="(meta_value LIKE '%$keyword_escaped%' AND (meta_key = 'nickname' OR meta_key = 'first_name' OR meta_key = 'last_name'))"
            else
                META_WHERE="$META_WHERE OR (meta_value LIKE '%$keyword_escaped%' AND (meta_key = 'nickname' OR meta_key = 'first_name' OR meta_key = 'last_name'))"
            fi
        done

        # Get user IDs from usermeta, but only subscribers and contributors
        META_USER_IDS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT DISTINCT um1.user_id
        FROM ${PREFIX}usermeta um1
        INNER JOIN ${PREFIX}usermeta um2 ON um1.user_id = um2.user_id
        WHERE ($META_WHERE)
        AND um2.meta_key = '${PREFIX}capabilities'
        AND (um2.meta_value LIKE '%subscriber%' OR um2.meta_value LIKE '%contributor%')
        AND um2.meta_value NOT LIKE '%administrator%'
        AND um2.meta_value NOT LIKE '%editor%'
        AND um2.meta_value NOT LIKE '%author%';
        " 2>/dev/null)

        # Get full details for users found in meta
        if [ -n "$META_USER_IDS" ]; then
            META_USER_IDS_LIST=$(echo "$META_USER_IDS" | tr '\n' ',' | sed 's/,$//')
            META_USER_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
            SELECT ID, user_login, user_email, display_name, user_registered
            FROM ${PREFIX}users
            WHERE ID IN ($META_USER_IDS_LIST);
            " 2>/dev/null)
            
            # Combine results (remove duplicates)
            if [ -n "$USER_DATA" ] && [ -n "$META_USER_DATA" ]; then
                ALL_USER_DATA=$(echo -e "$USER_DATA\n$META_USER_DATA" | sort -u)
            elif [ -n "$META_USER_DATA" ]; then
                ALL_USER_DATA="$META_USER_DATA"
            else
                ALL_USER_DATA="$USER_DATA"
            fi
        else
            ALL_USER_DATA="$USER_DATA"
        fi

        # Count matching users
        if [ -z "$ALL_USER_DATA" ]; then
            USER_COUNT=0
        else
            USER_COUNT=$(echo "$ALL_USER_DATA" | wc -l)
        fi

        if [ "$USER_COUNT" -gt 0 ]; then
            echo -e "${GREEN}Found $USER_COUNT subscriber(s)/contributor(s) with spam keywords:${NC}"
            
            # Log to file
            echo "=== Spam Keyword Subscribers/Contributors Found in $SITE_PATH ===" >> "$USERS_LOG"
            echo "Timestamp: $(date)" >> "$USERS_LOG"
            echo "Database: $DB_NAME" >> "$USERS_LOG"
            echo "" >> "$USERS_LOG"
            
            # Display preview (first 10 users) and log all
            PREVIEW_COUNT=0
            while IFS=$'\t' read -r USER_ID USER_LOGIN USER_EMAIL DISPLAY_NAME USER_REGISTERED; do
                # Get user role
                USER_ROLE=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                SELECT meta_value FROM ${PREFIX}usermeta 
                WHERE user_id = $USER_ID AND meta_key = '${PREFIX}capabilities' LIMIT 1;
                " 2>/dev/null)
                
                # Extract role from capabilities
                if [[ "$USER_ROLE" =~ "subscriber" ]]; then
                    ROLE_NAME="subscriber"
                elif [[ "$USER_ROLE" =~ "contributor" ]]; then
                    ROLE_NAME="contributor"
                else
                    ROLE_NAME="unknown"
                fi
                
                # Get matching keywords for this user (exact phrase matching)
                MATCHED_KEYWORDS=""
                for keyword in "${SPAM_KEYWORDS[@]}"; do
                    if [[ "$USER_LOGIN" =~ $keyword ]] || [[ "$USER_EMAIL" =~ $keyword ]] || [[ "$DISPLAY_NAME" =~ $keyword ]]; then
                        if [ -z "$MATCHED_KEYWORDS" ]; then
                            MATCHED_KEYWORDS="$keyword"
                        else
                            MATCHED_KEYWORDS="$MATCHED_KEYWORDS, $keyword"
                        fi
                    fi
                done
                
                # Check usermeta too (exact phrase matching)
                USER_META=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                SELECT meta_key, meta_value
                FROM ${PREFIX}usermeta
                WHERE user_id = $USER_ID AND (meta_key = 'nickname' OR meta_key = 'first_name' OR meta_key = 'last_name');
                " 2>/dev/null)
                
                META_INFO=""
                if [ -n "$USER_META" ]; then
                    while IFS=$'\t' read -r META_KEY META_VALUE; do
                        for keyword in "${SPAM_KEYWORDS[@]}"; do
                            if [[ "$META_VALUE" =~ $keyword ]]; then
                                if [[ ! "$MATCHED_KEYWORDS" =~ "$keyword" ]]; then
                                    if [ -z "$MATCHED_KEYWORDS" ]; then
                                        MATCHED_KEYWORDS="$keyword"
                                    else
                                        MATCHED_KEYWORDS="$MATCHED_KEYWORDS, $keyword"
                                    fi
                                fi
                                META_INFO="$META_INFO, $META_KEY: $META_VALUE"
                            fi
                        done
                    done <<< "$USER_META"
                fi
                
                if [ $PREVIEW_COUNT -lt 10 ]; then
                    echo -e "${YELLOW}  - ID: $USER_ID${NC}"
                    echo -e "${GRAY}    Login: $USER_LOGIN${NC}"
                    echo -e "${GRAY}    Email: $USER_EMAIL${NC}"
                    echo -e "${GRAY}    Display Name: $DISPLAY_NAME${NC}"
                    echo -e "${GRAY}    Role: $ROLE_NAME${NC}"
                    echo -e "${GRAY}    Registered: $USER_REGISTERED${NC}"
                    echo -e "${GRAY}    Matched Keywords: $MATCHED_KEYWORDS${NC}"
                    if [ -n "$META_INFO" ]; then
                        echo -e "${GRAY}    Meta: ${META_INFO:2}${NC}"
                    fi
                    PREVIEW_COUNT=$((PREVIEW_COUNT + 1))
                fi
                
                # Log to file
                echo "User ID: $USER_ID" >> "$USERS_LOG"
                echo "  Login: $USER_LOGIN" >> "$USERS_LOG"
                echo "  Email: $USER_EMAIL" >> "$USERS_LOG"
                echo "  Display Name: $DISPLAY_NAME" >> "$USERS_LOG"
                echo "  Role: $ROLE_NAME" >> "$USERS_LOG"
                echo "  Registered: $USER_REGISTERED" >> "$USERS_LOG"
                echo "  Matched Keywords: $MATCHED_KEYWORDS" >> "$USERS_LOG"
                if [ -n "$META_INFO" ]; then
                    echo "  Meta: ${META_INFO:2}" >> "$USERS_LOG"
                fi
                echo "" >> "$USERS_LOG"
            done <<< "$ALL_USER_DATA"
            
            if [ $USER_COUNT -gt 10 ]; then
                echo -e "${GRAY}  ... and $((USER_COUNT - 10)) more (see log file for details)${NC}"
            fi
            
            echo
            echo -ne "${RED}Do you want to DELETE these users? Type 'yes' to confirm: ${NC}"
            read CONFIRM
            
            if [ "$CONFIRM" == "yes" ]; then
                # Get user IDs for deletion
                USER_IDS=$(echo "$ALL_USER_DATA" | cut -f1 | tr '\n' ',' | sed 's/,$//')
                
                # Count comments by these users
                COMMENT_COUNT_BY_USERS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id IN ($USER_IDS);
                " 2>/dev/null)
                
                # Default to 0 if query returns empty/null
                COMMENT_COUNT_BY_USERS=${COMMENT_COUNT_BY_USERS:-0}
                
                if [ "$COMMENT_COUNT_BY_USERS" -gt 0 ]; then
                    echo -e "${YELLOW}  → These users have $COMMENT_COUNT_BY_USERS comment(s) that will also be deleted${NC}"
                fi
                
                # Perform deletion - safe order: commentmeta → comments → usermeta → users
                
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
                DELETE FROM ${PREFIX}usermeta WHERE user_id IN ($USER_IDS);
                " 2>/dev/null

                # Delete users
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}users WHERE ID IN ($USER_IDS);
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
            echo -e "${GRAY}No subscribers/contributors with spam keywords found${NC}"
            echo -e "${GRAY}(Administrators, editors, authors protected)${NC}"
        fi
        
        TOTAL_SITES_PROCESSED=$((TOTAL_SITES_PROCESSED + 1))
        echo
    fi
done

# =====================================
# FINAL SUMMARY
# =====================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== User Keyword Cleanup Finished ========${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# Create summary
SUMMARY="WordPress User Keyword Cleanup Summary
========================================
Timestamp: $(date)
Sites Processed: $TOTAL_SITES_PROCESSED
Keywords Used: ${#SPAM_KEYWORDS[@]}

Results:
- Total users deleted: $TOTAL_DELETED_USERS
- Total comments deleted: $TOTAL_DELETED_COMMENTS

Log Files:
- Users: $USERS_LOG
- Summary: $SUMMARY_LOG
"

echo "$SUMMARY" > "$SUMMARY_LOG"

if [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
    echo -e "${GREEN}Summary:${NC}"
    echo -e "${GREEN}  Sites processed: $TOTAL_SITES_PROCESSED${NC}"
    echo -e "${GREEN}  Total users deleted: $TOTAL_DELETED_USERS${NC}"
    echo -e "${GREEN}  Total comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo
    
    echo -e "${YELLOW}Logs saved to:${NC}"
    echo -e "${CYAN}  Users Log: $USERS_LOG${NC}"
    echo -e "${CYAN}  Summary: $SUMMARY_LOG${NC}"
else
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "${YELLOW}  Sites processed: $TOTAL_SITES_PROCESSED${NC}"
    echo -e "${YELLOW}  No users were deleted${NC}"
fi

echo
echo -e "${CYAN}Thank you for using WordPress User Keyword Cleanup Script!${NC}"
