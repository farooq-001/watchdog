#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/file_changes.log"

# Detect OS and package manager
if command -v apt &> /dev/null; then
    PKG_UPDATE="sudo apt update -y"
    PKG_INSTALL="sudo apt install -y python3-venv python3-pip"
elif command -v dnf &> /dev/null; then
    PKG_UPDATE="sudo dnf makecache"
    PKG_INSTALL="sudo dnf install -y python3 python3-pip python3-virtualenv"
elif command -v yum &> /dev/null; then
    sudo yum install -y epel-release
    PKG_UPDATE="sudo yum makecache"
    PKG_INSTALL="sudo yum install -y python3 python3-pip python3-virtualenv"
else
    echo "❌ Unsupported OS or package manager."
    exit 1
fi

# Check for systemctl
if ! command -v systemctl &> /dev/null; then
    echo "❌ systemctl not found. This script requires systemd."
    exit 1
fi

# Update and install
echo "🔧 Installing required packages..."
eval "$PKG_UPDATE"
eval "$PKG_INSTALL"

# Virtual environment
echo "🐍 Setting up Python virtual environment..."
python3 -m venv $VENV_DIR || virtualenv $VENV_DIR
source $VENV_DIR/bin/activate

# Install Python package
echo "📦 Installing watchdog..."
pip install --upgrade pip
pip install watchdog

# Create monitor script
echo "📝 Creating file monitor script..."
cat <<EOL > $SCRIPT_PATH
import os
import logging
import time
import gzip
import shutil
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime

LOG_FILE = "$LOG_FILE"
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

COMPRESS_INTERVAL = 3600
LOG_RETENTION_DAYS = 7

# Emojis for event types
EVENT_ICONS = {
    'CREATED': "✨",
    'MODIFIED': "🔄",
    'DELETED': "❌",
    'MOVED': "🔀"
}

class FileMonitorHandler(FileSystemEventHandler):
    def on_any_event(self, event):
        event_type = event.event_type.upper()
        kind = "[DIR]" if event.is_directory else "[FILE]"
        icon = EVENT_ICONS.get(event_type, "📁")

        if hasattr(event, 'dest_path'):  # Moved event
            logging.info(f"{icon} {event_type} {kind}: {event.src_path} ➡️ {event.dest_path}")
        else:
            logging.info(f"{icon} {event_type} {kind}: {event.src_path}")

def get_existing_paths():
    paths = ["/home", "/etc", "/root", "/usr", "/opt"]
    return [path for path in paths if os.path.exists(path)]

def compress_log():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    compressed_log = f"{LOG_FILE}_{timestamp}.gz"
    with open(LOG_FILE, "rb") as f_in:
        with gzip.open(compressed_log, "wb") as f_out:
            shutil.copyfileobj(f_in, f_out)
    open(LOG_FILE, 'w').close()
    logging.info(f"Log compressed and saved as: {compressed_log}")

def delete_old_logs():
    current_time = time.time()
    for filename in os.listdir('/var/log'):
        if filename.startswith("file_changes.log") and filename.endswith(".gz"):
            file_path = os.path.join('/var/log', filename)
            if os.path.isfile(file_path):
                file_mod_time = os.path.getmtime(file_path)
                if current_time - file_mod_time > LOG_RETENTION_DAYS * 86400:
                    os.remove(file_path)
                    logging.info(f"Deleted old log file: {file_path}")

def main():
    event_handler = FileMonitorHandler()
    observer = Observer()
    for path in get_existing_paths():
        observer.schedule(event_handler, path, recursive=True)
    observer.start()
    logging.info("📢 File Integrity Monitoring Started!")

    while True:
        try:
            compress_log()
            time.sleep(COMPRESS_INTERVAL)
            delete_old_logs()
        except KeyboardInterrupt:
            observer.stop()
            logging.info("❌ File Integrity Monitoring Stopped!")
            break
        except Exception as e:
            logging.error(f"Error: {str(e)}")

    observer.join()

if __name__ == "__main__":
    main()
EOL

# Ensure log file exists
sudo touch $LOG_FILE
sudo chown root:root $LOG_FILE
sudo chmod 644 $LOG_FILE

# Make script executable
chmod +x $SCRIPT_PATH

# Create systemd service
echo "⚙️ Creating systemd service..."
cat <<EOL | sudo tee $SERVICE_PATH > /dev/null
[Unit]
Description=File Integrity Monitor
After=network.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python $SCRIPT_PATH
WorkingDirectory=/opt
User=root
Group=root
Restart=always
Environment="PATH=$VENV_DIR/bin:/usr/bin:/bin"
Environment="PYTHONUNBUFFERED=1"
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOL

# Reload and start service
echo "🚀 Enabling and starting watchdog service..."
sudo systemctl daemon-reload
sudo systemctl enable watchdog.service
sudo systemctl start watchdog.service

# Display status
echo "✅ File Integrity Monitor is active!"
sudo systemctl status watchdog.service --no-pager

echo "ℹ️ If using SELinux (RHEL/CentOS/Rocky), and it blocks the service, run:"
echo "   sudo setenforce 0"
