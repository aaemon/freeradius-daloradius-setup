#!/bin/bash

###############################################################################
# FreeRADIUS + daloRADIUS Installation Script with Nginx
# Updated for new daloRADIUS version
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
required_vars=("DB_ROOT_PASSWORD" "DB_RADIUS_PASSWORD" "RADIUS_DB_NAME" "RADIUS_DB_USER" "SERVER_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        print_error "Required environment variable $var is not set in .env file"
        exit 1
    fi
done

print_message "Starting FreeRADIUS + daloRADIUS installation with Nginx..."

###############################################################################
# 1. System Update
###############################################################################
print_message "Updating system packages..."
apt-get update -y
apt-get upgrade -y

###############################################################################
# 2. Install Nginx
###############################################################################
print_message "Installing Nginx..."
apt-get install -y nginx

###############################################################################
# 3. Install PHP and required extensions
###############################################################################
print_message "Installing PHP and extensions..."
apt-get install -y php-fpm php-gd php-common php-mail php-mail-mime \
    php-mysql php-pear php-db php-mbstring php-xml php-curl \
    php-zip php-bcmath php-json

# Detect PHP version
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
print_message "Detected PHP version: $PHP_VERSION"

###############################################################################
# 4. Install MariaDB
###############################################################################
print_message "Installing MariaDB..."
apt-get install -y mariadb-server mariadb-client

###############################################################################
# 5. Secure MariaDB Installation (Automated)
###############################################################################
print_message "Securing MariaDB installation..."
mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASSWORD}';" || true
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DROP DATABASE IF EXISTS test;"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysql -u root -p"${DB_ROOT_PASSWORD}" -e "FLUSH PRIVILEGES;"

###############################################################################
# 6. Create FreeRADIUS Database
###############################################################################
print_message "Creating FreeRADIUS database and user..."
mysql -u root -p"${DB_ROOT_PASSWORD}" <<MYSQL_SCRIPT
CREATE DATABASE IF NOT EXISTS ${RADIUS_DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${RADIUS_DB_USER}'@'localhost' IDENTIFIED BY '${DB_RADIUS_PASSWORD}';
GRANT ALL PRIVILEGES ON ${RADIUS_DB_NAME}.* TO '${RADIUS_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

###############################################################################
# 7. Install FreeRADIUS
###############################################################################
print_message "Installing FreeRADIUS..."
apt-get install -y freeradius freeradius-mysql freeradius-utils

###############################################################################
# 8. Import FreeRADIUS MySQL Schema
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
# 9. Enable SQL Module for FreeRADIUS
###############################################################################
print_message "Enabling SQL module for FreeRADIUS..."
ln -sf ${FREERADIUS_CONFIG_PATH}/mods-available/sql ${FREERADIUS_CONFIG_PATH}/mods-enabled/sql

###############################################################################
# 10. Generate SSL Certificates
###############################################################################
print_message "Generating SSL certificates..."
cd /etc/ssl/certs/
if [ ! -f ca-key.pem ]; then
    openssl genrsa 2048 > ca-key.pem
    openssl req -sha256 -new -x509 -nodes -days 3650 -key ca-key.pem \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=FreeRADIUS-CA" > ca-cert.pem
fi

###############################################################################
# 11. Configure FreeRADIUS SQL Module
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
# 12. Set Proper Permissions for FreeRADIUS
###############################################################################
print_message "Setting FreeRADIUS permissions..."
chgrp -h freerad ${FREERADIUS_CONFIG_PATH}/mods-available/sql
chown -R freerad:freerad ${FREERADIUS_CONFIG_PATH}/mods-enabled/sql

###############################################################################
# 13. Install daloRADIUS (New Version)
###############################################################################
print_message "Installing daloRADIUS..."
cd /tmp

# Clone the latest daloRADIUS from GitHub
if [ -d daloradius ]; then
    rm -rf daloradius
fi

apt-get install -y git
git clone https://github.com/lirantal/daloradius.git
cd daloradius

###############################################################################
# 14. Import daloRADIUS Database Schema
###############################################################################
print_message "Importing daloRADIUS database schema..."

# For new daloRADIUS, the SQL files location has changed
if [ -f "contrib/db/fr2-mysql-daloradius-and-freeradius.sql" ]; then
    mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} < contrib/db/fr2-mysql-daloradius-and-freeradius.sql
fi

if [ -f "contrib/db/mysql-daloradius.sql" ]; then
    mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} < contrib/db/mysql-daloradius.sql
fi

# Check for new schema location (newer versions)
if [ -f "contrib/db/fr3-mysql-freeradius.sql" ]; then
    mysql -u root -p"${DB_ROOT_PASSWORD}" ${RADIUS_DB_NAME} < contrib/db/fr3-mysql-freeradius.sql
fi

###############################################################################
# 15. Move daloRADIUS to Web Directory
###############################################################################
print_message "Setting up daloRADIUS web files..."
WEB_ROOT="/var/www/html"
DALORADIUS_PATH="${WEB_ROOT}/daloradius"

