#!/bin/bash

###############################################################################
# FreeRADIUS + MySQL Installation Script
# Clean installation without daloRADIUS
###############################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then 
    print_error "Please run this script as root or with sudo"
    exit 1
fi

# Load environment variables
if [ ! -f .env ]; then
    print_error ".env file not found! Please copy .env.example to .env and configure it."
    exit 1
fi

# Source environment variables
export $(grep -v '^#' .env | xargs)

# Validate required environment variables
required_vars=("DB_ROOT_PASSWORD" "DB_RADIUS_PASSWORD" "RADIUS_DB_NAME" "RADIUS_DB_USER" "TEST_NAS_SECRET" "TEST_USER_NAME" "TEST_USER_PASSWORD")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required environment variable $var is not set in .env file"
        exit 1
    fi
done

print_message "Starting FreeRADIUS + MySQL installation..."

###############################################################################
# 1. System Update
###############################################################################
print_message "Updating system packages..."
apt-get update -y
apt-get upgrade -y

###############################################################################
# 2. Install MariaDB
###############################################################################
print_message "Installing MariaDB..."
apt-get install -y mariadb-server mariadb-client

###############################################################################
# 3. Secure MariaDB Installation (Automated)
###############################################################################
print_message "Securing MariaDB installation..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';" || true
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

###############################################################################
# 4. Create FreeRADIUS Database
###############################################################################
print_message "Creating FreeRADIUS database and user..."
mysql -u root -p"${DB_ROOT_PASSWORD}" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS ${RADIUS_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${RADIUS_DB_USER}'@'localhost' IDENTIFIED BY '${DB_RADIUS_PASSWORD}';
GRANT ALL PRIVILEGES ON ${RADIUS_DB_NAME}.* TO '${RADIUS_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

###############################################################################
# 5. Install FreeRADIUS
###############################################################################
print_message "Installing FreeRADIUS..."
apt-get install -y freeradius freeradius-mysql freeradius-utils

###############################################################################
# 6. Import FreeRADIUS MySQL Schema
###############################################################################
print_message "Importing FreeRADIUS database schema..."
FREERADIUS_CONFIG_PATH="/etc/freeradius/3.0"

# Check if FreeRADIUS 3.0 directory exists, otherwise try 3.2 or other versions
if [ ! -d "$FREERADIUS_CONFIG_PATH" ]; then
    FREERADIUS_CONFIG_PATH=$(find /etc/freeradius -type d -name "3.*" | head -n 1)
    if [ -z "$FREERADIUS_CONFIG_PATH" ]; then
        print_error "FreeRADIUS configuration directory not found"
        exit 1
    fi
    print_message "Using FreeRADIUS config path: $FREERADIUS_CONFIG_PATH"
fi

mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} < ${FREERADIUS_CONFIG_PATH}/mods-config/sql/main/mysql/schema.sql

# Verify tables were created
print_message "Verifying database tables..."
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "USE ${RADIUS_DB_NAME}; SHOW TABLES;"

###############################################################################
# 7. Enable SQL Module for FreeRADIUS
###############################################################################
print_message "Enabling SQL module for FreeRADIUS..."
ln -sf ${FREERADIUS_CONFIG_PATH}/mods-available/sql ${FREERADIUS_CONFIG_PATH}/mods-enabled/sql

###############################################################################
# 8. Generate SSL Certificates
###############################################################################
print_message "Generating SSL certificates..."
cd /etc/ssl/certs/
if [ ! -f ca-key.pem ]; then
    openssl genrsa 2048 > ca-key.pem
    openssl req -sha256 -new -x509 -nodes -days 3650 -key ca-key.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=FreeRADIUS-CA" > ca-cert.pem
fi

###############################################################################
# 9. Configure FreeRADIUS SQL Module
###############################################################################
print_message "Configuring FreeRADIUS SQL module..."
cat > ${FREERADIUS_CONFIG_PATH}/mods-enabled/sql <<EOF
sql {
    driver = "rlm_sql_mysql"
    dialect = "mysql"

    # Connection info:
    server = "localhost"
    port = 3306
    login = "${RADIUS_DB_USER}"
    password = "${DB_RADIUS_PASSWORD}"

    # Database table configuration
    radius_db = "${RADIUS_DB_NAME}"

    mysql {
        # If any of the files below are set, TLS encryption is enabled
        tls {
            ca_file = "/etc/ssl/certs/ca-cert.pem"
            ca_path = "/etc/ssl/certs/"
            cipher = "DHE-RSA-AES256-SHA:AES128-SHA"

            tls_required = no
            tls_check_cert = no
            tls_check_cert_cn = no
        }

        warnings = auto
    }

    # Set to 'yes' to read radius clients from the database ('nas' table)
    read_clients = yes
    client_table = "nas"

    # Pool configuration
    pool {
        start = 5
        min = 4
        max = 10
        spare = 3
        uses = 0
        lifetime = 0
        idle_timeout = 60
    }
}
EOF

