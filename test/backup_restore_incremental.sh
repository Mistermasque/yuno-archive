#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && cd .. && pwd)"
YUNO_ARCHIVE="${ROOT_DIR}/yuno-archive.sh"

init() {
    TMP_DIR=$(mktemp --directory)
    SOURCE_DIR="$TMP_DIR/source"
    mkdir -p "$SOURCE_DIR/rep"
    # Create initial files in source directory
    echo "File 1 content" >"$SOURCE_DIR/file 1.txt"
    echo "File 2 content" >"$SOURCE_DIR/rep/file2.txt"
    echo "File 3 content" >"$SOURCE_DIR/rep/file3.txt"
}

cleanup() {
    rm -rf "$TMP_DIR"
}

error_msg() {
    local msg="$1"
    local prefix="❌"
    local color="\e[31m" # Red color
    local reset="\e[0m"
    echo -e "${prefix} ${color}${msg}${reset}"
}

success_msg() {
    local msg="$1"
    local prefix="✅"
    local color="\e[32m" # Green color
    local reset="\e[0m"
    echo -e "${prefix} ${color}${msg}${reset}"
}

test_cmd() {
    echo "Execute command: $*"

    if ! "$@"; then
        error_msg "Command failed: $*"
        cleanup
        exit 1
    fi
}

test_values() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "$expected" != "$actual" ]]; then
        error_msg "Test failed for $description:\n"
        echo "Expected: $expected"
        echo "Got: $actual"
        cleanup
        exit 1
    else
        success_msg "Test passed for $description"
    fi
}

backup_tests() {
    local method="$1"
    local repository="$2"

    local method_opts=()
    case "$method" in
    local)
        method_opts=(local --repository="$repository")
        ;;
    rclone)
        method_opts=(rclone --repository="$repository" --path="tests backup restore")
        ;;
    drive)
        method_opts=(drive --drive="$repository" --repository="tests backup restore")
        ;;
    ssh)
        method_opts=(ssh --repository="$repository")
        ;;
    *)
        error_msg "Unknown method: $method"
        cleanup
        exit 1
        ;;
    esac

    # Create first backup
    echo -e "\n------- Creating initial backup...\n"
    test_cmd $YUNO_ARCHIVE backup "${method_opts[@]}" --source="$SOURCE_DIR" --name="test ${method} backup" --incremental --verbose

    # Check available backups
    echo -e "\n------- Available backups after first backup:\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test initial backup...\n"
    # Compare list backup
    INITIAL_LIST=$($YUNO_ARCHIVE list "${method_opts[@]}")
    EXPECTED_LIST="test ${method} backup.base"
    test_values "$EXPECTED_LIST" "$INITIAL_LIST" "Initial backup list"

    # Modify source directory for incremental backup
    echo "File 1 content modified" >"$SOURCE_DIR/file 1.txt"

    # Create second backup (incremental)
    echo -e "\n------- Creating second backup incremental...\n"
    test_cmd $YUNO_ARCHIVE backup "${method_opts[@]}" --source="$SOURCE_DIR" --name="test ${method} backup" --incremental --verbose

    # List available backups
    echo -e "\n------- Available backups after two backups:\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test second backup...\n"
    # Compare list backup
    SECOND_LIST=$($YUNO_ARCHIVE list "${method_opts[@]}" | sort)
    EXPECTED_LIST="test ${method} backup.base
test ${method} backup.inc01"
    test_values "$EXPECTED_LIST" "$SECOND_LIST" "Second backup list"

    # Create third backup (incremental) without changes
    echo -e "\n------- Creating third backup incremental...\n"
    test_cmd $YUNO_ARCHIVE backup "${method_opts[@]}" --source="$SOURCE_DIR" --name="test ${method} backup" --incremental --verbose

    # List available backups again
    echo -e "\n------- Available backups after third incremental backup (no changes):\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test third backup...\n"
    # Compare list backup
    THIRD_LIST=$($YUNO_ARCHIVE list "${method_opts[@]}" | sort)
    EXPECTED_LIST="test ${method} backup.base
test ${method} backup.inc01
test ${method} backup.inc02"
    test_values "$EXPECTED_LIST" "$THIRD_LIST" "Third backup list"

    # Create fourth backup (incremental) with file created and file deleted
    echo "File 4 content" >"$SOURCE_DIR/file4.txt"
    rm "$SOURCE_DIR/rep/file2.txt"

    echo -e "\n------- Creating fourth backup incremental...\n"
    test_cmd $YUNO_ARCHIVE backup "${method_opts[@]}" --source="$SOURCE_DIR" --name="test ${method} backup" --incremental --verbose

    # List available backups again
    echo -e "\n------- Available backups after fourth incremental backup (file created and file deleted):\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test fourth backup...\n"
    # Compare list backup
    FOURTH_LIST=$($YUNO_ARCHIVE list "${method_opts[@]}" | sort)
    EXPECTED_LIST="test ${method} backup.base
