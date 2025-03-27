#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/file_changes.log"

# Update package list and install required packages
echo "Updating system and installing required packages..."
sudo apt update -y
sudo apt install -y python3-venv python3-pip

# Create a virtual environment
echo "Creating virtual environment at $VENV_DIR..."
python3 -m venv $VENV_DIR

# Activate virtual environment
source $VENV_DIR/bin/activate

# Install required Python packages
echo "Installing required Python packages..."
pip install watchdog

# Create the file monitor script
echo "Creating the file monitor script..."
cat <<EOL > $SCRIPT_PATH
import os
import logging
import time
import gzip
import shutil
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from datetime import datetime, timedelta

# Configure logging
LOG_FILE = "$LOG_FILE"  # You can change this to any path you prefer
logging.basicConfig(filename=LOG_FILE, level=logging.INFO, format="%(asctime)s - %(message)s")

# Time interval for log file compression (in seconds)
COMPRESS_INTERVAL = 3600  # 1 hour
LOG_RETENTION_DAYS = 7

# Unicode icons for different events
MODIFIED_ICON = "🔄"  # Modified event
CREATED_ICON = "✨"   # Created event
DELETED_ICON = "❌"   # Deleted event
MOVED_ICON = "🔀"     # Moved event

class FileMonitorHandler(FileSystemEventHandler):
    """Handles file system events (create, modify, delete, move)"""
    
    def on_modified(self, event):
        if not event.is_directory:
            logging.info(f"{MODIFIED_ICON} Modified: {event.src_path}")

    def on_created(self, event):
        if not event.is_directory:
            logging.info(f"{CREATED_ICON} Created: {event.src_path}")

    def on_deleted(self, event):
        if not event.is_directory:
            logging.info(f"{DELETED_ICON} Deleted: {event.src_path}")

    def on_moved(self, event):
        if not event.is_directory:
            logging.info(f"{MOVED_ICON} Moved: {event.src_path} to {event.dest_path}")

def get_existing_paths():
    """Returns only existing system directories to prevent errors (removed /var)"""
    paths = ["/home", "/etc", "/root", "/usr", "/opt"]  # /var has been removed
    return [path for path in paths if os.path.exists(path)]

def compress_log():
    """Compress the log file every hour"""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    compressed_log = f"{LOG_FILE}_{timestamp}.gz"
    
    with open(LOG_FILE, "rb") as f_in:
        with gzip.open(compressed_log, "wb") as f_out:
            shutil.copyfileobj(f_in, f_out)

    # Clear the original log file after compression
    open(LOG_FILE, 'w').close()

    logging.info(f"Log compressed and saved as: {compressed_log}")

def delete_old_logs():
    """Delete log files older than 7 days"""
    current_time = time.time()
    for filename in os.listdir('/var/log'):
        if filename.startswith("file_changes.log"):
            file_path = os.path.join('/var/log', filename)
            if os.path.isfile(file_path):
                file_mod_time = os.path.getmtime(file_path)
                if current_time - file_mod_time > LOG_RETENTION_DAYS * 86400:  # 86400 seconds = 1 day
                    os.remove(file_path)
                    logging.info(f"Deleted old log file: {file_path}")

def main():
    event_handler = FileMonitorHandler()
    observer = Observer()

    # Add all system paths
    for path in get_existing_paths():
        observer.schedule(event_handler, path, recursive=True)
    
    observer.start()
    logging.info("📢 File Integrity Monitoring Started!")

    # Set up log rotation (compression and deletion) in a background thread
    while True:
        try:
            # Run log compression every hour
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

# Create systemd service file for the script
echo "Creating systemd service file..."
cat <<EOL | sudo tee $SERVICE_PATH
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

[Install]
WantedBy=multi-user.target
EOL

# Reload systemd and enable the service
echo "Reloading systemd, enabling and starting the service..."
sudo systemctl daemon-reload
sudo systemctl enable fwatchdog.service
sudo systemctl start watchdog.service

echo "File Integrity Monitor service installed and started successfully!"

# Check service status
sudo systemctl status watchdog.service