###############################################################################
# 10. Set Proper Permissions for FreeRADIUS
###############################################################################
print_message "Setting FreeRADIUS permissions..."
chgrp -h freerad ${FREERADIUS_CONFIG_PATH}/mods-available/sql
chown -R freerad:freerad ${FREERADIUS_CONFIG_PATH}/mods-enabled/sql

###############################################################################
# 11. Restart Services
###############################################################################
print_message "Restarting services..."
systemctl restart mariadb
systemctl restart freeradius

# Enable services to start on boot
systemctl enable mariadb
systemctl enable freeradius

###############################################################################
# 12. Verify Services Status
###############################################################################
print_message "Verifying services status..."
systemctl status mariadb --no-pager | head -n 10
systemctl status freeradius --no-pager | head -n 10

###############################################################################
# 13. Create Sample NAS Client (Optional)
###############################################################################
print_message "Adding sample NAS client to database..."
mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} <<SQL_SCRIPT
INSERT IGNORE INTO nas (nasname, shortname, type, ports, secret, server, community, description)
VALUES ('127.0.0.1', 'localhost', 'other', 1812, '${TEST_NAS_SECRET}', NULL, NULL, 'Local testing NAS');
SQL_SCRIPT

###############################################################################
# 14. Create Sample Test User (Optional)
###############################################################################
print_message "Adding sample test user to database..."
mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} <<SQL_SCRIPT
-- Insert test user
INSERT IGNORE INTO radcheck (username, attribute, op, value)
VALUES ('${TEST_USER_NAME}', 'Cleartext-Password', ':=', '${TEST_USER_PASSWORD}');

-- Add user to default group
INSERT IGNORE INTO radusergroup (username, groupname, priority)
VALUES ('${TEST_USER_NAME}', 'default', 1);
SQL_SCRIPT

###############################################################################
# Installation Complete
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "FreeRADIUS Configuration: ${YELLOW}${FREERADIUS_CONFIG_PATH}${NC}"
echo ""
echo -e "Database Information:"
echo -e "  Database: ${YELLOW}${RADIUS_DB_NAME}${NC}"
echo -e "  User: ${YELLOW}${RADIUS_DB_USER}${NC}"
echo -e "  Host: ${YELLOW}localhost:3306${NC}"
echo ""
echo -e "Sample NAS Client:"
echo -e "  IP: ${YELLOW}127.0.0.1${NC}"
echo -e "  Secret: ${YELLOW}${TEST_NAS_SECRET}${NC}"
echo ""
echo -e "Sample Test User:"
echo -e "  Username: ${YELLOW}${TEST_USER_NAME}${NC}"
echo -e "  Password: ${YELLOW}${TEST_USER_PASSWORD}${NC}"
echo ""
echo -e "${YELLOW}Test FreeRADIUS authentication:${NC}"
echo -e "  radtest ${TEST_USER_NAME} ${TEST_USER_PASSWORD} 127.0.0.1 0 ${TEST_NAS_SECRET}"
echo ""
echo -e "${YELLOW}Check FreeRADIUS status:${NC}"
echo -e "  systemctl status freeradius"
echo ""
echo -e "${YELLOW}View FreeRADIUS logs:${NC}"
echo -e "  tail -f /var/log/freeradius/radius.log"
echo ""
echo -e "${YELLOW}Debug FreeRADIUS (if issues):${NC}"
echo -e "  systemctl stop freeradius"
echo -e "  freeradius -X"
echo ""
echo -e "${RED}IMPORTANT:${NC}"
echo "1. Change the test NAS secret and credentials in .env for production"
echo "2. Remove or change the test user credentials"
echo "3. Configure your actual NAS devices in the 'nas' table"
echo "4. Add your users to the 'radcheck' table"
echo ""