# Remove old installation if exists
if [ -d "$DALORADIUS_PATH" ]; then
    rm -rf "$DALORADIUS_PATH"
fi

# Copy daloRADIUS to web root
cp -r /tmp/daloradius "$DALORADIUS_PATH"

###############################################################################
# 16. Configure daloRADIUS
###############################################################################
print_message "Configuring daloRADIUS..."

# Check for the new configuration file location
if [ -f "$DALORADIUS_PATH/app/common/includes/daloradius.conf.php.sample" ]; then
    # New structure (2024+ versions)
    CONFIG_DIR="$DALORADIUS_PATH/app/common/includes"
    CONFIG_FILE="$CONFIG_DIR/daloradius.conf.php"
    cp "$CONFIG_DIR/daloradius.conf.php.sample" "$CONFIG_FILE"
elif [ -f "$DALORADIUS_PATH/library/daloradius.conf.php.sample" ]; then
    # Old structure
    CONFIG_DIR="$DALORADIUS_PATH/library"
    CONFIG_FILE="$CONFIG_DIR/daloradius.conf.php"
    cp "$CONFIG_DIR/daloradius.conf.php.sample" "$CONFIG_FILE"
else
    print_error "Cannot find daloRADIUS configuration template"
    exit 1
fi

# Update configuration
sed -i "s/\$configValues\['CONFIG_DB_HOST'\] = '.*';/\$configValues['CONFIG_DB_HOST'] = 'localhost';/" "$CONFIG_FILE"
sed -i "s/\$configValues\['CONFIG_DB_PORT'\] = '.*';/\$configValues['CONFIG_DB_PORT'] = '3306';/" "$CONFIG_FILE"
sed -i "s/\$configValues\['CONFIG_DB_USER'\] = '.*';/\$configValues['CONFIG_DB_USER'] = '${RADIUS_DB_USER}';/" "$CONFIG_FILE"
sed -i "s/\$configValues\['CONFIG_DB_PASS'\] = '.*';/\$configValues['CONFIG_DB_PASS'] = '${DB_RADIUS_PASSWORD}';/" "$CONFIG_FILE"
sed -i "s/\$configValues\['CONFIG_DB_NAME'\] = '.*';/\$configValues['CONFIG_DB_NAME'] = '${RADIUS_DB_NAME}';/" "$CONFIG_FILE"

chmod 664 "$CONFIG_FILE"

###############################################################################
# 17. Set Permissions for daloRADIUS
###############################################################################
print_message "Setting daloRADIUS permissions..."
chown -R www-data:www-data "$DALORADIUS_PATH"

###############################################################################
# 18. Configure Nginx for daloRADIUS
###############################################################################
print_message "Configuring Nginx for daloRADIUS..."

cat > /etc/nginx/sites-available/daloradius <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};

    root ${DALORADIUS_PATH};
    index index.php index.html index.htm;

    # Logging
    access_log /var/log/nginx/daloradius-access.log;
    error_log /var/log/nginx/daloradius-error.log;

    # Main location
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    # PHP-FPM Configuration
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Deny access to hidden files
    location ~ /\. {
        deny all;
    }

    # Deny access to config files
    location ~ /app/common/includes/daloradius.conf.php {
        deny all;
    }
    
    location ~ /library/daloradius.conf.php {
        deny all;
    }
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/daloradius /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test Nginx configuration
nginx -t

###############################################################################
# 19. Restart Services
###############################################################################
print_message "Restarting services..."
systemctl restart mariadb
systemctl restart freeradius
systemctl restart php${PHP_VERSION}-fpm
systemctl restart nginx

# Enable services to start on boot
systemctl enable mariadb
systemctl enable freeradius
systemctl enable php${PHP_VERSION}-fpm
systemctl enable nginx

###############################################################################
# 20. Verify Services Status
###############################################################################
print_message "Verifying services status..."
systemctl status freeradius --no-pager | head -n 10
systemctl status nginx --no-pager | head -n 10

###############################################################################
# Installation Complete
###############################################################################
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installation completed successfully!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Access daloRADIUS at: ${YELLOW}http://${SERVER_NAME}/daloradius/${NC}"
echo ""
echo -e "Default credentials:"
echo -e "  Username: ${YELLOW}administrator${NC}"
echo -e "  Password: ${YELLOW}radius${NC}"
echo ""
echo -e "${RED}IMPORTANT: Change the default password immediately after first login!${NC}"
echo ""
echo -e "Database Information:"
echo -e "  Database: ${RADIUS_DB_NAME}"
echo -e "  User: ${RADIUS_DB_USER}"
echo ""
echo -e "FreeRADIUS Configuration: ${FREERADIUS_CONFIG_PATH}"
echo -e "daloRADIUS Path: ${DALORADIUS_PATH}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Log in to daloRADIUS web interface"
echo "2. Change the default administrator password"
echo "3. Configure your NAS clients"
echo "4. Add users and test authentication"
echo ""
