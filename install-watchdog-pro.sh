#!/bin/bash

# Variables
VENV_DIR="/opt/watchdog_env"
SCRIPT_PATH="/opt/file_monitor.py"
SERVICE_PATH="/etc/systemd/system/watchdog.service"
LOG_FILE="/var/log/watchdog.log"

echo "📦 Detecting OS and installing dependencies..."

# OS detection and dependency installation
if [ -f /etc/debian_version ]; then
    echo "✅ Detected Debian-based system (Ubuntu/Debian)"
    sudo apt update -y
    sudo apt install -y python3 python3-venv python3-pip
elif [ -f /etc/redhat-release ] || grep -qi 'fedora' /etc/os-release; then
    OS_NAME=$(cat /etc/os-release | grep "^NAME=" | cut -d= -f2 | tr -d '"')
    case "$OS_NAME" in
        *Rocky*)
            echo "✅ Detected Rocky Linux"
            ;;
        *CentOS*)
            echo "✅ Detected CentOS"
            ;;
        *Red\ Hat*)
            echo "✅ Detected Red Hat Enterprise Linux"
            ;;
        *Fedora*)
            echo "✅ Detected Fedora"
            ;;
        *)
            echo "⚠️  Detected RHEL-based system: $OS_NAME"
            ;;
    esac
    sudo dnf install -y python3 python3-pip || sudo yum install -y python3 python3-pip
else
    echo "❌ Unsupported OS. Only Ubuntu/Debian and RHEL-based systems (CentOS, Rocky, Fedora, RHEL) are supported."
    exit 1
fi

# Create Python virtual environment
echo "🐍 Creating Python virtual environment at $VENV_DIR..."
python3 -m venv "$VENV_DIR"

# Activate virtual environment and install watchdog
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install watchdog

# Create the Python monitoring script
echo "📝 Writing file monitor script to $SCRIPT_PATH..."
cat <<EOF > "$SCRIPT_PATH"
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

COMPRESS_INTERVAL = 3600  # 1 hour
LOG_RETENTION_DAYS = 7

ICONS = {
    'created': "🌱",
    'modified': "🔧",
    'deleted': "🗑️",
    'moved': "🔄",
    'file': "📄",
    'dir': "📘"
}

class FileMonitorHandler(FileSystemEventHandler):
    def log_event(self, event_type, event):
        icon_type = ICONS['dir'] if event.is_directory else ICONS['file']
        if event_type == "moved":
            message = f"{ICONS[event_type]} {event_type.upper()} {icon_type} {event.src_path} ➡️ {icon_type} {event.dest_path}"
        else:
            message = f"{ICONS[event_type]} {event_type.upper()} {icon_type} {event.src_path}"
        logging.info(message)

    def on_created(self, event): self.log_event("created", event)
    def on_modified(self, event): self.log_event("modified", event)
    def on_deleted(self, event): self.log_event("deleted", event)
    def on_moved(self, event): self.log_event("moved", event)

def get_existing_paths():
    include_paths = ["/home", "/etc", "/root", "/usr", "/opt"]
    exclude_paths = ["/proc", "/sys", "/dev", "/run", "/tmp", "/var/cache", "/var/log"]
    return [p for p in include_paths if os.path.exists(p) and all(not p.startswith(ex) for ex in exclude_paths)]

def compress_log():
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    compressed_log = f"{LOG_FILE}_\{timestamp}.gz"
    with open(LOG_FILE, "rb") as f_in, gzip.open(compressed_log, "wb") as f_out:
        shutil.copyfileobj(f_in, f_out)
    open(LOG_FILE, 'w').close()
    logging.info(f"Compressed log saved: {compressed_log}")

def delete_old_logs():
    now = time.time()
    for filename in os.listdir('/var/log'):
        if filename.startswith("watchdog.log") and filename.endswith(".gz"):
            file_path = os.path.join('/var/log', filename)
            if os.path.isfile(file_path):
                file_time = os.path.getmtime(file_path)
                if now - file_time > LOG_RETENTION_DAYS * 86400:
                    os.remove(file_path)
                    logging.info(f"Deleted old log: {file_path}")

def main():
    event_handler = FileMonitorHandler()
    observer = Observer()
    for path in get_existing_paths():
        observer.schedule(event_handler, path, recursive=True)

    observer.start()
    logging.info("📢 File monitoring started!")

    try:
        while True:
            compress_log()
            time.sleep(COMPRESS_INTERVAL)
            delete_old_logs()
    except KeyboardInterrupt:
        observer.stop()
        logging.info("❌ File monitoring stopped.")
    except Exception as e:
        logging.error(f"Error: {str(e)}")

    observer.join()

if __name__ == "__main__":
    main()
EOF

# Create the systemd service file
echo "🔧 Creating systemd service..."
cat <<EOF | sudo tee "$SERVICE_PATH"
[Unit]
Description=File Integrity Watchdog
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
EOF

# Enable and start the service
echo "🚀 Enabling and starting watchdog service..."
sudo systemctl daemon-reload
sudo systemctl enable watchdog.service
sudo systemctl restart watchdog.service

echo "✅ Installation complete! Service is running."
sudo systemctl status watchdog.service
