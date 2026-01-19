#!/bin/bash
# =====================================
# WP Link Comment Cleanup Script
# Purpose: Delete comments containing links and their associated users
# Features: 
# - Detect links in comment content, author name, author email, and author URL
# - Smart user deletion (only users with ONLY link-spam comments)
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
COMMENTS_LOG="$LOG_DIR/deleted_link_comments_$TIMESTAMP.txt"
USERS_LOG="$LOG_DIR/deleted_link_users_$TIMESTAMP.txt"
SUMMARY_LOG="$LOG_DIR/link_cleanup_summary_$TIMESTAMP.txt"

echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== WordPress Link Comment Cleanup ========${NC}"
echo -e "${CYAN}==== Remove Comments with Links ============${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# =====================================
# CONFIGURATION
# =====================================
echo -e "${YELLOW}Link Detection Configuration:${NC}"
echo -e "${WHITE}This script will detect and remove comments containing:${NC}"
echo -e "${GRAY}  • HTTP/HTTPS links in comment content${NC}"
echo -e "${GRAY}  • HTML anchor tags (<a href=...)${NC}"
echo -e "${GRAY}  • Markdown-style links${NC}"
echo -e "${GRAY}  • URLs in author name${NC}"
echo -e "${GRAY}  • Suspicious author URLs (non-empty values)${NC}"
echo -e "${GRAY}  • Email addresses with link patterns${NC}"
echo

echo -e "${YELLOW}Choose detection mode:${NC}"
echo -e "${WHITE}  1) Strict - Remove ALL comments with any links (recommended)${NC}"
echo -e "${WHITE}  2) Moderate - Keep comments from registered users (user_id > 0)${NC}"
echo -e "${WHITE}  3) Custom - Specify exclusions${NC}"
echo -ne "${YELLOW}Enter choice 1, 2, or 3: ${NC}"
read DETECTION_MODE

EXCLUDE_REGISTERED=false
EXCLUDE_APPROVED=false

if [ "$DETECTION_MODE" == "2" ]; then
    EXCLUDE_REGISTERED=true
    echo -e "${GREEN}Mode: Moderate - Will preserve comments from registered users${NC}"
elif [ "$DETECTION_MODE" == "3" ]; then
    echo -ne "${YELLOW}Exclude registered users (user_id > 0)? (yes/no): ${NC}"
    read EXCL_REG
    if [ "$EXCL_REG" == "yes" ]; then
        EXCLUDE_REGISTERED=true
    fi
    
    echo -ne "${YELLOW}Exclude approved comments? (yes/no): ${NC}"
    read EXCL_APP
    if [ "$EXCL_APP" == "yes" ]; then
        EXCLUDE_APPROVED=true
    fi
    echo -e "${GREEN}Custom mode configured${NC}"
elif [ "$DETECTION_MODE" == "1" ]; then
    echo -e "${GREEN}Mode: Strict - Will remove ALL comments containing links${NC}"
else
    echo -e "${RED}Invalid choice. Exiting.${NC}"
    exit 1
fi

echo
echo -e "${GREEN}Ready to scan for link-containing comments across all WordPress sites${NC}"
echo -e "${CYAN}  → Detection mode: $([ "$DETECTION_MODE" == "1" ] && echo "Strict" || ([ "$DETECTION_MODE" == "2" ] && echo "Moderate" || echo "Custom"))${NC}"
echo -e "${CYAN}  → Exclude registered users: $([ "$EXCLUDE_REGISTERED" == true ] && echo "Yes" || echo "No")${NC}"
echo -e "${CYAN}  → Exclude approved comments: $([ "$EXCLUDE_APPROVED" == true ] && echo "Yes" || echo "No")${NC}"
echo
echo -ne "${YELLOW}Do you want to proceed? Type 'yes' to continue: ${NC}"
read PROCEED
if [ "$PROCEED" != "yes" ]; then
    echo -e "${RED}Aborted by user.${NC}"
    exit 1
fi