test ${method} backup.inc01
test ${method} backup.inc02
test ${method} backup.inc03"
    test_values "$EXPECTED_LIST" "$FOURTH_LIST" "Fourth backup list"
}

restore_tests() {
    local method="$1"
    local repository="$2"

    local method_opts=()
    case "$method" in
    local)
        method_opts=(local --repository="$repository")
        ;;
    rclone)
        method_opts=(rclone --repository="$repository" --path="tests backup restore")
        ;;
    drive)
        method_opts=(drive --drive="$repository" --repository="tests backup restore")
        ;;
    ssh)
        method_opts=(ssh --repository="$repository")
        ;;
    *)
        error_msg "Unknown method: $method"
        cleanup
        exit 1
        ;;
    esac

    echo -e "\n------- Restoring to restore-base from base backup...\n"

    RESTORE_DIR="$TMP_DIR/$method/restore-base"
    mkdir -p "$RESTORE_DIR"
    test_cmd $YUNO_ARCHIVE restore "${method_opts[@]}" --name="test ${method} backup" --destination="$RESTORE_DIR" --increment=base --verbose

    echo -e "\n------- Check restore-base from base backup...\n"

    # Verify restored files
    RESTORED_FILE1_CONTENT=$(cat "$RESTORE_DIR/file 1.txt")
    test_values "File 1 content" "$RESTORED_FILE1_CONTENT" "Restored file 1.txt from base backup"

    RESTORED_FILE2_CONTENT=$(cat "$RESTORE_DIR/rep/file2.txt")
    test_values "File 2 content" "$RESTORED_FILE2_CONTENT" "Restored file2.txt from base backup"

    RESTORED_FILE3_CONTENT=$(cat "$RESTORE_DIR/rep/file3.txt")
    test_values "File 3 content" "$RESTORED_FILE3_CONTENT" "Restored file3.txt from base backup"

    echo -e "\n------- Restoring to restore-inc01 from inc01 backup...\n"

    RESTORE_DIR="$TMP_DIR/$method/restore-inc01"
    mkdir -p "$RESTORE_DIR"
    test_cmd $YUNO_ARCHIVE restore "${method_opts[@]}" --name="test ${method} backup" --destination="$RESTORE_DIR" --increment=1 --verbose

    echo -e "\n------- Check restore-inc01 from inc01 backup...\n"

    # Verify restored files
    RESTORED_FILE1_CONTENT=$(cat "$RESTORE_DIR/file 1.txt")
    test_values "File 1 content modified" "$RESTORED_FILE1_CONTENT" "Restored file 1.txt from inc01 backup"

    RESTORED_FILE2_CONTENT=$(cat "$RESTORE_DIR/rep/file2.txt")
    test_values "File 2 content" "$RESTORED_FILE2_CONTENT" "Restored file2.txt from inc01 backup"

    RESTORED_FILE3_CONTENT=$(cat "$RESTORE_DIR/rep/file3.txt")
    test_values "File 3 content" "$RESTORED_FILE3_CONTENT" "Restored file3.txt from inc01 backup"

    echo -e "\n------- Restoring to restore-inc02 from inc02 backup...\n"

    RESTORE_DIR="$TMP_DIR/$method/restore-inc02"
    mkdir -p "$RESTORE_DIR"
    test_cmd $YUNO_ARCHIVE restore "${method_opts[@]}" --name="test ${method} backup" --destination="$RESTORE_DIR" --increment=2 --verbose

    echo -e "\n------- Check restore-inc02 from inc02 backup...\n"

    # Verify restored files
    RESTORED_FILE1_CONTENT=$(cat "$RESTORE_DIR/file 1.txt")
    test_values "File 1 content modified" "$RESTORED_FILE1_CONTENT" "Restored file 1.txt from inc02 backup"

    RESTORED_FILE2_CONTENT=$(cat "$RESTORE_DIR/rep/file2.txt")
    test_values "File 2 content" "$RESTORED_FILE2_CONTENT" "Restored file2.txt from inc02 backup"

    RESTORED_FILE3_CONTENT=$(cat "$RESTORE_DIR/rep/file3.txt")
    test_values "File 3 content" "$RESTORED_FILE3_CONTENT" "Restored file3.txt from inc02 backup"

    echo -e "\n------- Restoring to restore-inc03 from inc03 backup...\n"

    RESTORE_DIR="$TMP_DIR/$method/restore-inc03"
    mkdir -p "$RESTORE_DIR"
    test_cmd $YUNO_ARCHIVE restore "${method_opts[@]}" --name="test ${method} backup" --destination="$RESTORE_DIR" --increment=3 --verbose

    echo -e "\n------- Check restore-inc03 from inc03 backup...\n"

    # Verify restored files
    RESTORED_FILE1_CONTENT=$(cat "$RESTORE_DIR/file 1.txt")
    test_values "File 1 content modified" "$RESTORED_FILE1_CONTENT" "Restored file 1.txt from inc03 backup"

    if [ -f "$RESTORE_DIR/rep/file2.txt" ]; then
        error_msg "Test failed for Restored file2.txt from inc03 backup: file should be deleted"
        cleanup
        exit 1
    else
        success_msg "Test passed for Restored file2.txt from inc03 backup: file correctly deleted"
    fi

    RESTORED_FILE3_CONTENT=$(cat "$RESTORE_DIR/rep/file3.txt")
    test_values "File 3 content" "$RESTORED_FILE3_CONTENT" "Restored file3.txt from inc03 backup"

    RESTORED_FILE3_CONTENT=$(cat "$RESTORE_DIR/file4.txt")
    test_values "File 4 content" "$RESTORED_FILE3_CONTENT" "Restored file4.txt from inc03 backup"
}

