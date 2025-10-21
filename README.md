# FreeRADIUS + daloRADIUS Installation Script

Automated installation script for FreeRADIUS with daloRADIUS web interface using Nginx.

## Features

- ✅ Automated installation of FreeRADIUS
- ✅ daloRADIUS web GUI (latest version compatible)
- ✅ Nginx web server (instead of Apache)
- ✅ MariaDB database
- ✅ PHP-FPM with all required extensions
- ✅ Environment-based configuration (no hardcoded credentials)
- ✅ SSL certificate generation
- ✅ Automated database setup and schema import
- ✅ Proper permissions and security settings

## Requirements

- Ubuntu 20.04/22.04/24.04 or Debian 11/12
- Root or sudo access
- Internet connection

## Installation

### 1. Clone or Download

```bash
git clone <repository-url>
cd initial-setup
```

### 2. Configure Environment Variables

Copy the example environment file and edit it with your settings:

```bash
cp .env.example .env
nano .env
```

Edit the following variables in `.env`:

```bash
# Database Configuration
DB_ROOT_PASSWORD=your_secure_root_password
DB_RADIUS_PASSWORD=your_secure_radius_password

# FreeRADIUS Database
RADIUS_DB_NAME=radius
RADIUS_DB_USER=radius

# Server Configuration
SERVER_NAME=localhost  # Change to your domain or IP
SERVER_IP=127.0.0.1

# daloRADIUS Configuration
DALORADIUS_VERSION=master
```

**Important**: Use strong, unique passwords for production environments!

### 3. Make Script Executable

```bash
chmod +x setup-freeradius-daloradius.sh
```

### 4. Run Installation

```bash
sudo ./setup-freeradius-daloradius.sh
```

The script will:
- Update system packages
- Install and configure Nginx
- Install PHP-FPM and required extensions
- Install and secure MariaDB
- Install FreeRADIUS
- Install daloRADIUS (latest version)
- Configure all components
- Set up proper permissions
- Start all services

## Post-Installation

### Access daloRADIUS

Open your browser and navigate to:

```
http://your-server-ip/daloradius/
```

or

```
http://your-domain.com/daloradius/
```

### Default Credentials

- **Username**: `administrator`
- **Password**: `radius`

**⚠️ CRITICAL**: Change the default password immediately after first login!

### Change Administrator Password

1. Log in to daloRADIUS
2. Go to: **Config** → **Operators** → **List Operators**
3. Click on `administrator`
4. Change the password
5. Save changes

## Configuration

### FreeRADIUS Configuration

Configuration files location:
```
/etc/freeradius/3.0/
```

SQL module configuration:
```
/etc/freeradius/3.0/mods-enabled/sql
```

### daloRADIUS Configuration

Web files location:
```
/var/www/html/daloradius/
```

Configuration file (new versions):
```
/var/www/html/daloradius/app/common/includes/daloradius.conf.php
```

Configuration file (older versions):
```
/var/www/html/daloradius/library/daloradius.conf.php
```

### Nginx Configuration

Site configuration:
```
/etc/nginx/sites-available/daloradius
```

Logs:
```
/var/log/nginx/daloradius-access.log
/var/log/nginx/daloradius-error.log
```

## Testing FreeRADIUS

### Test Local Authentication

```bash
# Test user authentication
radtest username password localhost 0 testing123
```

### Check FreeRADIUS Status

```bash
sudo systemctl status freeradius
```

### Debug Mode

```bash
sudo systemctl stop freeradius
sudo freeradius -X
```

## Common Tasks

### Adding a NAS Client

1. Log in to daloRADIUS
2. Go to: **Management** → **NAS** → **New NAS**
3. Fill in:
   - NAS IP Address
   - NAS Short Name
   - NAS Type
   - NAS Secret (shared secret)
4. Save

### Adding a User

1. Log in to daloRADIUS
2. Go to: **Management** → **Users** → **New User**
3. Fill in:
   - Username
   - Password
   - Attributes (optional)
4. Save

### View Accounting Data

1. Go to: **Accounting** → **Custom Query**
2. View user sessions, bandwidth usage, etc.

## Troubleshooting

### Check Service Status

```bash
sudo systemctl status freeradius
sudo systemctl status nginx
sudo systemctl status mariadb
sudo systemctl status php8.1-fpm  # Adjust PHP version
```

### View FreeRADIUS Logs

```bash
sudo tail -f /var/log/freeradius/radius.log
```

### View Nginx Logs

```bash
sudo tail -f /var/log/nginx/daloradius-error.log
```

### Database Connection Issues

Test database connection:
```bash
mysql -u radius -p -h localhost radius
```

### Permission Issues

Reset daloRADIUS permissions:
```bash
sudo chown -R www-data:www-data /var/www/html/daloradius/
```

### FreeRADIUS Won't Start

Check configuration:
```bash
sudo freeradius -C
```

Run in debug mode:
```bash
sudo freeradius -X
```

## Security Considerations

1. **Change default passwords** immediately
2. **Use strong passwords** for database and admin accounts
3. **Configure firewall** to restrict access:
   ```bash
   sudo ufw allow 22/tcp    # SSH
   sudo ufw allow 80/tcp    # HTTP
   sudo ufw allow 443/tcp   # HTTPS (if configured)
   sudo ufw allow 1812/udp  # RADIUS Authentication
   sudo ufw allow 1813/udp  # RADIUS Accounting
   sudo ufw enable
   ```
4. **Enable HTTPS** with Let's Encrypt or self-signed certificates
5. **Restrict database access** to localhost only
6. **Regular updates**: Keep system and packages updated
7. **Backup database** regularly

## SSL/TLS Configuration (Optional)

To enable HTTPS with Let's Encrypt:

```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d your-domain.com
```

## Backup and Restore

### Backup Database

```bash
mysqldump -u root -p radius > radius_backup_$(date +%Y%m%d).sql
```

### Restore Database

```bash
mysql -u root -p radius < radius_backup_YYYYMMDD.sql
```

## Uninstallation

To remove all components:

```bash
sudo systemctl stop freeradius nginx mariadb
sudo apt remove --purge freeradius freeradius-mysql nginx mariadb-server php-fpm
sudo rm -rf /etc/freeradius
sudo rm -rf /var/www/html/daloradius
sudo rm -f /etc/nginx/sites-available/daloradius
sudo mysql -u root -p -e "DROP DATABASE radius;"
```

## License

This installation script is provided as-is for educational and production use.

## Support

For issues related to:
- **FreeRADIUS**: https://freeradius.org/documentation/
- **daloRADIUS**: https://github.com/lirantal/daloradius
- **This script**: Open an issue in the repository

## Changelog

### Version 2.0 (2025)
- Switched from Apache to Nginx
- Updated for latest daloRADIUS version
- Added support for new daloRADIUS directory structure
- Moved sensitive data to environment variables
- Added comprehensive error handling
- Improved security configurations
- Added detailed documentation

### Version 1.0 (Original)
- Basic installation script with Apache
- Hardcoded credentials
- Manual configuration required
