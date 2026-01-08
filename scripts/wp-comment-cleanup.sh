#!/bin/bash
# =====================================
# WP Comment & User Cleanup Script (Script 2)
# Purpose: Delete spam comments and their associated users
# Features: 
# - Search comments by keywords in all fields
# - Smart user deletion (only users with ONLY spam comments)
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
COMMENTS_LOG="$LOG_DIR/deleted_comments_$TIMESTAMP.txt"
USERS_LOG="$LOG_DIR/deleted_comment_users_$TIMESTAMP.txt"
SUMMARY_LOG="$LOG_DIR/cleanup_summary_$TIMESTAMP.txt"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress Comment Cleanup (Script 2) =${NC}"
echo -e "${CYAN}==== Spam Comments & User Removal =========${NC}"
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
echo -e "${GREEN}Ready to search for spam comments across all WordPress sites${NC}"
echo -e "${CYAN}  → Total keywords to search: ${#SPAM_KEYWORDS[@]}${NC}"
if [ ${#SPAM_KEYWORDS[@]} -le 5 ]; then
    echo -e "${CYAN}  → Keywords: ${SPAM_KEYWORDS[*]}${NC}"
else
    echo -e "${CYAN}  → Sample keywords: ${SPAM_KEYWORDS[0]}, ${SPAM_KEYWORDS[1]}, ${SPAM_KEYWORDS[2]}...${NC}"
fi
echo
echo -ne "${YELLOW}Do you want to proceed? Type 'yes' to continue: ${NC}"
read PROCEED
if [ "$PROCEED" != "yes" ]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
fi

# =====================================
# SCAN AND DELETE SPAM COMMENTS + USERS
# =====================================
echo
echo -e "${BLUE}Searching all WordPress sites under $BASE_DIR ...${NC}"
echo -e "${GRAY}Log files will be saved to: $LOG_DIR${NC}"
echo

TOTAL_DELETED_COMMENTS=0
TOTAL_DELETED_USERS=0
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
        echo -e "${GRAY}  Searching for spam keywords in comments...${NC}"

        # Build SQL WHERE clause for keywords
        # Search in: comment_content, comment_author, comment_author_email, comment_author_url
        declare -A UNIQUE_WORDS
        for keyword in "${SPAM_KEYWORDS[@]}"; do
            # Split phrase into individual words if needed
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

        # Get matching comments BEFORE deletion
        COMMENT_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT comment_ID, comment_author, comment_author_email, user_id, LEFT(comment_content, 80)
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
            echo -e "${GREEN}Found $COMMENT_COUNT spam comment(s)${NC}"
            
            # Log to file
            echo "=== Spam Comments Found in $SITE_PATH ===" >> "$COMMENTS_LOG"
            echo "Timestamp: $(date)" >> "$COMMENTS_LOG"
            echo "Database: $DB_NAME" >> "$COMMENTS_LOG"
            echo "" >> "$COMMENTS_LOG"
            
            # Store unique user IDs and emails from spam comments
            declare -A SPAM_COMMENT_USER_IDS
            declare -A SPAM_COMMENT_EMAILS
            
            # Display preview (first 5 comments)
            PREVIEW_COUNT=0
            echo "$COMMENT_DATA" | while IFS=$'\t' read -r COMMENT_ID AUTHOR EMAIL USER_ID CONTENT; do
                if [ $PREVIEW_COUNT -lt 5 ]; then
                    echo -e "${YELLOW}  - ID: $COMMENT_ID${NC}"
                    echo -e "${GRAY}    Author: $AUTHOR${NC}"
                    echo -e "${GRAY}    Email: $EMAIL${NC}"
                    echo -e "${GRAY}    User ID: $USER_ID${NC}"
                    echo -e "${GRAY}    Content: ${CONTENT}...${NC}"
                    PREVIEW_COUNT=$((PREVIEW_COUNT + 1))
                fi
                
                # Log all comments
                echo "Comment ID: $COMMENT_ID" >> "$COMMENTS_LOG"
                echo "  Author: $AUTHOR" >> "$COMMENTS_LOG"
                echo "  Email: $EMAIL" >> "$COMMENTS_LOG"
                echo "  User ID: $USER_ID" >> "$COMMENTS_LOG"
                echo "  Content: $CONTENT" >> "$COMMENTS_LOG"
                echo "" >> "$COMMENTS_LOG"
            done
            
            if [ $COMMENT_COUNT -gt 5 ]; then
                echo -e "${GRAY}  ... and $((COMMENT_COUNT - 5)) more (see log file for details)${NC}"
            fi
            
            # Collect user IDs and emails from spam comments
            while IFS=$'\t' read -r COMMENT_ID AUTHOR EMAIL USER_ID CONTENT; do
                if [ -n "$USER_ID" ] && [ "$USER_ID" != "0" ] && [ "$USER_ID" != "NULL" ]; then
                    SPAM_COMMENT_USER_IDS["$USER_ID"]=1
                fi
                if [ -n "$EMAIL" ] && [ "$EMAIL" != "NULL" ]; then
                    SPAM_COMMENT_EMAILS["$EMAIL"]=1
                fi
            done <<< "$COMMENT_DATA"
            
            echo
            echo -ne "${RED}Do you want to DELETE these spam comments? Type 'yes' to confirm: ${NC}"
            read CONFIRM_COMMENTS
            
            if [ "$CONFIRM_COMMENTS" == "yes" ]; then
                # Delete commentmeta first
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}commentmeta
                WHERE comment_id IN (
                    SELECT comment_ID FROM (SELECT comment_ID FROM ${PREFIX}comments WHERE $COMMENT_WHERE) AS temp
                );
                " 2>/dev/null

                # Delete comments
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}comments
                WHERE $COMMENT_WHERE;
                " 2>/dev/null
                
                echo -e "${GREEN}✓ Deleted $COMMENT_COUNT spam comment(s)${NC}"
                TOTAL_DELETED_COMMENTS=$((TOTAL_DELETED_COMMENTS + COMMENT_COUNT))
                
                # =====================================
                # SMART USER DELETION
                # =====================================
                echo
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "${YELLOW}Analyzing users associated with deleted comments...${NC}"
                
                USERS_TO_DELETE=()
                declare -A USER_DETAILS
                
                # Check users by user_id
                if [ ${#SPAM_COMMENT_USER_IDS[@]} -gt 0 ]; then
                    for USER_ID in "${!SPAM_COMMENT_USER_IDS[@]}"; do
                        # Check if user has any remaining comments
                        REMAINING_COMMENTS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                        SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id = $USER_ID;
                        " 2>/dev/null)
                        
                        REMAINING_COMMENTS=${REMAINING_COMMENTS:-0}
                        
                        # If user has no remaining comments, mark for deletion
                        if [ "$REMAINING_COMMENTS" -eq 0 ]; then
                            # Get user details
                            USER_INFO=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                            SELECT ID, user_login, user_email FROM ${PREFIX}users WHERE ID = $USER_ID;
                            " 2>/dev/null)
                            
                            if [ -n "$USER_INFO" ]; then
                                USERS_TO_DELETE+=("$USER_ID")
                                USER_DETAILS["$USER_ID"]="$USER_INFO"
                            fi
                        fi
                    done
                fi
                
                # Check users by email (for non-registered comment authors who later registered)
                if [ ${#SPAM_COMMENT_EMAILS[@]} -gt 0 ]; then
                    for EMAIL in "${!SPAM_COMMENT_EMAILS[@]}"; do
                        EMAIL_ESCAPED=$(escape_for_sql "$EMAIL")
                        
                        # Get user with this email
                        USER_INFO=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                        SELECT ID, user_login, user_email FROM ${PREFIX}users WHERE user_email = '$EMAIL_ESCAPED';
                        " 2>/dev/null)
                        
                        if [ -n "$USER_INFO" ]; then
                            USER_ID=$(echo "$USER_INFO" | cut -f1)
                            
                            # Check if not already in deletion list
                            if [[ ! " ${USERS_TO_DELETE[@]} " =~ " ${USER_ID} " ]]; then
                                # Check if user has any remaining comments
                                REMAINING_COMMENTS=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
                                SELECT COUNT(*) FROM ${PREFIX}comments WHERE user_id = $USER_ID;
                                " 2>/dev/null)
                                
                                REMAINING_COMMENTS=${REMAINING_COMMENTS:-0}
                                
                                # If user has no remaining comments, mark for deletion
                                if [ "$REMAINING_COMMENTS" -eq 0 ]; then
                                    USERS_TO_DELETE+=("$USER_ID")
                                    USER_DETAILS["$USER_ID"]="$USER_INFO"
                                fi
                            fi
                        fi
                    done
                fi
                
                # Display users found for deletion
                if [ ${#USERS_TO_DELETE[@]} -gt 0 ]; then
                    echo -e "${GREEN}Found ${#USERS_TO_DELETE[@]} user(s) with ONLY spam comments (safe to delete):${NC}"
                    
                    # Log to file
                    echo "=== Users with Only Spam Comments in $SITE_PATH ===" >> "$USERS_LOG"
                    echo "Timestamp: $(date)" >> "$USERS_LOG"
                    echo "Database: $DB_NAME" >> "$USERS_LOG"
                    echo "" >> "$USERS_LOG"
                    
                    for USER_ID in "${USERS_TO_DELETE[@]}"; do
                        USER_INFO="${USER_DETAILS[$USER_ID]}"
                        USER_LOGIN=$(echo "$USER_INFO" | cut -f2)
                        USER_EMAIL=$(echo "$USER_INFO" | cut -f3)
                        
                        echo -e "${YELLOW}  - ID: $USER_ID, Login: $USER_LOGIN, Email: $USER_EMAIL${NC}"
                        
                        # Log to file
                        echo "User ID: $USER_ID" >> "$USERS_LOG"
                        echo "  Login: $USER_LOGIN" >> "$USERS_LOG"
                        echo "  Email: $USER_EMAIL" >> "$USERS_LOG"
                        echo "  Reason: All comments were spam (0 legitimate comments remaining)" >> "$USERS_LOG"
                        echo "" >> "$USERS_LOG"
                    done
                    
                    echo
                    echo -e "${GRAY}These users have NO legitimate comments remaining.${NC}"
                    echo -ne "${RED}Do you want to DELETE these users? Type 'yes' to confirm: ${NC}"
                    read CONFIRM_USERS
                    
                    if [ "$CONFIRM_USERS" == "yes" ]; then
                        # Convert array to comma-separated list
                        USER_IDS_LIST=$(IFS=,; echo "${USERS_TO_DELETE[*]}")
                        
                        # Delete usermeta
                        mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                        DELETE FROM ${PREFIX}usermeta WHERE user_id IN ($USER_IDS_LIST);
                        " 2>/dev/null

                        # Delete users
                        mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                        DELETE FROM ${PREFIX}users WHERE ID IN ($USER_IDS_LIST);
                        " 2>/dev/null
                        
                        echo -e "${GREEN}✓ Deleted ${#USERS_TO_DELETE[@]} user(s) with only spam comments${NC}"
                        TOTAL_DELETED_USERS=$((TOTAL_DELETED_USERS + ${#USERS_TO_DELETE[@]}))
                    else
                        echo -e "${GRAY}Skipped user deletion${NC}"
                    fi
                else
                    echo -e "${GRAY}No users found with ONLY spam comments${NC}"
                    echo -e "${GRAY}(Users with legitimate comments were preserved)${NC}"
                fi
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            else
                echo -e "${GRAY}Skipped comment deletion${NC}"
            fi
        else
            echo -e "${GRAY}No spam comments found${NC}"
        fi
        
        TOTAL_SITES_PROCESSED=$((TOTAL_SITES_PROCESSED + 1))
        echo
    fi
done

# =====================================
# FINAL SUMMARY
# =====================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Comment Cleanup Script Finished ======${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# Create summary
SUMMARY="WordPress Comment & User Cleanup Summary
========================================
Timestamp: $(date)
Sites Processed: $TOTAL_SITES_PROCESSED
Keywords Used: ${#SPAM_KEYWORDS[@]}

Results:
- Total comments deleted: $TOTAL_DELETED_COMMENTS
- Total users deleted: $TOTAL_DELETED_USERS

Log Files:
- Comments: $COMMENTS_LOG
- Users: $USERS_LOG
- Summary: $SUMMARY_LOG
"

echo "$SUMMARY" > "$SUMMARY_LOG"

if [ "$TOTAL_DELETED_COMMENTS" -gt 0 ] || [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
    echo -e "${GREEN}Summary:${NC}"
    echo -e "${GREEN}  Sites processed: $TOTAL_SITES_PROCESSED${NC}"
    echo -e "${GREEN}  Total comments deleted: $TOTAL_DELETED_COMMENTS${NC}"
    echo -e "${GREEN}  Total users deleted: $TOTAL_DELETED_USERS${NC}"
    echo
    
    echo -e "${YELLOW}Logs saved to:${NC}"
    echo -e "${CYAN}  Comments Log: $COMMENTS_LOG${NC}"
    if [ "$TOTAL_DELETED_USERS" -gt 0 ]; then
        echo -e "${CYAN}  Users Log: $USERS_LOG${NC}"
    fi
    echo -e "${CYAN}  Summary: $SUMMARY_LOG${NC}"
else
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "${YELLOW}  Sites processed: $TOTAL_SITES_PROCESSED${NC}"
    echo -e "${YELLOW}  No items were deleted${NC}"
fi

echo
echo -e "${CYAN}Thank you for using WordPress Comment Cleanup Script!${NC}"