# TODO add delete test

delete_tests() {
    local method="$1"
    local repository="$2"

    local method_opts=()
    case "$method" in
    local)
        method_opts=(local --repository="$repository")
        ;;
    rclone)
        method_opts=(rclone --repository="$repository" --path="tests backup restore")
        ;;
    drive)
        method_opts=(drive --drive="$repository" --repository="tests backup restore")
        ;;
    ssh)
        method_opts=(ssh --repository="$repository")
        ;;
    *)
        error_msg "Unknown method: $method"
        cleanup
        exit 1
        ;;
    esac

    echo -e "\n------- Creating non incremental backup...\n"
    test_cmd $YUNO_ARCHIVE backup "${method_opts[@]}" --source="$SOURCE_DIR" --name="test ${method}" --verbose

    # Check available backups
    echo -e "\n------- Available backups after first backup:\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test initial backup...\n"
    # Compare list backup
    LIST=$($YUNO_ARCHIVE list "${method_opts[@]}" | sort)
    EXPECTED_LIST="test ${method}
test ${method} backup.base
test ${method} backup.inc01
test ${method} backup.inc02
test ${method} backup.inc03"
    test_values "$EXPECTED_LIST" "$LIST" "Initial backup list before delete"

    echo -e "\n------- delete incremental backup...\n"
    test_cmd $YUNO_ARCHIVE delete "${method_opts[@]}" --name="test ${method} backup" --verbose

    # Check available backups
    echo -e "\n------- Available backups after delete incremental backup:\n"
    test_cmd $YUNO_ARCHIVE list "${method_opts[@]}" --full --human_readable

    echo -e "\n------- Test initial backup...\n"
    # Compare list backup
    LIST=$($YUNO_ARCHIVE list "${method_opts[@]}" | sort)
    EXPECTED_LIST="test ${method}"
    test_values "$EXPECTED_LIST" "$LIST" "List after delete incremental"
}

############################################################
# Main script                                              #
############################################################

trap cleanup EXIT

echo -e "\n======= Starting Backup Local Incremental Tests =======\n"

init

BACKUP_DIR="$TMP_DIR/backup"
mkdir -p "$BACKUP_DIR"

backup_tests local "$BACKUP_DIR"

echo -e "\n======= Starting Restore Local Incremental Tests =======\n"

restore_tests local "$BACKUP_DIR"

echo -e "\n======= Starting Delete Local Tests =======\n"

delete_tests local "$BACKUP_DIR"

cleanup

echo -e "\n======= Starting Backup Drive Incremental Tests =======\n"

init

BACKUP_DRIVE="/dev/sdXX"

backup_tests drive "$BACKUP_DRIVE"

echo -e "\n======= Starting Restore Drive Incremental Tests =======\n"

restore_tests drive "$BACKUP_DRIVE"

echo -e "\n======= Starting Delete Drive Tests =======\n"

delete_tests drive "$BACKUP_DRIVE"

cleanup

echo -e "\n======= Starting Backup Rclone Incremental Tests =======\n"

init

BACKUP_RCLONE="XXX"

backup_tests rclone "$BACKUP_RCLONE"

echo -e "\n======= Starting Restore Rclone Incremental Tests =======\n"

restore_tests rclone "$BACKUP_RCLONE"

echo -e "\n======= Starting Delete Rclone Tests =======\n"

delete_tests rclone "$BACKUP_RCLONE"

cleanup

echo -e "\n======= Starting Backup SSH Incremental Tests =======\n"

init

BACKUP_SSH="XXXXX:/tmp/test/archive repo"

backup_tests ssh "$BACKUP_SSH"

echo -e "\n======= Starting Restore Drive Incremental Tests =======\n"

restore_tests ssh "$BACKUP_SSH"

echo -e "\n======= Starting Delete Drive Tests =======\n"

delete_tests ssh "$BACKUP_SSH"

cleanup