# =====================================
# SCAN AND DELETE LINK COMMENTS + USERS
# =====================================
echo
echo -e "${BLUE}Scanning all WordPress sites under $BASE_DIR ...${NC}"
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
        echo -e "${GRAY}  Searching for comments with links...${NC}"

        # Build SQL WHERE clause for link detection
        # Detect various link patterns:
        # 1. http:// or https:// in comment_content
        # 2. <a href in comment_content (HTML links)
        # 3. [url] or [link] markdown-style
        # 4. Non-empty comment_author_url (spam indicator)
        # 5. Links in comment_author
        
        LINK_WHERE="(
            comment_content LIKE '%http://%' OR 
            comment_content LIKE '%https://%' OR 
            comment_content LIKE '%<a href%' OR 
            comment_content LIKE '%[url%' OR 
            comment_content LIKE '%[link%' OR
            comment_author LIKE '%http://%' OR 
            comment_author LIKE '%https://%' OR
            comment_author LIKE '%.com%' OR
            comment_author LIKE '%.net%' OR
            comment_author LIKE '%.org%' OR
            (comment_author_url IS NOT NULL AND comment_author_url != '' AND comment_author_url != 'http://' AND comment_author_url != 'https://')
        )"

        # Add exclusions if specified
        if [ "$EXCLUDE_REGISTERED" == true ]; then
            LINK_WHERE="$LINK_WHERE AND (user_id = 0 OR user_id IS NULL)"
        fi
        
        if [ "$EXCLUDE_APPROVED" == true ]; then
            LINK_WHERE="$LINK_WHERE AND comment_approved != '1'"
        fi

        # Get matching comments BEFORE deletion
        COMMENT_DATA=$(mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -sN -e "
        SELECT 
            comment_ID, 
            comment_author, 
            comment_author_email, 
            comment_author_url,
            user_id, 
            comment_approved,
            LEFT(comment_content, 100) as content_preview
        FROM ${PREFIX}comments
        WHERE $LINK_WHERE
        ORDER BY comment_ID;
        " 2>/dev/null)

        # Count matching comments
        if [ -z "$COMMENT_DATA" ]; then
            COMMENT_COUNT=0
        else
            COMMENT_COUNT=$(echo "$COMMENT_DATA" | wc -l)
        fi

        if [ "$COMMENT_COUNT" -gt 0 ]; then
            echo -e "${GREEN}Found $COMMENT_COUNT comment(s) with links${NC}"
            
            # Log to file
            echo "=== Link Comments Found in $SITE_PATH ===" >> "$COMMENTS_LOG"
            echo "Timestamp: $(date)" >> "$COMMENTS_LOG"
            echo "Database: $DB_NAME" >> "$COMMENTS_LOG"
            echo "" >> "$COMMENTS_LOG"
            
            # Store unique user IDs and emails from link comments
            declare -A LINK_COMMENT_USER_IDS
            declare -A LINK_COMMENT_EMAILS
            
            # Display preview (first 5 comments)
            PREVIEW_COUNT=0
            echo "$COMMENT_DATA" | while IFS=$'\t' read -r COMMENT_ID AUTHOR EMAIL AUTHOR_URL USER_ID APPROVED CONTENT; do
                if [ $PREVIEW_COUNT -lt 5 ]; then
                    echo -e "${YELLOW}  - ID: $COMMENT_ID${NC}"
                    echo -e "${GRAY}    Author: $AUTHOR${NC}"
                    echo -e "${GRAY}    Email: $EMAIL${NC}"
                    echo -e "${GRAY}    Author URL: $AUTHOR_URL${NC}"
                    echo -e "${GRAY}    User ID: $USER_ID | Status: $([ "$APPROVED" == "1" ] && echo "Approved" || echo "Pending/Spam")${NC}"
                    echo -e "${GRAY}    Content: ${CONTENT}...${NC}"
                    PREVIEW_COUNT=$((PREVIEW_COUNT + 1))
                fi
                
                # Log all comments
                echo "Comment ID: $COMMENT_ID" >> "$COMMENTS_LOG"
                echo "  Author: $AUTHOR" >> "$COMMENTS_LOG"
                echo "  Email: $EMAIL" >> "$COMMENTS_LOG"
                echo "  Author URL: $AUTHOR_URL" >> "$COMMENTS_LOG"
                echo "  User ID: $USER_ID" >> "$COMMENTS_LOG"
                echo "  Status: $APPROVED" >> "$COMMENTS_LOG"
                echo "  Content: $CONTENT" >> "$COMMENTS_LOG"
                echo "" >> "$COMMENTS_LOG"
            done
            
            if [ $COMMENT_COUNT -gt 5 ]; then
                echo -e "${GRAY}  ... and $((COMMENT_COUNT - 5)) more (see log file for details)${NC}"
            fi
            
            # Collect user IDs and emails from link comments
            while IFS=$'\t' read -r COMMENT_ID AUTHOR EMAIL AUTHOR_URL USER_ID APPROVED CONTENT; do
                if [ -n "$USER_ID" ] && [ "$USER_ID" != "0" ] && [ "$USER_ID" != "NULL" ]; then
                    LINK_COMMENT_USER_IDS["$USER_ID"]=1
                fi
                if [ -n "$EMAIL" ] && [ "$EMAIL" != "NULL" ]; then
                    LINK_COMMENT_EMAILS["$EMAIL"]=1
                fi
            done <<< "$COMMENT_DATA"
            
            echo
            echo -ne "${RED}Do you want to DELETE these link-containing comments? Type 'yes' to confirm: ${NC}"
            read CONFIRM_COMMENTS
            
            if [ "$CONFIRM_COMMENTS" == "yes" ]; then
                # Delete commentmeta first
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}commentmeta
                WHERE comment_id IN (
                    SELECT comment_ID FROM (
                        SELECT comment_ID FROM ${PREFIX}comments WHERE $LINK_WHERE
                    ) AS temp
                );
                " 2>/dev/null

                # Delete comments
                mysql -h "$DB_HOST" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
                DELETE FROM ${PREFIX}comments
                WHERE $LINK_WHERE;
                " 2>/dev/null
                
                echo -e "${GREEN}✓ Deleted $COMMENT_COUNT link-containing comment(s)${NC}"
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
                if [ ${#LINK_COMMENT_USER_IDS[@]} -gt 0 ]; then
                    for USER_ID in "${!LINK_COMMENT_USER_IDS[@]}"; do
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
                if [ ${#LINK_COMMENT_EMAILS[@]} -gt 0 ]; then
                    for EMAIL in "${!LINK_COMMENT_EMAILS[@]}"; do
                        EMAIL_ESCAPED=$(echo "$EMAIL" | sed "s/'/''/g")
                        
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
                    echo -e "${GREEN}Found ${#USERS_TO_DELETE[@]} user(s) with ONLY link-spam comments (safe to delete):${NC}"
                    
                    # Log to file
                    echo "=== Users with Only Link-Spam Comments in $SITE_PATH ===" >> "$USERS_LOG"
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
                        echo "  Reason: All comments contained links (0 legitimate comments remaining)" >> "$USERS_LOG"
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
                        
                        echo -e "${GREEN}✓ Deleted ${#USERS_TO_DELETE[@]} user(s) with only link-spam comments${NC}"
                        TOTAL_DELETED_USERS=$((TOTAL_DELETED_USERS + ${#USERS_TO_DELETE[@]}))
                    else
                        echo -e "${GRAY}Skipped user deletion${NC}"
                    fi
                else
                    echo -e "${GRAY}No users found with ONLY link-spam comments${NC}"
                    echo -e "${GRAY}(Users with legitimate comments were preserved)${NC}"
                fi
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            else
                echo -e "${GRAY}Skipped comment deletion${NC}"
            fi
        else
            echo -e "${GRAY}No link-containing comments found${NC}"
        fi
        
        TOTAL_SITES_PROCESSED=$((TOTAL_SITES_PROCESSED + 1))
        echo
    fi
done

# =====================================
# FINAL SUMMARY
# =====================================
echo -e "${CYAN}=============================================${NC}"
echo -e "${CYAN}==== Link Cleanup Script Finished ==========${NC}"
echo -e "${CYAN}=============================================${NC}"
echo

# Create summary
SUMMARY="WordPress Link Comment Cleanup Summary
========================================
Timestamp: $(date)
Sites Processed: $TOTAL_SITES_PROCESSED
Detection Mode: $([ "$DETECTION_MODE" == "1" ] && echo "Strict" || ([ "$DETECTION_MODE" == "2" ] && echo "Moderate" || echo "Custom"))
Excluded Registered Users: $([ "$EXCLUDE_REGISTERED" == true ] && echo "Yes" || echo "No")
Excluded Approved Comments: $([ "$EXCLUDE_APPROVED" == true ] && echo "Yes" || echo "No")

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
echo -e "${CYAN}Thank you for using WordPress Link Comment Cleanup Script!${NC}"
